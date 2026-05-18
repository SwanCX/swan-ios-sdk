import Foundation

/// Result returned by the planned ``Swan/login(identifier:attributes:)``
/// API.
///
/// The login flow flushes the queue before the profile switch so
/// anonymous events aren't attributed to the new identity post-switch.
/// On success the result carries the resolved CDID and a flag indicating
/// whether the backend actually switched profiles (`profileSwitched =
/// true`) or recognised the call as a repeat-login for the same
/// identifier (`profileSwitched = false`).
public struct LoginResult: Equatable, Sendable {
    /// The user's resolved CDID after the login call. `nil` only on
    /// transient backend failures where the SDK couldn't read a CDID
    /// from the response.
    public let cdid: String?

    /// `true` when the server reported the login triggered a server-side
    /// profile switch (i.e. the SDK is now bound to a different customer
    /// profile than before). `false` for repeat-login calls with the
    /// same identifier and for best-effort failure fallbacks.
    public let profileSwitched: Bool

    public init(cdid: String?, profileSwitched: Bool) {
        self.cdid = cdid
        self.profileSwitched = profileSwitched
    }
}
