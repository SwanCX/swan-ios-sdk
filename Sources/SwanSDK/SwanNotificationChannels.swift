import Foundation

/// Public constants for the five predefined Swan notification channel ids
/// (Android-OS terminology) / category ids (iOS terminology). Cross-platform
/// equivalents — same string values everywhere.
///
/// On Android the SDK auto-creates these as `NotificationChannel`s at init.
/// On iOS they register as `UNNotificationCategory` ids the campaign payload
/// can reference. Host apps reference these constants when building payloads
/// or asserting on received pushes.
///
/// ## Channels
///
/// | Constant | Wire id |
/// |---|---|
/// | ``transactional`` | `swan_transactional` (high importance — orders, OTPs) |
/// | ``alerts`` | `swan_alerts` (high importance — critical alerts) |
/// | ``promotional`` | `swan_promotional` (default — marketing) |
/// | ``general`` | `swan_general` (default — general updates) |
/// | ``default`` | `swan_notifications` (fallback when payload omits id) |
public enum SwanNotificationChannels {
    /// High-priority channel — orders, OTPs, urgent updates.
    public static let transactional: String = "swan_transactional"

    /// High-priority channel — critical alerts, warnings.
    public static let alerts: String = "swan_alerts"

    /// Default-priority channel — marketing, offers, deals.
    public static let promotional: String = "swan_promotional"

    /// Default-priority channel — general updates, news.
    public static let general: String = "swan_general"

    /// Fallback channel id used when payload omits `channelId`.
    public static let `default`: String = "swan_notifications"

    /// The full set of predefined channel ids. Useful for tests and
    /// host-app guard checks.
    public static let all: [String] = [
        transactional,
        alerts,
        promotional,
        general,
        `default`,
    ]
}
