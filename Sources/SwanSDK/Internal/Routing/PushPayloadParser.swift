import Foundation

/// Pure parser — turns a notification `data` map (the bag of String→String
/// values FCM enforces on the wire; APNs `userInfo` coerced to the same
/// shape) into a ``NotificationOpenedPayload`` suitable for host delivery.
///
/// **Capabilities:** `deeplink-url`, `deeplink-key-value`.
///
/// **No platform dependencies** so this can be unit-tested without a real
/// `UNNotificationResponse` / `[AnyHashable: Any]` userInfo. The
/// `UNNotificationResponse` adapter lives on the public ``Swan`` API; that
/// surface calls into this parser after extracting the data map.
///
/// Spec:
///   - `spec/wire/push-payload-fcm.yaml#FcmDataField` — canonical wire field list.
///   - `spec/api/push.yaml#NotificationOpenedPayload` — output shape.
///   - `spec/locked-decisions.md` — `oneLinkParams` / `oneLinkConfig` MUST
///     be preserved end-to-end without SDK parsing.
///   - `conformance/scenarios/deeplink-key-value.feature` — keyValuePairs
///     parse semantics + oneLink* pass-through invariants.
///
/// # RN source-of-truth
///
/// - Route resolution (RN src/index.tsx:4755, :4923, :5040, :3682): always
///   `notificationData.route ?? notificationData.defaultRoute` —
///   caller-supplied `route` wins over the spec's fallback `defaultRoute`.
///   Both are present on the data-only path (server emits BOTH with the
///   same value, but the carousel per-item flow REPLACES `route` while
///   leaving `defaultRoute` as the notification-level fallback, hence the
///   explicit precedence).
/// - keyValuePairs parsing (RN src/index.tsx:113): JSON.parse the string,
///   reject non-objects (arrays / primitives → `{}`), swallow parse errors
///   → `{}`. NEVER throws; `keyValuePairs` is always at least an empty map
///   on the delivered payload.
/// - Extras (RN src/index.tsx:4826 `{ ...notificationData, route, ... }`):
///   RN spreads the raw `data` object onto the payload, then overlays the
///   resolved route + parsed keyValuePairs. We keep the unconsumed fields
///   in a separate ``NotificationOpenedPayload/extras`` map for type safety
///   + so the consumed fields (title, body, route, keyValuePairs,
///   defaultRoute) don't leak as stringified duplicates. `messageId` is
///   also stripped — the `delivery-click-ack` capability owns it, and
///   surfacing it here would let host apps accidentally key on the wrong
///   value.
internal enum PushPayloadParser {

    /// Fields the SDK consumes directly — stripped from
    /// ``NotificationOpenedPayload/extras`` so host apps don't see
    /// stringified duplicates of values exposed as first-class properties.
    ///
    /// `messageId` is kept out of extras because the delivery-click-ack
    /// capability owns it as a tracking key; surfacing it here would
    /// invite host apps to key on it for their own dedup, which would
    /// conflict if the ACK key ever rotates.
    private static let consumedKeys: Set<String> = [
        "title",
        "body",
        "route",
        "defaultRoute",
        "keyValuePairs",
        "messageId",
    ]

    /// Resolve the effective deep-link route from the `data` map.
    ///
    /// Returns `nil` when neither `route` nor `defaultRoute` is present, OR
    /// when both are present but empty — host apps consistently nil-check
    /// one value instead of guarding both empty-string and missing.
    static func resolveRoute(_ data: [String: String]) -> String? {
        if let r = data["route"], !r.isEmpty { return r }
        if let d = data["defaultRoute"], !d.isEmpty { return d }
        return nil
    }

    /// Parse the JSON-encoded `keyValuePairs` field into a typed map.
    ///
    /// Mirrors RN's `parseKeyValuePairs` (src/index.tsx:113): returns an
    /// empty map on missing / empty / invalid-JSON / non-object input.
    /// NEVER throws.
    ///
    /// The decoded object's primitives are converted to typed ``JSONValue``
    /// values; nested objects + arrays are recursively decoded so host
    /// apps can navigate them without re-parsing.
    static func parseKeyValuePairs(_ data: [String: String]) -> [String: JSONValue] {
        guard let raw = data["keyValuePairs"], !raw.isEmpty else { return [:] }
        guard let asData = raw.data(using: .utf8) else { return [:] }
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(
                with: asData,
                options: [.fragmentsAllowed]
            )
        } catch {
            SwanLogger.warn("PushPayloadParser: failed to parse keyValuePairs: \(error)")
            return [:]
        }
        // Mirrors RN's explicit non-object rejection (src/index.tsx:118-128).
        // Arrays / primitives → empty map.
        guard let obj = parsed as? [String: Any] else { return [:] }
        var out: [String: JSONValue] = [:]
        for (k, v) in obj {
            out[k] = JSONValue.fromAny(v)
        }
        return out
    }

    /// Build a ``NotificationOpenedPayload`` from a notification `data` map.
    ///
    /// Pure function — no platform types touched, no event emission. The
    /// caller owns delivery (``NotificationRouter`` wires this to listener
    /// callbacks).
    static func buildPayload(_ data: [String: String]) -> NotificationOpenedPayload {
        let route = resolveRoute(data)
        let title = data["title"].flatMap { $0.isEmpty ? nil : $0 }
        let body = data["body"].flatMap { $0.isEmpty ? nil : $0 }
        let keyValuePairs = parseKeyValuePairs(data)
        var extras: [String: String] = [:]
        for (k, v) in data where !consumedKeys.contains(k) {
            extras[k] = v
        }
        return NotificationOpenedPayload(
            route: route,
            title: title,
            body: body,
            keyValuePairs: keyValuePairs,
            extras: extras
        )
    }

    /// Returns `true` if `route` is a fully-qualified URL — has a scheme
    /// followed by `://`. Used to decide whether to also treat the route as
    /// URL-shaped at the host-app level (per
    /// `conformance/scenarios/deeplink-url.feature` "HTTPS URL route also
    /// emits DEEP_LINK_OPENED").
    ///
    /// Note: RN's `emitDeepLinkOpened` fires for EVERY notification tap
    /// (with source=push) regardless of route shape
    /// (RN src/index.tsx:847-852). We mirror that broader emission in
    /// ``NotificationRouter`` — this helper exists for tests / future
    /// filtering needs but the v1 router does NOT gate on it.
    static func isUrlRoute(_ route: String?) -> Bool {
        guard let route = route, !route.isEmpty else { return false }
        // Trim leading whitespace check — Android version uses
        // `route.isNullOrBlank()`. Mirror by stripping ASCII whitespace.
        let trimmed = route.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return false }
        guard let schemeEnd = trimmed.range(of: "://") else { return false }
        let scheme = trimmed[..<schemeEnd.lowerBound]
        if scheme.isEmpty { return false }
        guard let first = scheme.first, first.isLetter else { return false }
        // RFC 3986: scheme = ALPHA *( ALPHA / DIGIT / "+" / "-" / "." )
        for ch in scheme {
            let ok = ch.isLetter || ch.isNumber || ch == "+" || ch == "-" || ch == "."
            if !ok { return false }
        }
        return true
    }
}

/// Adapter for the APNs `userInfo` dictionary
/// (`[AnyHashable: Any]` shape, the standard
/// `UNNotificationResponse.notification.request.content.userInfo` surface).
///
/// FCM (when integrated via Firebase Messaging for iOS) merges its data
/// dictionary into `userInfo` at top-level. APNs-only senders that mirror
/// the FCM data shape ship the same keys at the same level. This adapter
/// flattens both into the `[String: String]` shape the
/// [PushPayloadParser] expects.
///
/// Non-String values are skipped — FCM enforces map<string,string> on the
/// wire, and APNs payloads coming from the comms backend stamp every
/// custom field as a string (`PUSH-HTTP/index.js:132` JSON-stringifies
/// JSON-shaped fields before send).
///
/// The standard APNs `aps` payload key (which holds the OS-rendering
/// alert/badge/sound block) is dropped from the resulting map — the SDK
/// doesn't surface those rendering hints on the tap payload, and they're
/// not String values anyway (`aps` is a nested dictionary).
internal enum UserInfoAdapter {

    /// Top-level APNs reserved key — host apps never need this in the
    /// `data`-shaped tap surface.
    private static let apnsReservedKeys: Set<String> = [
        "aps",
    ]

    /// Convert a `UNNotificationResponse.notification.request.content.userInfo`
    /// dictionary to the `[String: String]` shape ``PushPayloadParser``
    /// consumes. Non-String values and reserved APNs keys are skipped.
    static func toDataMap(_ userInfo: [AnyHashable: Any]) -> [String: String] {
        var out: [String: String] = [:]
        for (k, v) in userInfo {
            guard let key = k as? String else { continue }
            if apnsReservedKeys.contains(key) { continue }
            if let s = v as? String {
                out[key] = s
            } else if let n = v as? NSNumber {
                // Defensive — some senders may stamp a numeric badge/id.
                // Coerce to canonical string form so the SDK degrades
                // gracefully instead of dropping the key on the floor.
                out[key] = n.stringValue
            }
            // Other types (nested dict, array, NSNull, custom) are skipped
            // — same posture as Android's IntentExtras.fromBundle().
        }
        return out
    }
}
