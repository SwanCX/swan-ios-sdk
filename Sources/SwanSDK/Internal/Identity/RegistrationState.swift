import Foundation

/// Device-registration state machine.
///
/// Spec: `spec/behavior/device-registration.yaml`
///
/// Mirrors the RN `DeviceState` enum (state/DeviceStateMachine.ts) and
/// Android's Kotlin sealed class as a Swift enum with associated
/// values — strongly typed with payloads on the success state, an
/// `Error` on failure.
///
/// The internal "registering vs cached short-circuit" distinction is
/// handled inside [Swan.initialize] without exposing it.
public enum RegistrationState {
    /// SDK constructed but `initialize(...)` not yet called.
    case uninitialized

    /// Network call in flight.
    case registering

    /// Device registered (fresh or cached).
    case registered(deviceId: String, generatedCDID: String)

    /// Network / protocol failure. SDK keeps queueing events; retries
    /// on network restore (network-resilience capability — later port).
    case failed(error: Error)
}

extension RegistrationState: Equatable {
    public static func == (lhs: RegistrationState, rhs: RegistrationState) -> Bool {
        switch (lhs, rhs) {
        case (.uninitialized, .uninitialized): return true
        case (.registering, .registering): return true
        case let (.registered(d1, c1), .registered(d2, c2)):
            return d1 == d2 && c1 == c2
        case let (.failed(e1), .failed(e2)):
            return (e1 as NSError) == (e2 as NSError)
        default: return false
        }
    }
}
