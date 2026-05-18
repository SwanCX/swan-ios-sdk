import Foundation

/// Geo coordinates supplied by the host app via
/// ``Swan/updateLocation(latitude:longitude:accuracy:)``.
///
/// The SDK does NOT acquire location itself — host apps call
/// `updateLocation` with their own coordinates. This keeps the SDK
/// dependency-free of CoreLocation and gives the host app full control
/// over when the OS permission prompt fires.
public struct SwanLocation: Equatable, Sendable {
    /// Latitude in WGS-84 decimal degrees.
    public let latitude: Double

    /// Longitude in WGS-84 decimal degrees.
    public let longitude: Double

    /// Horizontal accuracy in meters at 68% confidence. `nil` when the
    /// host app didn't supply it.
    public let accuracy: Double?

    /// Capture timestamp in epoch milliseconds. Defaults to the SDK
    /// clock at `updateLocation` call time so host apps don't need to
    /// supply it.
    public let timestamp: Int64

    public init(
        latitude: Double,
        longitude: Double,
        accuracy: Double? = nil,
        timestamp: Int64
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.accuracy = accuracy
        self.timestamp = timestamp
    }
}
