import Foundation

/// Allowed ACK event values. Backend (index.js:20-33) lower-cases input,
/// so case is normalized on the wire.
///
/// **Capability:** `delivery-click-ack` (Phase 1.16 port).
///
/// v1 emits `delivered` and `clicked`. `showed` is reserved for in-app
/// (deferred to v2 per spec/scope-v1.md). `failed` is accepted by the
/// backend but never emitted by RN — kept for future telemetry parity.
enum AckEvent: String, Equatable {
    case delivered
    case clicked
}

/// Wire payload for `/mobile-push-tracking`.
///
/// **Capability:** `delivery-click-ack` (Phase 1.16 port).
///
/// Spec: `spec/wire/notification-ack.yaml#AckPayload`. Mirrors RN's
/// `payload` build in `sendEventBatch` (src/index.tsx:1819-1829) and
/// the cold-start direct-ack body (src/index.tsx:5144-5150).
///
/// Backend (shopify-communications-webhook/WEBHOOK-MOBILE-PUSH-HTTP/index.js)
/// destructures EXACTLY `{CDID, commId, event, appId}`. `deviceId`, `type`,
/// `linkId` are silently ignored on the wire but emitted for RN parity.
///
/// Field ordering on the wire is fixed to match the RN golden:
///   `commId, appId, CDID, event, deviceId, type?, linkId?`
/// `type` and `linkId` are appended only when non-empty (RN:
/// `if (type) payload.type = type` / `if (linkId) payload.linkId = linkId`).
struct AckPayload: Equatable {
    let commId: String
    let appId: String
    let CDID: String
    let event: AckEvent
    let deviceId: String
    /// Set ONLY when the click originated from a deep-link tap. RN: `'deepLink'`.
    let type: String?
    /// Set with [type] when the deep-link URL carried `swan_link_id`.
    let linkId: String?

    init(
        commId: String,
        appId: String,
        CDID: String,
        event: AckEvent,
        deviceId: String,
        type: String? = nil,
        linkId: String? = nil
    ) {
        self.commId = commId
        self.appId = appId
        self.CDID = CDID
        self.event = event
        self.deviceId = deviceId
        self.type = type
        self.linkId = linkId
    }

    /// Encode to a JSON object dictionary in canonical field order.
    /// Returned as `[String: Any]` (ordered insertion isn't preserved by
    /// `JSONSerialization`, but field PRESENCE order is what the
    /// byte-shape test asserts on the parsed tree — see RN-PARITY.md).
    ///
    /// Visible for tests so the wire test asserts on the encoded JSON
    /// without a FakeTransport round-trip.
    func toJsonObject() -> [String: Any] {
        var obj: [String: Any] = [:]
        obj["commId"] = commId
        obj["appId"] = appId
        obj["CDID"] = CDID
        obj["event"] = event.rawValue
        obj["deviceId"] = deviceId
        if let type = type, !type.isEmpty { obj["type"] = type }
        if let linkId = linkId, !linkId.isEmpty { obj["linkId"] = linkId }
        return obj
    }

    /// Serialize to bytes — uses `JSONSerialization` rather than
    /// `Codable` so the empty-string drop rule for `type` / `linkId` is
    /// trivially expressible.
    func toJsonData() throws -> Data {
        return try JSONSerialization.data(
            withJSONObject: toJsonObject(),
            options: []
        )
    }
}
