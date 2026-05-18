import Foundation

/// Host-app configuration for ``Swan/initialize(appId:baseUrl:config:)``.
///
/// ## Fields
///
/// - ``debug`` (default `false`) — gate the SDK's internal debug logs.
///   When `true`, ``Swan``'s internal `debug` / `info` traces are
///   emitted; when `false`, they are suppressed. Warnings + errors are
///   NEVER suppressed.
///
/// - ``production`` (default `true`) — informational on iOS (the
///   `baseUrl` argument controls the actual endpoint). Set to `false`
///   for dev/staging builds you want flagged as such.
///
/// - ``pushNotifications`` — opt-in/opt-out gate for the push subsystem.
///   Default `.init(enabled: true)`. When disabled, the SDK skips the
///   APNs registration on init and ignores inbound pushes.
///
/// - ``location`` — opt-in flag for the location-tagging surface.
///   Default `.init(enabled: false)` — host apps explicitly opt in to
///   tag events with coordinates via
///   ``Swan/updateLocation(latitude:longitude:accuracy:)``.
///
/// - ``appGroup`` — App Group identifier shared between the host app
///   and any Notification Service Extension that wants to fire
///   killed-state delivery ACKs via
///   ``Templates/handleServiceRequest(request:content:appGroup:completion:)``.
///   Default `nil` (App Group disabled). When set, the SDK persists
///   credentials into `UserDefaults(suiteName: appGroup)` so the NSE
///   process can read them.
public struct SwanConfig: Equatable, Sendable {

    /// Whether the SDK emits its internal debug/info logs.
    ///
    /// Warnings + errors are NEVER suppressed. Default `false`.
    public let debug: Bool

    /// `true` selects production posture; `false` selects dev/staging
    /// posture. Default `true`.
    public let production: Bool

    /// Push subsystem gate.
    public let pushNotifications: PushNotificationsConfig

    /// Location-tagging gate. Host apps opt in by setting
    /// `enabled: true` and then calling
    /// ``Swan/updateLocation(latitude:longitude:accuracy:)`` with their
    /// own coordinates.
    public let location: LocationConfig

    /// App Group identifier (e.g. `"group.com.yourcompany.app"`) for
    /// cross-process credential sharing between the host app and any
    /// Notification Service Extension. Default `nil` — App Group
    /// disabled, NSE-side delivery ACKs are no-op.
    ///
    /// **Setup:**
    ///
    /// 1. Add the **App Groups** capability to both the host app
    ///    target and the NSE target in Xcode, with the same identifier.
    /// 2. Pass the identifier here.
    /// 3. In your NSE, call
    ///    ``Templates/handleServiceRequest(request:content:appGroup:completion:)``
    ///    with the same identifier.
    ///
    /// When set, the SDK migrates existing credentials from the
    /// per-process suite to the App Group suite on first init and writes
    /// every credential change to the App Group going forward.
    public let appGroup: String?

    public init(
        debug: Bool = false,
        production: Bool = true,
        pushNotifications: PushNotificationsConfig = .default,
        location: LocationConfig = .default,
        appGroup: String? = nil
    ) {
        self.debug = debug
        self.production = production
        self.pushNotifications = pushNotifications
        self.location = location
        self.appGroup = appGroup
    }

    /// Default config — debug disabled, production = true, push opt-in
    /// (enabled), location opt-out (disabled), no App Group.
    public static let `default`: SwanConfig = SwanConfig()
}

/// Push-notifications config block on ``SwanConfig``.
public struct PushNotificationsConfig: Equatable, Sendable {

    /// Master gate for the push subsystem. Default `true` (opt-out).
    public let enabled: Bool

    public init(enabled: Bool = true) {
        self.enabled = enabled
    }

    public static let `default`: PushNotificationsConfig = PushNotificationsConfig()
}

/// Location-tracking config block on ``SwanConfig``.
public struct LocationConfig: Equatable, Sendable {

    /// Master gate for the location-tagging surface. Default `false`
    /// (opt-in). Surfaced via ``Swan/isLocationEnabled()``.
    ///
    /// The SDK does NOT acquire location itself — host apps call
    /// ``Swan/updateLocation(latitude:longitude:accuracy:)`` with their
    /// own coordinates. This flag is a documented opt-in so host apps
    /// can branch on ``Swan/isLocationEnabled()`` to decide whether to
    /// compute coordinates.
    public let enabled: Bool

    public init(enabled: Bool = false) {
        self.enabled = enabled
    }

    public static let `default`: LocationConfig = LocationConfig()
}
