import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif
#if canImport(UIKit)
import UIKit
#endif

/// App-icon badge count read/write — iOS port.
///
/// @impl badge-count
///
/// Spec:
///   - `spec/api/push.yaml` `/sdk/getBadgeCount` + `/sdk/setBadgeCount`.
///   - `conformance/scenarios/badge-count.feature` — set / get / clear /
///     silent push does not change badge.
///
/// # iOS-vs-Android divergence
///
/// **Android** had to ship a host-side count cache because RN's
/// `messaging().setBadge()` is a NO-OP on Android (RN bug #14 — it's
/// iOS-only on `@react-native-firebase/messaging`). The Android port
/// fixed the bug by persisting + reading back via the notification
/// builder's `setNumber()`.
///
/// **iOS** has native OS-level badge support:
///   - iOS 16+: `UNUserNotificationCenter.current().setBadgeCount(_:)`
///     (async — completion-handler variant).
///   - iOS 13–15: `UIApplication.shared.applicationIconBadgeNumber = N`
///     (synchronous, must be on the main actor).
///
/// The iOS port preserves cross-platform parity by:
///   1. Persisting the count to a `KeyValueStore` so `getCount()` stays
///      synchronous and survives process restart.
///   2. Pushing every set through to the OS via ``BadgeHost``, which in
///      production calls the version-appropriate API.
///   3. Notifying a single-listener ``BadgeChangeNotifier`` so the
///      rendering layer (A22) can pick up the current count when
///      building notifications.
///
/// # Silent push contract
///
/// The `@silent` scenario in `badge-count.feature` requires that a
/// silent push does NOT change the badge. The badge service is
/// OBLIVIOUS to push payloads — the routing layer never calls
/// ``setCount(_:)`` on the silent path. This service exposes only the
/// manual host-app API surface.
///
/// # RN parity + bug catch (#14)
///
/// RN's `getBadgeCount`/`setBadgeCount` (src/index.tsx:4050-4087)
/// delegate to `FirebaseNotificationManager.getBadgeCount`/`setBadgeCount`
/// (src/utils/FirebaseNotificationManager.ts:520-545) which call
/// `messaging().getBadge()` / `.setBadge(count)`. On iOS these go
/// through `@react-native-firebase/messaging`'s iOS-only bridge. The
/// native port uses the OS API directly so:
///   - On iOS: same behavior, no `FirebaseMessaging` dep needed.
///   - On Android (separate port): native fix for the broken RN path
///     (Android's `BadgeService` persists + uses `setNumber()`).
///
/// **No RN bug fix needed on iOS** — RN's iOS badge path works. The
/// port shifts the call from `messaging().setBadge()` to the native
/// `UNUserNotificationCenter` API for cleanliness; behavior is unchanged.
internal final class BadgeService: @unchecked Sendable {

    /// Notifier signature — invoked on every successful ``setCount(_:)``.
    /// Used by the rendering layer to know the latest count when building
    /// a notification. `@Sendable` because the notifier may run on any
    /// thread that `setCount` happens to be called from.
    typealias BadgeChangeNotifier = @Sendable (Int) -> Void

    private let lock = NSLock()
    private let store: KeyValueStore
    private let host: BadgeHost
    private let notifier: BadgeChangeNotifier?

    init(
        store: KeyValueStore,
        host: BadgeHost = SystemBadgeHost(),
        notifier: BadgeChangeNotifier? = nil
    ) {
        self.store = store
        self.host = host
        self.notifier = notifier
    }

    /// Persisted current count. Returns 0 when unset.
    func getCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        let raw = store.getString(Self.keyBadgeCount) ?? "0"
        return Int(raw) ?? 0
    }

    /// Convenience read mirroring Android's `currentCount()`.
    func currentCount() -> Int { return getCount() }

    /// Write `count` to the OS badge + persist + notify.
    ///
    /// Negative counts are clamped to 0 — the OS treats negatives as 0
    /// silently; normalizing at the SDK boundary avoids a
    /// "set -5, get 0" surprise.
    ///
    /// Returns `true` on success. Mirrors RN's `Promise<boolean>` return
    /// shape. The iOS path never throws — the OS APIs are
    /// completion-handler-only and we don't surface their (rare) errors.
    ///
    /// **Eventual consistency on iOS 13-15:** the persisted cache is
    /// updated synchronously, so subsequent `getCount()` calls return
    /// the new value immediately. The OS-visible icon overlay on the
    /// home screen, however, is async-dispatched to the main actor (the
    /// iOS 13-15 `UIApplication.shared.applicationIconBadgeNumber`
    /// setter requires main). Tests that need to observe the icon
    /// overlay (rare — usually only humans look at it) must wait a
    /// runloop tick. iOS 16+ uses `UNUserNotificationCenter.setBadgeCount`
    /// which is async with a completion handler and handles its own
    /// dispatch. Caught 2026-05-18 — Bug 15 in the senior-engineer audit
    /// (no behavior change; loud documentation instead of silent race).
    @discardableResult
    func setCount(_ count: Int) -> Bool {
        let normalized = max(0, count)
        lock.lock()
        store.putString(Self.keyBadgeCount, String(normalized))
        lock.unlock()
        host.setBadge(normalized)
        notifier?(normalized)
        return true
    }

    // MARK: - Persistence keys

    /// Persistence key for the badge count. Distinct from the
    /// credentials store sub-keys so a credential wipe doesn't reset
    /// the badge.
    internal static let keyBadgeCount: String = "swan_badge_count"
}

/// Test seam — wraps the iOS OS-level badge APIs. Production uses
/// ``SystemBadgeHost``; tests inject a fake that records every set call.
internal protocol BadgeHost: Sendable {
    func setBadge(_ count: Int)
    func currentBadge() -> Int
}

/// Production host — picks the right OS API per iOS version.
///
/// - iOS 16+: `UNUserNotificationCenter.current().setBadgeCount(_:)`.
///   Async (completion handler); we fire-and-forget — the cached count
///   in the service is the source of truth for `getCount()`.
/// - iOS 13–15: `UIApplication.shared.applicationIconBadgeNumber = N`.
///   Must run on the main actor.
internal final class SystemBadgeHost: BadgeHost, @unchecked Sendable {
    init() {}

    func setBadge(_ count: Int) {
        // Defensive: skip OS calls in non-app processes (e.g.
        // `swift test` running under `xctest`). Same posture as
        // ``SystemNotificationCategoryHost``. A real iOS app's bundle
        // ends in `.app`; the xctest CLI ends in nothing.
        let bundleExt = Bundle.main.bundleURL.pathExtension.lowercased()
        guard bundleExt == "app" || bundleExt == "appex" else {
            SwanLogger.debug("SystemBadgeHost.setBadge: skipped (host not an .app/.appex bundle)")
            return
        }
        #if os(iOS)
        if #available(iOS 16.0, *) {
            #if canImport(UserNotifications)
            UNUserNotificationCenter.current().setBadgeCount(count) { error in
                if let error = error {
                    SwanLogger.warn("BadgeService.setBadge(\(count)) failed: \(error)")
                }
            }
            #endif
        } else {
            // iOS 13–15 — must run on the main actor.
            #if canImport(UIKit)
            if Thread.isMainThread {
                UIApplication.shared.applicationIconBadgeNumber = count
            } else {
                DispatchQueue.main.async {
                    UIApplication.shared.applicationIconBadgeNumber = count
                }
            }
            #endif
        }
        #endif
    }

    func currentBadge() -> Int {
        #if os(iOS) && canImport(UIKit)
        if Thread.isMainThread {
            return UIApplication.shared.applicationIconBadgeNumber
        }
        // Defensive — sync-dispatching to main from non-main can deadlock
        // if caller already holds a lock that main is waiting on. Callers
        // SHOULD use the SDK's cached `BadgeService.getCount()` instead;
        // this path exists for completeness only.
        var result = 0
        DispatchQueue.main.sync {
            result = UIApplication.shared.applicationIconBadgeNumber
        }
        return result
        #else
        return 0
        #endif
    }
}
