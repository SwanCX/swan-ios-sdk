import Foundation

/// Typed shape for a single carousel item, parsed from one element of
/// `data.carouselItems` (which itself is a JSON-encoded string on the wire,
/// see `spec/wire/push-payload-fcm.yaml#FcmDataField.carouselItems`).
///
/// Per-item shape (Joi-validated, communications/validations/push.js:26-31):
///   `{ imageUrl: string, title: string, body: string, route: string }`
/// — each defaulting to "" on the wire. RN
/// `CarouselTemplate.kt:144` reads via `optString("imageUrl", "")` etc; we
/// mirror the empty-string default semantics here.
internal struct CarouselItem: Equatable {
    let imageUrl: String
    let title: String
    let body: String
    let route: String
}

/// Filmstrip vs standard carousel variant.
///
/// Wire constant `data.carouselVariant` (push-payload-fcm.yaml).
internal enum CarouselVariant: String, Equatable {
    /// Standard ViewFlipper-style carousel (RN CarouselRemoteViews).
    case standard
    /// 3-image filmstrip preview (RN CarouselFilmstripRemoteViews).
    case filmstrip

    static let WIRE_STANDARD = "standard"
    static let WIRE_FILMSTRIP = "filmstrip"

    static func from(_ raw: String?) -> CarouselVariant {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return trimmed == WIRE_FILMSTRIP ? .filmstrip : .standard
    }
}

/// Notification template the SDK should render for an inbound APNs / FCM
/// data payload. Mirrors Android `NotificationTemplate`.
///
/// Maps from the wire field `data.notificationType` (see
/// `spec/wire/push-payload-fcm.yaml#FcmDataField.notificationType`).
///
/// RN parity (`swan-react-native-sdk/android/.../CarouselTemplate.kt:27`):
/// the carousel wire constant is `"carousel"`. RN has no `BASIC` enum — it
/// just falls through `Notifee.displayNotification` when the type is
/// missing. We promote that fallback to a first-class enum value
/// (`.basic`) for cleaner dispatch.
internal enum NotificationTemplate: Equatable {
    /// Standard title / body / optional image. The default when
    /// `data.notificationType` is missing or unknown.
    case basic

    /// Carousel where the user swipes between images. Wire signal:
    /// `data.notificationType == "carousel"` AND
    /// `data.carouselMode` ∈ {null, "manual"}.
    case carouselManual

    /// Auto-advancing carousel. Wire signal:
    /// `data.notificationType == "carousel"` AND
    /// `data.carouselMode == "auto"`.
    case carouselAuto

    /// Wire constant `data.notificationType == "carousel"`.
    static let WIRE_TYPE_CAROUSEL: String = "carousel"

    /// Wire constants for `data.carouselMode`.
    static let WIRE_CAROUSEL_MODE_MANUAL: String = "manual"
    static let WIRE_CAROUSEL_MODE_AUTO: String = "auto"

    /// Resolve which template a given data map should render.
    ///
    /// Tolerant of unknown `notificationType` values — unknown types
    /// degrade to ``basic`` rather than dropping the push.
    static func from(_ data: [String: String]) -> NotificationTemplate {
        let type = (data["notificationType"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if type.lowercased() != WIRE_TYPE_CAROUSEL { return .basic }

        let mode = (data["carouselMode"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if mode == WIRE_CAROUSEL_MODE_AUTO { return .carouselAuto }
        // RN parity: `mode ?: "manual"` (CarouselTemplate.kt:131). Any
        // non-"auto" value (including missing / blank / "manual" /
        // "standard") routes to manual.
        return .carouselManual
    }
}

/// Typed, parsed view of an inbound carousel data payload.
///
/// Constructed by ``CarouselPayloadParser/parse(_:)``. Reading
/// `carouselItems` off the wire involves decoding a JSON-encoded string
/// into an array; we do that here rather than at render time so unit
/// tests can exercise the parsing separately from any platform-bound
/// render path.
///
/// Filmstrip note: per `spec/wire/push-payload-fcm.yaml` lines 209-213 +
/// RN `CarouselTemplate.kt:560`, the filmstrip variant filters items with
/// empty `imageUrl`. We apply that filter here (in parsing) so renderers
/// receive a pre-filtered list. Standard + auto variants keep items with
/// empty `imageUrl` because RN's flipper still allocates the slot.
internal struct CarouselPayload: Equatable {
    let items: [CarouselItem]
    /// One of ``NotificationTemplate/carouselManual`` /
    /// ``NotificationTemplate/carouselAuto``.
    let mode: NotificationTemplate
    let variant: CarouselVariant
    let intervalMs: Int
    let defaultRoute: String

    /// RN parity: `data.carouselInterval ?: 3000` (CarouselTemplate.kt:133).
    static let DEFAULT_INTERVAL_MS: Int = 3000

    /// RN parity: `parseItems(...).take(10)` (CarouselTemplate.kt:561).
    static let MAX_ITEMS: Int = 10
}

/// Pure parser — turns a notification `data` map into a typed
/// ``CarouselPayload``.
///
/// No platform dependencies on the parse path. The `carouselItems` JSON
/// decode is the only non-trivial work; we tolerate all the same wire
/// shapes RN does:
///   - missing / blank `carouselItems` → empty list
///   - non-array JSON → empty list
///   - individual array elements missing fields → fall back to "" per field
///   - `carouselInterval` parses string → Int; on parse failure use
///     ``CarouselPayload/DEFAULT_INTERVAL_MS``.
internal enum CarouselPayloadParser {

    /// Parse the `data` map into a ``CarouselPayload``.
    ///
    /// Returns `nil` when the map is not actually a carousel — i.e.
    /// `data.notificationType != "carousel"`. Use this as a guard before
    /// dispatching to the carousel renderer.
    static func parseIfCarousel(_ data: [String: String]) -> CarouselPayload? {
        let template = NotificationTemplate.from(data)
        if template == .basic { return nil }
        return parse(data, template: template)
    }

    private static func parse(
        _ data: [String: String],
        template: NotificationTemplate
    ) -> CarouselPayload {
        let variant = CarouselVariant.from(data["carouselVariant"])
        let rawItems = parseItems(data["carouselItems"] ?? "")
        // RN CarouselTemplate.kt:560 — filmstrip filters empty imageUrl.
        let filtered = variant == .filmstrip
            ? rawItems.filter { !$0.imageUrl.isEmpty }
            : rawItems
        let limited = Array(filtered.prefix(CarouselPayload.MAX_ITEMS))
        let intervalRaw = (data["carouselInterval"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let intervalMs = Int(intervalRaw) ?? CarouselPayload.DEFAULT_INTERVAL_MS

        return CarouselPayload(
            items: limited,
            mode: template,
            variant: variant,
            intervalMs: intervalMs,
            defaultRoute: data["defaultRoute"] ?? ""
        )
    }

    /// Decode the JSON-encoded `carouselItems` string into ``CarouselItem``s.
    ///
    /// Returns an empty list on any parse failure — matches RN's posture
    /// (`CarouselTemplate.kt:556-565` catch + log + return emptyList).
    /// NEVER throws.
    static func parseItems(_ rawJson: String) -> [CarouselItem] {
        let trimmed = rawJson.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }
        guard let asData = trimmed.data(using: .utf8) else { return [] }
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: asData, options: [.fragmentsAllowed])
        } catch {
            SwanLogger.warn("CarouselPayloadParser: failed to parse carouselItems: \(error)")
            return []
        }
        guard let array = parsed as? [Any] else { return [] }
        return array.compactMap { element -> CarouselItem? in
            guard let obj = element as? [String: Any] else { return nil }
            return CarouselItem(
                imageUrl: stringOrEmpty(obj["imageUrl"]),
                title: stringOrEmpty(obj["title"]),
                body: stringOrEmpty(obj["body"]),
                route: stringOrEmpty(obj["route"])
            )
        }
    }

    /// Mirrors RN `optString("k", "")`: primitives (number / boolean /
    /// string) are stringified; `NSNull` / non-primitives → "".
    private static func stringOrEmpty(_ value: Any?) -> String {
        guard let value = value else { return "" }
        if value is NSNull { return "" }
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return ""
    }

    /// Resolve the deep-link route for the carousel item at `index`, with
    /// the outer-`defaultRoute` fallback that RN encodes at
    /// `CarouselTemplate.kt:251` (`itemRoute.ifEmpty { defaultRoute }`).
    static func routeForItem(_ payload: CarouselPayload, index: Int) -> String {
        guard index >= 0, index < payload.items.count else {
            return payload.defaultRoute
        }
        let item = payload.items[index]
        return item.route.isEmpty ? payload.defaultRoute : item.route
    }
}
