import Foundation

/// Payload delivered to every ``Swan/addSwanIdentifierChangedListener(_:)``
/// callback when the Swan identifier transitions.
///
/// Fires on identify (with `.identify`), logout (with `.logout`), and
/// future v2 login flows (with `.profileSwitch`). The identifier value
/// itself is the same string ``Swan/swanIdentifier`` would return at the
/// moment of emission — the new `currentCDID` after identify, or the
/// anonymous `generatedCDID` after logout.
public struct SwanIdentifierChangedPayload: Equatable, Sendable {
    /// The new Swan identifier — same string ``Swan/swanIdentifier``
    /// would return at the moment of emission. Never empty at emit time.
    public let swanIdentifier: String

    /// What triggered the change.
    public let source: Source

    public init(swanIdentifier: String, source: Source) {
        self.swanIdentifier = swanIdentifier
        self.source = source
    }

    /// The transition that triggered the listener emission.
    public enum Source: String, Equatable, Sendable {
        /// Fired from ``Swan/identify(identifier:attributes:)-93pxw`` after
        /// a profile switch persists.
        case identify

        /// Fired from ``Swan/logout()`` after the local CDID reverts to
        /// anonymous.
        case logout

        /// Reserved for v2's full `login()` API. Unused in v1 — included
        /// for forward-compatibility of the callback signature.
        case profileSwitch
    }
}
