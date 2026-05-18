import Foundation

/// Unified deep-link event payload — emitted for ALL deep-link sources, not
/// just push. v1 only fires the push-source variant; email / sms /
/// direct-deepLink sources are reserved for v2.
///
/// **Capabilities:** `deeplink-url`, `deeplink-key-value`.
///
/// Spec:
///   - `spec/api/push.yaml#DeepLinkOpenedPayload`
///   - `conformance/scenarios/deeplink-url.feature` (HTTPS URL route also
///     emits DEEP_LINK_OPENED with source=push)
///   - `conformance/scenarios/deeplink-key-value.feature` (keyValuePairs +
///     oneLink* pass-through reach this surface alongside NOTIFICATION_OPENED)
///
/// Wire-byte-equivalent to the Android `DeepLinkOpenedPayload` and the RN
/// `DeepLinkOpenedPayload` (RN src/index.tsx:196).
public struct DeepLinkOpenedPayload: Equatable, Sendable {

    /// Deep link route (path or full URL).
    public let route: String?

    /// Source of the deep link. v1 only emits ``Source/push``.
    public let source: Source

    /// Custom key-value pairs (parsed from `data.keyValuePairs`).
    public let keyValuePairs: [String: JSONValue]

    /// Remaining `data` fields, preserved verbatim.
    public let extras: [String: String]

    public init(
        route: String?,
        source: Source,
        keyValuePairs: [String: JSONValue],
        extras: [String: String]
    ) {
        self.route = route
        self.source = source
        self.keyValuePairs = keyValuePairs
        self.extras = extras
    }

    /// Origin of the deep-link tap. The `rawValue` is the byte-equivalent
    /// wire string used by Android + RN.
    public enum Source: String, Equatable, Sendable {
        case push
        case email
        case sms
        case deepLink
    }
}
