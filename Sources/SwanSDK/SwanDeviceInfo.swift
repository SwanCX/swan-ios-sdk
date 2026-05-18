import Foundation

/// Snapshot of the SDK's view of the host device.
///
/// Returned by ``Swan/getDeviceInfo()``. Carries the static device
/// fingerprint the SDK auto-enriches every event with, plus the persisted
/// device-registration identifiers, plus the last ``Swan/updateLocation(latitude:longitude:accuracy:)``
/// payload if any.
///
/// ## Identifier vs CDID
///
/// - ``generatedCDID``: the anonymous identifier the backend issued at
///   device-register time. Stable for the install lifetime; survives
///   logout. `nil` only until the first device-register completes.
/// - ``currentCDID``: the logged-in identifier set by
///   ``Swan/identify(identifier:attributes:)-93pxw`` on profile-switch
///   success. `nil` for anonymous users; reset to `nil` by
///   ``Swan/logout()``.
/// - ``identifier``: the external user identifier the host app last
///   passed to `identify` (email, phone, loyalty ID). `nil` for
///   anonymous users.
///
/// ## Threading
///
/// Safe to read from any thread. ``Swan/getDeviceInfo()`` is a
/// synchronous snapshot — repeated reads may return different
/// `currentCDID` values if an identify / logout call races.
/// The ``Swan/addSwanIdentifierChangedListener(_:)`` event surface is the
/// canonical way to observe identifier transitions.
public struct SwanDeviceInfo: Equatable, Sendable {
    /// Always `"ios"` on this platform.
    public let platform: String

    /// iOS system version string (e.g. `"17.0"`). Matches the `osModal`
    /// wire field.
    public let osModal: String

    /// Hardware model identifier (e.g. `"iPhone15,2"`). Matches the
    /// `deviceModal` wire field — same string `react-native-device-info`
    /// returns for `getModel()`.
    public let deviceModal: String

    /// Always `"Apple"` on this platform. Mirrors the `deviceBrand` wire
    /// field across SDKs.
    public let deviceBrand: String

    /// Persisted device id from the `/v2/device/register` response. `nil`
    /// until the first device-register round-trip completes.
    public let deviceId: String?

    /// Anonymous customer-derived id minted by the backend at
    /// device-register time. `nil` until the first device-register
    /// completes.
    public let generatedCDID: String?

    /// Logged-in customer id, set by ``Swan/identify(identifier:attributes:)-93pxw``
    /// on profile-switch success. `nil` for anonymous users / post-logout.
    public let currentCDID: String?

    /// External user identifier last asserted via ``Swan/identify(identifier:attributes:)-93pxw``.
    /// `nil` for anonymous users / post-logout.
    public let identifier: String?

    /// Last-known device location, if any. `nil` until
    /// ``Swan/updateLocation(latitude:longitude:accuracy:)`` has been
    /// called at least once.
    public let location: SwanLocation?

    public init(
        platform: String,
        osModal: String,
        deviceModal: String,
        deviceBrand: String,
        deviceId: String?,
        generatedCDID: String?,
        currentCDID: String?,
        identifier: String?,
        location: SwanLocation?
    ) {
        self.platform = platform
        self.osModal = osModal
        self.deviceModal = deviceModal
        self.deviceBrand = deviceBrand
        self.deviceId = deviceId
        self.generatedCDID = generatedCDID
        self.currentCDID = currentCDID
        self.identifier = identifier
        self.location = location
    }
}
