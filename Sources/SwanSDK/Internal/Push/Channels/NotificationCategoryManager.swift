import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif

/// Descriptor for an iOS notification category. iOS-side equivalent of
/// Android's `NotificationChannelDescriptor` — same field names where
/// they make sense so cross-platform host code reads the same.
///
/// **Field divergences vs Android:**
/// - `importance` is intentionally OMITTED. iOS doesn't have per-
///   category importance — `UNNotificationCategory` only carries action
///   buttons + presentation options. On the wire we still accept an
///   `importance` parameter for parity, but it's IGNORED on iOS.
/// - `description` is OMITTED too — iOS doesn't surface category
///   descriptions to users (the OS Settings doesn't list categories).
internal struct NotificationCategoryDescriptor: Hashable {
    /// Stable id — matches the Android channel id. Five predefined ids:
    /// `swan_transactional`, `swan_alerts`, `swan_promotional`,
    /// `swan_general`, `swan_notifications`.
    let id: String

    /// User-visible name. Not surfaced by the OS on iOS (kept for parity
    /// + diagnostics).
    let name: String

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// Orchestrator for the `notification-channels` capability on iOS.
///
/// @impl notification-channels
///
/// Spec:
///   - `spec/api/push.yaml` `getNotificationChannelId` /
///     `createNotificationChannel` / `deleteNotificationChannel`
///   - `conformance/scenarios/notification-channels.feature`
///
/// # iOS vs Android conceptual difference (CRITICAL)
///
/// On Android, `NotificationChannel` carries OS-level importance + sound +
/// vibration settings. The OS exposes the channels to the user in
/// Settings → Notifications → <App> → Notification categories.
///
/// **On iOS, `UNNotificationCategory` is a DIFFERENT concept.** It's a
/// grouping for ACTION BUTTONS attached to notifications — not for
/// per-category sound/importance. iOS sets sound + presentation options
/// per-notification via `UNMutableNotificationContent`. Users do NOT see
/// categories listed in iOS Settings.
///
/// The SDK exposes a `channel id` abstraction for cross-platform parity:
///   - `getNotificationChannelId()` returns `"swan_notifications"` on
///     both platforms (RN bug #13 fixed — RN returns `appId` instead of
///     the documented DEFAULT constant).
///   - `createNotificationChannel(id:...)` is a no-op for predefined
///     ids on iOS (the OS doesn't care) but DOES register the category
///     so a downstream `UNMutableNotificationContent.categoryIdentifier`
///     can route to it for action-button rendering.
///   - `deleteNotificationChannel(id:)` refuses to delete predefined
///     ids (load-bearing for backend routing); otherwise removes the
///     category and re-registers the remaining set.
///
/// # RN parity + RN bug catch (#13)
///
/// RN's `getNotificationChannelId()` (src/index.tsx:4043-4045) returns
/// `this.appId` — that's the tenant id, NOT a channel id. The
/// conformance scenario "Default channel id is the documented constant"
/// asserts the result MUST equal `"swan_notifications"` (the documented
/// DEFAULT constant — src/index.tsx:68). The iOS port returns
/// `defaultCategoryId()` which IS the constant. RN bug #13 caught.
///
/// # Mirrors Android Phase 1.18 `NotificationChannelManager`
///
/// Same predefined-five-channels set, same delete-protection rule, same
/// idempotent ensure semantics.
internal final class NotificationCategoryManager {

    private let lock = NSLock()
    private var customCategories: Set<NotificationCategoryDescriptor> = []
    private let host: NotificationCategoryHost

    init(host: NotificationCategoryHost = SystemNotificationCategoryHost()) {
        self.host = host
    }

    /// Register the five predefined Swan categories with
    /// `UNUserNotificationCenter.setNotificationCategories(_:)`.
    ///
    /// Idempotent — safe to call on every `Swan.init`. The OS replaces
    /// the registered set on every call. Custom categories registered
    /// via ``createCategory(_:)`` are preserved across re-runs.
    func ensurePredefinedCategories() {
        lock.lock()
        let merged = Set(Self.predefinedCategories).union(customCategories)
        lock.unlock()
        host.setCategories(merged)
        SwanLogger.debug("NotificationCategoryManager: ensured \(merged.count) categories")
    }

    /// Cross-platform parity hook. iOS doesn't have per-category
    /// importance/sound, so for a predefined id this is effectively a
    /// no-op that returns the id (host apps treat the return value as
    /// "the id is now registered, you can stamp it on
    /// `content.categoryIdentifier`").
    ///
    /// For a custom id the manager merges it into the registered set
    /// and re-pushes the full snapshot to the OS.
    ///
    /// **Returns** the id on success, `nil` on platform-impossible (the
    /// iOS port never returns nil — host apps that call this on iOS get
    /// the id back even if they passed an `importance` value the OS
    /// will ignore).
    @discardableResult
    func createCategory(_ descriptor: NotificationCategoryDescriptor) -> String? {
        if Self.predefinedIds.contains(descriptor.id) {
            return descriptor.id
        }
        lock.lock()
        customCategories.insert(descriptor)
        let merged = Set(Self.predefinedCategories).union(customCategories)
        lock.unlock()
        host.setCategories(merged)
        return descriptor.id
    }

    /// Refuses to delete predefined ids. The SDK depends on them being
    /// present for backend-driven routing (matches Android Phase 1.18).
    ///
    /// Returns `true` when a custom category was removed; `false` for
    /// predefined ids or unknown ids.
    @discardableResult
    func deleteCategory(_ id: String) -> Bool {
        if Self.predefinedIds.contains(id) {
            SwanLogger.warn("NotificationCategoryManager: refusing to delete predefined '\(id)'")
            return false
        }
        lock.lock()
        let removed = customCategories.remove(
            where: { $0.id == id }
        )
        let merged = Set(Self.predefinedCategories).union(customCategories)
        lock.unlock()
        guard removed else { return false }
        host.setCategories(merged)
        return true
    }

    /// Default category id surfaced via
    /// `Swan.shared.getNotificationChannelId()`.
    /// Always `"swan_notifications"` — RN bug #13 fix.
    func defaultCategoryId() -> String {
        return Self.defaultCategoryId
    }

    // MARK: - Predefined set

    /// Matches Android's `DEFAULT_CHANNEL_ID`
    /// (`internal/push/channels/NotificationChannelManager.kt:172`) and
    /// RN's `SWAN_NOTIFICATION_CHANNELS.DEFAULT`
    /// (src/index.tsx:68). Used as the fallback when an FCM payload
    /// omits `data.channelId`.
    internal static let defaultCategoryId: String = "swan_notifications"

    /// The five predefined Swan categories, byte-equal ids with Android.
    /// Names mirror RN's `setupNotificationHandlers` strings
    /// (src/utils/FirebaseNotificationManager.ts:235-267).
    internal static let predefinedCategories: [NotificationCategoryDescriptor] = [
        NotificationCategoryDescriptor(id: "swan_transactional", name: "Transactional"),
        NotificationCategoryDescriptor(id: "swan_alerts", name: "Alerts"),
        NotificationCategoryDescriptor(id: "swan_promotional", name: "Promotional"),
        NotificationCategoryDescriptor(id: "swan_general", name: "General"),
        NotificationCategoryDescriptor(id: defaultCategoryId, name: "Notifications"),
    ]

    /// Hot-path lookup set for delete-protection. Derived from
    /// ``predefinedCategories``.
    internal static let predefinedIds: Set<String> = Set(predefinedCategories.map { $0.id })
}

/// Test seam — wraps `UNUserNotificationCenter.setNotificationCategories(_:)`.
/// Production uses ``SystemNotificationCategoryHost``; tests inject a
/// fake that captures the registered set.
internal protocol NotificationCategoryHost: Sendable {
    func setCategories(_ categories: Set<NotificationCategoryDescriptor>)
    func currentCategoryIdentifiers() -> Set<String>
}

/// Production host — backed by
/// `UNUserNotificationCenter.current().setNotificationCategories(_:)`.
///
/// Note: `UNUserNotificationCenter` is process-level shared state.
/// Unlike the Android `NotificationManager` which is bound to a
/// `Context`, the iOS host doesn't need a host-app reference.
internal final class SystemNotificationCategoryHost: NotificationCategoryHost, @unchecked Sendable {
    init() {}

    func setCategories(_ categories: Set<NotificationCategoryDescriptor>) {
        #if canImport(UserNotifications)
        // Defensive: `UNUserNotificationCenter.current()` raises
        // NSInternalInconsistencyException("bundleProxyForCurrentProcess
        // is nil") on `swift test` runs whose host process is `xctest`
        // (a CLI binary, not an app bundle). Detect that by checking
        // the bundle URL's path extension — a real app bundle ends in
        // `.app`. Tests that need to exercise `Swan.shared.initialize`
        // don't crash before they can finish.
        let bundleExt = Bundle.main.bundleURL.pathExtension.lowercased()
        guard bundleExt == "app" || bundleExt == "appex" else {
            SwanLogger.debug("SystemNotificationCategoryHost.setCategories: skipped (host not an .app/.appex bundle)")
            return
        }
        let unCategories: Set<UNNotificationCategory> = Set(categories.map {
            UNNotificationCategory(
                identifier: $0.id,
                actions: [],        // v1 has no action buttons (spec/extensibility.md §1 reserves it for v2)
                intentIdentifiers: [],
                options: []
            )
        })
        UNUserNotificationCenter.current().setNotificationCategories(unCategories)
        #endif
    }

    func currentCategoryIdentifiers() -> Set<String> {
        #if canImport(UserNotifications)
        // UN doesn't expose a sync read; callers that need this would
        // await `getNotificationCategories(completionHandler:)`. For v1
        // the SDK is the only writer, so we hand back an empty set — the
        // manager tracks its own custom-id set in-memory.
        return []
        #else
        return []
        #endif
    }
}

// Helper extension — `Set.remove(where:)` isn't part of stdlib.
private extension Set where Element == NotificationCategoryDescriptor {
    mutating func remove(where predicate: (Element) -> Bool) -> Bool {
        if let toRemove = self.first(where: predicate) {
            self.remove(toRemove)
            return true
        }
        return false
    }
}
