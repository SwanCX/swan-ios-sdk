import Foundation

/// Push-token telemetry emitter interface.
///
/// **Capability:** `push-fcm-ios`.
///
/// The protocol was originally a stub when A19's `TelemetryEmitter`
/// didn't yet exist; the production bridge below now flows the events
/// into the unified telemetry stream, surfaced via
/// ``Swan/addPushTokenRegisteredListener(_:)``,
/// ``Swan/addPushTokenRegistrationFailedListener(_:)``, and
/// ``Swan/addPushTokenRefreshListener(_:)``.
protocol PushTelemetryEmitter: AnyObject {
    /// Fired exactly once when ``APNsTokenService/registerToken(_:)``
    /// resolves with success.
    func emitPushTokenRegistered(token: String)
    /// Fired on any subscribe / token failure inside the orchestrator.
    func emitPushTokenRegistrationFailed(error: Error)
}

/// Default no-op. Used by test bootstraps that don't need lifecycle
/// fan-out.
final class NullPushTelemetryEmitter: PushTelemetryEmitter {
    func emitPushTokenRegistered(token: String) {}
    func emitPushTokenRegistrationFailed(error: Error) {}
}

/// Production wiring — bridges ``APNsTokenService`` emits into the
/// unified ``TelemetryEmitter`` so host apps can subscribe via the
/// public Swan listener surfaces.
///
/// Tracks the most recently emitted token internally so the "refresh"
/// surface fires only when a NEW token replaces a previous one (initial
/// registration fires "registered" only, NOT "refresh" — matches
/// Android's `addPushTokenRefreshListener` semantic).
final class BridgedPushTelemetryEmitter: PushTelemetryEmitter, @unchecked Sendable {
    private let telemetry: TelemetryEmitter
    private let lock = NSLock()
    private var lastEmittedToken: String?

    init(telemetry: TelemetryEmitter) {
        self.telemetry = telemetry
    }

    func emitPushTokenRegistered(token: String) {
        lock.lock()
        let priorToken = lastEmittedToken
        lastEmittedToken = token
        lock.unlock()
        telemetry.emit(PushTokenRegisteredPayload(token: token))
        if let prior = priorToken, prior != token {
            telemetry.emit(PushTokenRefreshPayload(token: token))
        }
    }

    func emitPushTokenRegistrationFailed(error: Error) {
        telemetry.emit(PushTokenRegistrationFailedPayload(error: error))
    }

    /// Emit a foreground push received event. Used by
    /// ``APNsTokenService/handleIncoming(userInfo:)`` after parsing.
    /// Stream posture — no buffer.
    func emitNotificationReceived(_ payload: PushNotificationReceivedPayload) {
        telemetry.emit(payload)
    }
}
