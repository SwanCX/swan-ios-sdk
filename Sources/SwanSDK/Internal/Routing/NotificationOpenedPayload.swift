import Foundation

/// Payload delivered to host apps when a Swan notification is tapped.
///
/// **Capabilities:** `deeplink-url`, `deeplink-key-value`.
///
/// Spec:
///   - `spec/api/push.yaml#NotificationOpenedPayload`
///   - `spec/wire/push-payload-fcm.yaml#FcmDataField`
///   - `conformance/scenarios/deeplink-url.feature`
///   - `conformance/scenarios/deeplink-key-value.feature`
///
/// Wire-byte-equivalent to the Android `NotificationOpenedPayload` and the RN
/// `NotificationOpenedPayload` (RN src/index.tsx:180). `route` is the
/// user-facing deep-link target — either a path (`/products/123`) OR a full
/// URL with scheme (`https://example.com/p/1`, `myapp://offer/abc`).
///
/// `keyValuePairs` is the parsed JSON object from the wire
/// `data.keyValuePairs` string (RN's `parseKeyValuePairs`,
/// src/index.tsx:113). Empty / missing / invalid input yields an empty map
/// — NEVER nil — matching RN's `keyValuePairs: Record<string, any>`
/// required-with-default invariant.
///
/// `extras` carries the remaining fields from the APNs / FCM `data`
/// surface that are NOT among the canonical fields the SDK consumes
/// (title, body, route, defaultRoute, keyValuePairs, messageId). Per
/// `spec/locked-decisions.md` this MUST include `oneLinkParams` /
/// `oneLinkConfig` end-to-end without any SDK parsing — host apps own
/// AppsFlyer integration, the SDK is a pass-through.
public struct NotificationOpenedPayload: Equatable, Sendable {

    /// Deep link route — either a path (`/products/123`) or a full URL
    /// (`https://example.com/p/1`, `myapp://offer/abc`). `nil` when the
    /// underlying payload had no route field (empty string is normalized
    /// to `nil` so host apps can use a single nil-check).
    public let route: String?

    /// Notification title (`data.title`).
    public let title: String?

    /// Notification body (`data.body`).
    public let body: String?

    /// Custom key-value pairs parsed from `data.keyValuePairs` (a
    /// JSON-encoded string on the wire). Always non-nil — empty
    /// dictionary when the field is absent, empty, or fails to parse.
    /// Values flow through ``JSONValue`` so primitives + nested
    /// objects / arrays survive without forcing host apps to re-parse.
    public let keyValuePairs: [String: JSONValue]

    /// Remaining `data` fields the SDK does not consume directly. Preserved
    /// end-to-end without SDK parsing — host apps reach for
    /// `oneLinkParams`, `oneLinkConfig`, future v2 `actions`, and any
    /// custom fields here. Values are the raw on-wire strings (FCM
    /// enforces map<string,string>; APNs userInfo is coerced to the same
    /// shape).
    public let extras: [String: String]

    public init(
        route: String?,
        title: String?,
        body: String?,
        keyValuePairs: [String: JSONValue],
        extras: [String: String]
    ) {
        self.route = route
        self.title = title
        self.body = body
        self.keyValuePairs = keyValuePairs
        self.extras = extras
    }
}
