import Foundation

/// Push subsystem state — iOS.
///
/// **Capability:** `push-fcm-ios` (Phase 1.15 port).
///
/// Spec:
///   - `spec/behavior/push.yaml` — state machine
///   - `spec/api/push.yaml` `/sdk/getPushToken`
///
/// Mirrors Android's `FcmPushState` and RN's `PushStateMachine`
/// (src/state/PushStateMachine.ts). The iOS subsystem differs slightly:
/// there is no "Initializing" phase that fetches a token (Firebase
/// Messaging is NOT used — we accept the APNs token from the host app),
/// so we drop straight to `notReady → tokenPending → ready` once
/// ``Swan/registerAPNsToken(_:)`` is called.
///
/// The state is observable via ``Swan/isPushReady()`` (returns `true`
/// when state is ``ready``). Transitions are driven by
/// ``APNsTokenService``; v1 does not expose the raw state machine.
enum APNsPushState: Equatable {

    /// Subsystem not yet wired (SDK not initialized, or host app has not
    /// supplied an APNs token).
    case notReady

    /// Token received from the OS but not yet POSTed to Swan backend.
    /// Transient — flips to `.ready` on subscribe success, `.failed` on
    /// subscribe error.
    case tokenPending

    /// Token persisted + synced with backend.
    case ready(token: String)

    /// Token fetch / subscribe POST failed. Recoverable via retry.
    case failed(error: PushFailure)

    /// Host called ``Swan/unsubscribePush()``; token cleared locally. SDK
    /// keeps queueing other events; no token sync until
    /// ``Swan/registerAPNsToken(_:)`` is called again.
    case unsubscribed

    /// Hashable equality on `error` requires a typed wrapper —
    /// `Swift.Error` isn't `Equatable`. Tests compare states by case,
    /// not by the underlying error chain.
    struct PushFailure: Equatable {
        let message: String
        init(_ error: Error) {
            self.message = error.localizedDescription
        }
        init(message: String) {
            self.message = message
        }
    }

    /// Equality: ignore the token / error contents when comparing
    /// cases — tests typically assert on the case alone via
    /// `XCTAssertEqual(state.caseTag, ".ready")`. Full equality (incl.
    /// token contents) available via direct member comparison.
    static func == (lhs: APNsPushState, rhs: APNsPushState) -> Bool {
        switch (lhs, rhs) {
        case (.notReady, .notReady),
             (.tokenPending, .tokenPending),
             (.unsubscribed, .unsubscribed):
            return true
        case (.ready(let a), .ready(let b)):
            return a == b
        case (.failed(let a), .failed(let b)):
            return a == b
        default:
            return false
        }
    }
}
