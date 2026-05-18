import Foundation

/// Wire DTOs for `/device/push-subscription`.
///
/// **Capability:** `push-fcm-ios` (Phase 1.15 port).
///
/// Spec:
///   - `spec/wire/push-subscription.yaml`
///   - `spec/wire/golden/push-subscription-subscribe.json`
///   - `spec/wire/golden/push-subscription-unsubscribe.json`
///
/// Two payload shapes — subscribe (`status: "updated"`) and revoke
/// (`status: "revoked"`). Backend takes the unsubscribe branch when
/// `subscription === null`. Field ordering matches the Android +
/// RN call sites so the LZW64-compressed body decodes to byte-equal
/// JSON across all three SDKs.
///
/// Modeled with `Encodable` (not `Codable`) — we never decode these
/// types; backend responses follow a different schema
/// (``PushSubscriptionResponse``).

/// Subscribe / Unsubscribe body — a single Encodable type with an
/// optional `subscription` block. RN parity: `subscription` is non-nil
/// for subscribe, `null` for unsubscribe; backend branches on it.
struct PushSubscriptionRequest: Encodable {

    /// `nil` → backend takes the unsubscribe branch. The encoder emits
    /// `subscription: null` (matches RN's golden where the field is
    /// explicitly `null`, not absent).
    let subscription: PushSubscriptionBlock?
    /// `"updated"` for subscribe, `"revoked"` for unsubscribe. Backend
    /// doesn't enum-check this but the spec golden pins the literal.
    let status: String
    /// ISO 8601 UTC for subscribe, `nil` for unsubscribe.
    let subscribedAt: String?
    /// ISO 8601 UTC for unsubscribe, `nil` for subscribe.
    let unSubscribedAt: String?
    /// RN field name. `deviceActivatedAt` not separately persisted by the
    /// iOS port (matches Android — see PushSubscriptionService kdoc).
    /// `nil` drops out of the encoded payload to match the spec golden's
    /// null-or-missing tolerance.
    let linkedAt: String?
    /// `currentCDID ?? generatedCDID` resolved at POST time. Capitalized
    /// for RN parity — `CodingKeys` below pins the wire name.
    let CDID: String
    /// `"mobile"` on iOS. Backend defaults missing/empty to `"web"`.
    let device: String

    enum CodingKeys: String, CodingKey {
        case subscription
        case status
        case subscribedAt
        case unSubscribedAt
        case linkedAt
        case CDID
        case device
    }

    /// Custom encode so `subscription = nil` emits an explicit
    /// `subscription: null` rather than omitting the key entirely.
    /// Backend's unsubscribe branch keys on `subscription === null`.
    /// `linkedAt` / `subscribedAt` / `unSubscribedAt` follow the
    /// opposite rule (drop when nil, matching RN's
    /// `JSON.stringify` undefined-omission behavior).
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if subscription != nil {
            try c.encode(subscription, forKey: .subscription)
        } else {
            try c.encodeNil(forKey: .subscription)
        }
        try c.encode(status, forKey: .status)
        if let v = subscribedAt { try c.encode(v, forKey: .subscribedAt) }
        if let v = unSubscribedAt { try c.encode(v, forKey: .unSubscribedAt) }
        if let v = linkedAt { try c.encode(v, forKey: .linkedAt) }
        try c.encode(CDID, forKey: .CDID)
        try c.encode(device, forKey: .device)
    }
}

/// Subscribe block — non-nil for `status: "updated"`, nil for revoke.
struct PushSubscriptionBlock: Encodable {
    /// Hex-encoded APNs device token (iOS) or FCM token (Android). On
    /// iOS, lower-case hex without separators per APNs convention.
    let pushNotificationToken: String
    let subscribed: Bool
    /// `"ios"` or `"android"`.
    let lastLoginPlatform: String
    let sdkCapabilities: PushSdkCapabilities
}

/// `sdkCapabilities` block — backend gates its data-only push pipeline
/// on `dataOnlyPush === true`. Locked decision per `spec/locked-decisions.md`.
struct PushSdkCapabilities: Encodable {
    let dataOnlyPush: Bool
    let version: String
}

/// Backend response — `{ "message": "Success", "success": true }`.
/// Only checked for truthy. Decoded for type safety; missing fields
/// are tolerated.
struct PushSubscriptionResponse: Decodable {
    let success: Bool?
    let message: String?
}
