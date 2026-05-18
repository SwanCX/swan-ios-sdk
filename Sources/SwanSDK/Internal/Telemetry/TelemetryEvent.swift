import Foundation

/// SDK self-telemetry lifecycle events surfaced to the host app.
///
/// **Capability:** `self-telemetry` (Phase 1.14 iOS port).
///
/// Spec:
///   - `conformance/scenarios/self-telemetry.feature`
///   - `spec/catalog.yaml` `self-telemetry` (no dedicated
///     `spec/api/telemetry.yaml` in v1 — see report for the spec gap).
///
/// # RN parity
///
/// RN emits three of the four telemetry-related lifecycle events:
///   - `initialized` — RN src/index.tsx:456 (handled separately by
///     ``Swan/addInitializedListener(_:)``; NOT modeled here because
///     init-config already owns that surface).
///   - `deviceRegistered` — RN src/index.tsx:431 + :1190.
///   - `deviceRegistrationFailed` — RN src/index.tsx:451.
///
/// RN's CLAUDE.md + the conformance scenario also promise
/// `networkStateChanged`, but the RN `NetworkMonitor` never bridges its
/// internal `listeners: Set<...>` (NetworkMonitor.ts) into the public
/// `SwanSDK.emit()` map. This is a confirmed RN bug (see report). The
/// iOS port emits it via ``NetworkStateMonitor`` for parity with the
/// documented contract and the conformance scenario — same as Android.
///
/// # v1 scope (NOT shipping in v1)
///
/// Backend telemetry upload (drop counts, payload sizes) — `@v2 @skipped`
/// scenario in `conformance/scenarios/self-telemetry.feature`. The
/// conformance contract for v1 is explicit: "the SDK does NOT upload
/// self-telemetry to backend in v1". This file deliberately models
/// lifecycle-emit only.
///
/// # Sealed-class hierarchy (Swift)
///
/// Android uses a Kotlin `sealed class`. Swift's equivalent is an `enum`
/// with associated values — same exhaustive-switch ergonomics, same
/// pattern-match safety. The associated values are public structs so
/// host apps can read the fields without unpacking case syntax in their
/// listener bodies (we expose typed listener APIs per case on ``Swan``).
public enum TelemetryEvent: Equatable, Sendable {

    /// Emitted once when device registration completes successfully
    /// (either fresh registration or cached-credentials warm path).
    ///
    /// RN parity: src/index.tsx:431
    /// `this.emit('deviceRegistered', credentials)`. RN passes the full
    /// `DeviceCredentials` object; iOS surfaces only the two identifiers
    /// a host app would actually use (deviceId, generatedCDID) — the
    /// rest of the credentials struct (currentCDID, identifier, appId)
    /// is either accessible via ``Swan/swanIdentifier`` or is not
    /// host-facing.
    case deviceRegistered(DeviceRegisteredPayload)

    /// Emitted once when device registration fails (network error, 4xx,
    /// malformed response). The SDK continues to function — events
    /// queue locally and a retry fires when the network state next
    /// transitions to online.
    ///
    /// RN parity: src/index.tsx:451
    /// `this.emit('deviceRegistrationFailed', error)`. RN passes the
    /// raw `Error` instance; iOS surfaces the underlying `Error`
    /// directly so the host app can log / report it without
    /// recovering structured fields the SDK doesn't itself produce.
    case deviceRegistrationFailed(DeviceRegistrationFailedPayload)

    /// Emitted on every transition between offline and online
    /// connectivity. The payload is the current state — listeners
    /// that need edge-trigger semantics can debounce themselves.
    ///
    /// Catches an RN bug: RN promises this event in its CLAUDE.md and
    /// conformance scenario but never wires it (see ``TelemetryEvent``
    /// doc). Surfaced via the iOS `NWPathMonitor` plumbing in
    /// ``NetworkStateMonitor``.
    case networkStateChanged(NetworkStateChangedPayload)

    /// Payload struct for ``deviceRegistered``.
    public struct DeviceRegisteredPayload: Equatable, Sendable {
        public let deviceId: String
        public let generatedCDID: String
        public init(deviceId: String, generatedCDID: String) {
            self.deviceId = deviceId
            self.generatedCDID = generatedCDID
        }
    }

    /// Payload struct for ``deviceRegistrationFailed``.
    ///
    /// `Error` is not `Equatable`; we bridge to `NSError` for the
    /// derived `Equatable` synthesis on ``TelemetryEvent`` so tests
    /// can compare events with `assertEquals`.
    public struct DeviceRegistrationFailedPayload: Sendable {
        public let error: Error
        public init(error: Error) {
            self.error = error
        }
    }

    /// Payload struct for ``networkStateChanged``.
    public struct NetworkStateChangedPayload: Equatable, Sendable {
        public let isOnline: Bool
        public init(isOnline: Bool) {
            self.isOnline = isOnline
        }
    }
}

extension TelemetryEvent.DeviceRegistrationFailedPayload: Equatable {
    public static func == (
        lhs: TelemetryEvent.DeviceRegistrationFailedPayload,
        rhs: TelemetryEvent.DeviceRegistrationFailedPayload
    ) -> Bool {
        return (lhs.error as NSError) == (rhs.error as NSError)
    }
}
