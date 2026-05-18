import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif

/// Implements the `notification-permission` capability on iOS.
///
/// **Capability:** `notification-permission` (Phase 1.11 iOS port).
///
/// Spec:
///   - `spec/api/push.yaml` `/sdk/requestNotificationPermission`,
///     `/sdk/hasNotificationPermission`
///   - `spec/behavior/push.yaml`
///   - `conformance/scenarios/notification-permission.feature` —
///     "requestNotificationPermission on iOS triggers APNs authorization"
///
/// Mirrors RN's `requestNotificationPermission()` (src/index.tsx:3942) +
/// `hasNotificationPermission()` (src/index.tsx:3913) +
/// `PushTokenService.requestPermission` (src/services/PushTokenService.ts:73)
/// lifecycle-event emission, and the Android Phase 1.11
/// ``NotificationPermissionService`` behavior.
///
/// # Behavior
///
/// - **iOS 10+ (effectively always on iOS 13+ floor)**: dispatches the
///   `UNUserNotificationCenter.requestAuthorization` API with
///   `[.alert, .badge, .sound]`. The OS handles "already-granted /
///   already-denied" implicitly — the closure fires synchronously with
///   the cached decision.
/// - **`hasNotificationPermission()`** reads
///   `UNUserNotificationCenter.getNotificationSettings()` and reports
///   `authorizationStatus == .authorized || == .provisional` as true.
///   `.notDetermined` and `.denied` map to false.
/// - **Lifecycle events**: on every decision the service emits exactly
///   ONE of ``PushLifecycleEvent/permissionGranted`` or
///   ``PushLifecycleEvent/permissionDenied`` to all registered
///   listeners — mirrors RN + Android.
///
/// # iOS vs Android divergences
///
/// - **No "Activity context" concept on iOS.** The Android port had to
///   guard against being called from a non-Activity context;
///   `UNUserNotificationCenter` is callable from anywhere (process-level
///   singleton). The "bad context" branch from Android collapses to a
///   no-op on iOS.
/// - **`UNAuthorizationStatus.provisional` (iOS 12+)**: treated as
///   granted for the host-app surface. Provisional auth is "quiet
///   delivery" — notifications post to Notification Center without
///   alerting; from the SDK's perspective the OS is happy to deliver,
///   so callers see "granted". RN's iOS bridge treats provisional the
///   same way.
/// - **`.ephemeral` (iOS 14+, App Clips)**: treated as denied since
///   ephemeral is App-Clip-only and the swan-sdks main SDK runs in full
///   apps; granting on the App Clip side doesn't carry to the main app
///   anyway.
///
/// # Threading
///
/// `requestNotificationPermission()` is `async` — the
/// `UNUserNotificationCenter.requestAuthorization` completion handler
/// is wrapped in a continuation. Listener fan-out runs on whatever
/// queue UN delivers on (typically a private serial queue); host apps
/// that touch UI in listeners must marshal to the main actor themselves.
internal final class NotificationPermissionService: @unchecked Sendable {

    typealias Listener = @Sendable (PushLifecycleEvent) -> Void

    private let lock = NSLock()
    private var listeners: [Listener] = []
    private let gate: NotificationAuthorizationGate

    init(gate: NotificationAuthorizationGate = SystemNotificationAuthorizationGate()) {
        self.gate = gate
    }

    /// Subscribe to permission lifecycle events.
    ///
    /// Returns an unregister closure that removes the listener.
    /// Listeners receive `permissionGranted` or `permissionDenied` on
    /// every decision — regardless of whether the OS dialog was
    /// actually shown (already-granted fast-path still fires
    /// `permissionGranted` so host-app state machines stay coherent).
    @discardableResult
    func addListener(_ listener: @escaping Listener) -> () -> Void {
        lock.lock()
        listeners.append(listener)
        let idx = listeners.count - 1
        lock.unlock()
        return { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            // Swift closures can't be compared for identity. Index-based
            // removal is unsafe across mutations, so re-scan by closure
            // bit-cast — same compromise as `NotificationRouter`.
            _ = idx
            let target = unsafeBitCast(listener as AnyObject, to: Int.self)
            if let foundIdx = self.listeners.firstIndex(where: {
                unsafeBitCast($0 as AnyObject, to: Int.self) == target
            }) {
                self.listeners.remove(at: foundIdx)
            }
            self.lock.unlock()
        }
    }

    /// Snapshot read of current OS notification-permission state.
    func hasNotificationPermission() async -> Bool {
        return await gate.isAuthorized()
    }

    /// Prompt the user for notification permission.
    ///
    /// Resolution table:
    /// ```
    ///  status .notDetermined  → request → OS prompt → grant/deny per user
    ///  status .denied         → no prompt; return false  permissionDenied
    ///  status .authorized     → no prompt; return true   permissionGranted
    ///  status .provisional    → no prompt; return true   permissionGranted
    ///  status .ephemeral      → no prompt; return false  permissionDenied
    /// ```
    @discardableResult
    func requestNotificationPermission() async -> Bool {
        let granted = await decideAndPrompt()
        emit(granted ? .permissionGranted : .permissionDenied)
        return granted
    }

    private func decideAndPrompt() async -> Bool {
        // Read current status first. RN does this implicitly via
        // PermissionsAndroid / UN; we surface the read so already-granted
        // / already-denied flows can short-circuit the prompt.
        let status = await gate.currentStatus()
        switch status {
        case .authorized, .provisional:
            return true
        case .denied, .ephemeral:
            return false
        case .notDetermined:
            return await gate.requestAuthorization()
        }
    }

    private func emit(_ event: PushLifecycleEvent) {
        lock.lock()
        let snapshot = listeners
        lock.unlock()
        for listener in snapshot {
            listener(event)
        }
    }
}

/// Stable enum modeling the iOS `UNAuthorizationStatus` — decoupled from
/// the framework so unit tests can simulate every state without an
/// instance of `UNUserNotificationCenter`.
///
/// `.ephemeral` (iOS 14+) is collapsed into the same denied semantics on
/// the SDK side because App-Clip ephemeral auth doesn't carry to the
/// main app.
internal enum NotificationAuthorizationSnapshot {
    case notDetermined
    case denied
    case authorized
    case provisional
    case ephemeral
}

/// Test seam — wraps `UNUserNotificationCenter`. Production uses
/// ``SystemNotificationAuthorizationGate``; tests inject their own
/// implementation.
internal protocol NotificationAuthorizationGate: Sendable {
    func currentStatus() async -> NotificationAuthorizationSnapshot
    func isAuthorized() async -> Bool
    func requestAuthorization() async -> Bool
}

/// Production gate — backed by `UNUserNotificationCenter.current()`.
///
/// Compiled only when `UserNotifications` is available (always true on
/// iOS 13+; available on macOS 10.14+ + tvOS / watchOS — sample-app
/// macOS target gets it for free).
internal final class SystemNotificationAuthorizationGate: NotificationAuthorizationGate, @unchecked Sendable {

    init() {}

    func currentStatus() async -> NotificationAuthorizationSnapshot {
        #if canImport(UserNotifications)
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized: return .authorized
        case .provisional: return .provisional
        case .ephemeral: return .ephemeral
        @unknown default:
            // Future statuses default to notDetermined so the SDK re-prompts
            // rather than locking the host app out.
            return .notDetermined
        }
        #else
        return .notDetermined
        #endif
    }

    func isAuthorized() async -> Bool {
        let s = await currentStatus()
        return s == .authorized || s == .provisional
    }

    func requestAuthorization() async -> Bool {
        #if canImport(UserNotifications)
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .badge, .sound])
        } catch {
            SwanLogger.warn(
                "requestNotificationPermission: UN authorization error: \(error)"
            )
            return false
        }
        #else
        return false
        #endif
    }
}

/// Push-lifecycle events emitted by ``NotificationPermissionService`` (and,
/// in future versions, by the broader push pipeline once `push-fcm-ios`
/// lands).
///
/// Mirrors the RN `pushService.on('permissionGranted' | 'permissionDenied')`
/// surface (src/index.tsx:586) and the Android `PushLifecycleEvent` — the
/// raw value strings are byte-equal so a host app porting between
/// platforms can copy the listener-name strings verbatim.
public enum PushLifecycleEvent: String, Equatable, Sendable {
    case permissionGranted
    case permissionDenied
}
