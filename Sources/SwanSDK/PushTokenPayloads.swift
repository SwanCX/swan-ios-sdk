import Foundation

/// Payload delivered to ``Swan/addPushTokenRegisteredListener(_:)`` —
/// fires every time the APNs token is successfully registered with the
/// Swan backend.
///
/// Token registration is **idempotent on the same token** — re-calling
/// ``Swan/registerAPNsToken(_:)`` with the same bytes the SDK already
/// holds short-circuits to a success without re-emitting (matches
/// Android `addPushTokenRegisteredListener` semantics).
public struct PushTokenRegisteredPayload: Equatable, Sendable {
    /// Hex-encoded APNs device token (lowercase, no separators).
    public let token: String

    public init(token: String) {
        self.token = token
    }
}

/// Payload delivered to ``Swan/addPushTokenRegistrationFailedListener(_:)`` —
/// fires every time the SDK's POST to `/device/push-subscription`
/// fails (network error, 4xx, malformed response).
///
/// The SDK continues to function — events still queue locally and the
/// next ``Swan/registerAPNsToken(_:)`` call will retry the subscribe.
public struct PushTokenRegistrationFailedPayload: Sendable {
    /// The error that surfaced from the subscribe attempt. Bridged to
    /// `NSError` for cross-thread sending.
    public let error: Error

    public init(error: Error) {
        self.error = error
    }
}

/// Payload delivered to ``Swan/addPushTokenRefreshListener(_:)`` —
/// fires when the host app re-registers an APNs token that's different
/// from the one the SDK previously persisted.
///
/// Distinct from ``PushTokenRegisteredPayload`` (which fires on every
/// successful registration, including the initial one): refresh fires
/// only on a change. Useful for analytics that want to count actual
/// token rotations, separately from re-registration churn.
public struct PushTokenRefreshPayload: Equatable, Sendable {
    /// The new token. The previous token has already been replaced in
    /// the SDK's persisted credentials at the time the listener fires.
    public let token: String

    public init(token: String) {
        self.token = token
    }
}

// Manual Equatable for the failed-payload — `Error` is not Equatable
// without a domain/code bridge. Same posture as
// `TelemetryEvent.DeviceRegistrationFailedPayload`.
extension PushTokenRegistrationFailedPayload: Equatable {
    public static func == (
        lhs: PushTokenRegistrationFailedPayload,
        rhs: PushTokenRegistrationFailedPayload
    ) -> Bool {
        let lhsNs = lhs.error as NSError
        let rhsNs = rhs.error as NSError
        return lhsNs.domain == rhsNs.domain && lhsNs.code == rhsNs.code
    }
}
