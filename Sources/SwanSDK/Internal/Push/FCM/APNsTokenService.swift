import Foundation

/// Orchestrates the APNs token lifecycle on iOS.
///
/// **Capability:** `push-fcm-ios` (Phase 1.15 port).
///
/// Spec:
///   - `spec/api/push.yaml` `/sdk/getPushToken`, `/sdk/unsubscribePush`
///   - `spec/wire/push-subscription.yaml`
///   - `spec/behavior/push.yaml` — state machine
///   - `conformance/scenarios/push-fcm-android.feature` — same wire
///     contract; iOS port satisfies it
///
/// Mirrors Android's `FcmTokenService.kt` — same state machine, same
/// idempotence rules, same persistence ordering (POST first, then save
/// the token).
///
/// # iOS-vs-Android divergence
///
/// - **No `FcmTokenProvider`.** Android pulls the token from
///   FirebaseMessaging.getInstance().token; iOS receives it from the OS
///   via `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`
///   and the host app forwards it to ``Swan/registerAPNsToken(_:)``.
///   There is no SDK-driven "fetch" step. The state machine
///   correspondingly drops the `Initializing → Ready` transitions and
///   starts at ``APNsPushState/notReady``.
/// - **No `onTokenRefreshed`.** APNs tokens DO rotate (rare; usually on
///   device backup-restore or app reinstall). The host app picks up the
///   new token from the same UIApplicationDelegate callback and re-calls
///   ``registerToken(_:)`` — which goes through the same path. There's
///   no SDK-internal listener like Firebase's `onNewToken`.
/// - **`requestToken()` not exposed.** Android's `requestToken` fetches
///   from Firebase; the iOS equivalent (`UIApplication.shared.registerForRemoteNotifications()`)
///   is a host-app concern that requires the entitlement + permission
///   prompt. We don't wrap it.
///
/// # State machine wire-up
///
/// - `notReady → tokenPending` on [registerToken] before the POST resolves
/// - `tokenPending → ready(token)` on successful subscribe
/// - `tokenPending → failed` on subscribe failure
/// - `ready → tokenPending` on a re-`registerToken` with a different
///   token (rotation)
/// - `ready / failed → unsubscribed` on [unsubscribe] success
///
/// # Idempotence
///
/// Re-subscribing with the same token short-circuits — the service reads
/// ``CredentialsStore/pushNotificationToken`` before POSTing and skips
/// the network call when the token matches AND the state is already
/// ``APNsPushState/ready``. RN parity: RN doesn't short-circuit, but the
/// wire repetition is wasteful and the backend tolerates dup-subscribe.
/// Strictly more useful than RN — surfaced in the port report.
final class APNsTokenService {

    private let subscriptionService: PushSubscriptionService
    private let credentialsStore: CredentialsStore
    private let telemetry: PushTelemetryEmitter

    /// Serial state lock — every read/write to `_state` flows through.
    /// AsyncStream continuations notified outside the lock.
    private let lock = NSLock()
    private var _state: APNsPushState = .notReady

    init(
        subscriptionService: PushSubscriptionService,
        credentialsStore: CredentialsStore,
        telemetry: PushTelemetryEmitter = NullPushTelemetryEmitter()
    ) {
        self.subscriptionService = subscriptionService
        self.credentialsStore = credentialsStore
        self.telemetry = telemetry
    }

    /// Snapshot read — `true` when state is ``APNsPushState/ready``.
    /// Mirrors Android's `FcmTokenService.isReady()`.
    func isReady() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if case .ready = _state { return true }
        return false
    }

    /// Returns the current token (in-memory or persisted), or `nil`.
    /// Mirrors Android's `currentToken()`.
    func currentToken() -> String? {
        lock.lock()
        let s = _state
        lock.unlock()
        if case .ready(let token) = s { return token }
        return credentialsStore.read()?.pushNotificationToken
    }

    /// Current state snapshot — exposed for tests + debug.
    func currentState() -> APNsPushState {
        lock.lock(); defer { lock.unlock() }
        return _state
    }

    /// Register a host-supplied APNs token. Synchronously transitions to
    /// `tokenPending`, then awaits the subscribe POST and transitions to
    /// `ready` / `failed`.
    ///
    /// - Idempotent: re-calling with the same token while state is `.ready`
    ///   AND the persisted token matches is a no-op.
    /// - Pre-registration: if credentials aren't loaded yet, returns a
    ///   failure with ``PushSubscriptionError/credentialsNotLoaded`` and
    ///   transitions to `.failed`. Mirrors Android.
    @discardableResult
    func registerToken(_ token: String) async -> Result<String?, Error> {
        if token.isEmpty {
            let err = PushSubscriptionError.blankToken
            telemetry.emitPushTokenRegistrationFailed(error: err)
            return .failure(err)
        }

        guard let cached = credentialsStore.read() else {
            // Mirror Android: state → .failed, surface a credentials-not-loaded
            // error. Host should re-call after deviceRegistered.
            let err = PushSubscriptionError.credentialsNotLoaded
            setState(.failed(error: .init(err)))
            telemetry.emitPushTokenRegistrationFailed(error: err)
            return .failure(err)
        }

        // Idempotence — same token, already-ready state, persisted match.
        // Snapshot the state under the lock for the check.
        let snapshot: APNsPushState = {
            lock.lock(); defer { lock.unlock() }
            return _state
        }()
        if case .ready(let activeToken) = snapshot,
           activeToken == token,
           cached.pushNotificationToken == token {
            SwanLogger.debug("APNsTokenService.registerToken: token unchanged; skipping POST")
            return .success(token)
        }

        setState(.tokenPending)
        let result = await subscriptionService.subscribe(token: token)
        switch result {
        case .success:
            // Persist the token AFTER success so a crash mid-subscribe
            // doesn't leave a stale token in storage.
            credentialsStore.save(cached.withFields(pushNotificationToken: .some(token)))
            setState(.ready(token: token))
            telemetry.emitPushTokenRegistered(token: token)
            SwanLogger.debug("APNsTokenService: token registered + persisted")
            return .success(token)
        case .failure(let err):
            setState(.failed(error: .init(err)))
            telemetry.emitPushTokenRegistrationFailed(error: err)
            SwanLogger.warn("APNsTokenService.registerToken failed: \(err.localizedDescription)")
            return .failure(err)
        }
    }

    /// Revoke push subscription. Mirrors Android's `unsubscribe()`:
    /// POSTs revoke, clears the persisted token, transitions to
    /// `.unsubscribed`. Best-effort — network failure does NOT block the
    /// local clear (RN parity).
    @discardableResult
    func unsubscribe() async -> Result<Bool, Error> {
        guard let cached = credentialsStore.read() else {
            // Nothing to do; not registered.
            return .success(false)
        }
        let result = await subscriptionService.unsubscribe()
        // Clear local state regardless of network outcome.
        credentialsStore.save(cached.withFields(pushNotificationToken: .some(nil)))
        setState(.unsubscribed)
        switch result {
        case .success:
            return .success(true)
        case .failure(let err):
            // RN parity — the local state still clears. Surface the
            // wire error to the caller for diagnostics.
            SwanLogger.warn("APNsTokenService.unsubscribe wire POST failed: \(err.localizedDescription)")
            return .failure(err)
        }
    }

    /// Process a raw incoming push (warm-start delivery path).
    /// Currently a thin no-op pass-through — full processing flows
    /// through A19's router. Kept on the Swan facade so the host app
    /// can wire `application(_:didReceiveRemoteNotification:fetchCompletionHandler:)`
    /// today; per-notification rendering ships in v2.
    func handleIncoming(userInfo: [AnyHashable: Any]) {
        // Extract a structured payload + fan out to the
        // pushNotificationReceived listener (fires foreground-only;
        // background pushes get routed through the tap path
        // independently).
        guard userInfo["aps"] != nil || userInfo["gcm.message_id"] != nil else {
            SwanLogger.debug("APNsTokenService.handleIncoming: no APNs/FCM keys in userInfo; ignoring")
            return
        }
        SwanLogger.debug("APNsTokenService.handleIncoming: received remote notification payload")
        guard let bridge = telemetry as? BridgedPushTelemetryEmitter else {
            return // Null/test variant; nothing to emit.
        }
        let payload = Self.extractReceivedPayload(from: userInfo)
        bridge.emitNotificationReceived(payload)
    }

    /// Parse an inbound APNs `userInfo` dictionary into a
    /// ``PushNotificationReceivedPayload``. Extracts title/body from
    /// `aps.alert` (string OR dictionary), `messageId` from
    /// `gcm.message_id` / `aps.id` / `messageId`, and flattens any
    /// non-system keys into a `[String: String]` data map.
    internal static func extractReceivedPayload(
        from userInfo: [AnyHashable: Any]
    ) -> PushNotificationReceivedPayload {
        let aps = userInfo["aps"] as? [AnyHashable: Any] ?? [:]
        var title: String?
        var body: String?
        if let alertString = aps["alert"] as? String {
            body = alertString
        } else if let alertDict = aps["alert"] as? [AnyHashable: Any] {
            title = alertDict["title"] as? String
            body = alertDict["body"] as? String
        }

        let messageId: String? = {
            if let raw = userInfo["gcm.message_id"] as? String { return raw }
            if let raw = aps["id"] as? String { return raw }
            if let raw = userInfo["messageId"] as? String { return raw }
            return nil
        }()

        var data: [String: String] = [:]
        for (key, value) in userInfo {
            guard let key = key as? String, key != "aps" else { continue }
            if let strValue = value as? String {
                data[key] = strValue
            } else if let numValue = value as? NSNumber {
                data[key] = numValue.stringValue
            }
        }

        return PushNotificationReceivedPayload(
            messageId: messageId,
            title: title,
            body: body,
            data: data
        )
    }

    /// Test seam — reset state to `.notReady`.
    func resetForTests() {
        setState(.notReady)
    }

    private func setState(_ value: APNsPushState) {
        lock.lock()
        _state = value
        lock.unlock()
    }
}

// MARK: - APNs token utilities

/// APNs hex-string encoding helpers. Hot path is one call per app
/// launch; performance is not a concern.
enum APNsTokenEncoder {
    /// `UIApplication.registerForRemoteNotifications()` callback hands
    /// us a `Data` blob (typically 32 bytes). Swan's backend expects the
    /// lower-case hex string without separators.
    static func hexString(from data: Data) -> String {
        return data.map { String(format: "%02x", $0) }.joined()
    }
}
