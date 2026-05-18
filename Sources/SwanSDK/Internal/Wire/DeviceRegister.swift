import Foundation

/// Wire models for `POST /v2/device/register`.
///
/// Spec: `spec/wire/device-register.yaml`
/// Goldens: `spec/wire/golden/device-register-{fresh,response}.json`
///
/// v1 only. Fields from spec marked unused (e.g. `pushNotificationToken`,
/// `pushPermissionPreference`) are NOT modeled here — they belong to the
/// push-subscription capability port.
///
/// Wire-format byte-equivalence with RN (`swan-react-native-sdk@2.7.x`) is
/// the contract. RN sends `{ deviceDetails: { location: {...} }, platform,
/// purpose }`. We do the same.
struct DeviceRegisterRequest: Encodable {
    let deviceDetails: DeviceDetails
    let platform: String  // "ios" | "android"
    let purpose: String   // "register_device" | "update_device"
}

/// `deviceDetails` payload. On `register_device` from a fresh install, RN
/// sends only `{ location: {...} }`. The location object itself can be
/// empty (`{}`) when geolocation is unavailable — matches RN behavior.
struct DeviceDetails: Encodable {
    let location: LocationPayload
}

/// Device location. All fields optional — an empty location is `{}` on
/// the wire, matching RN's `location || {}` spread when geolocation is
/// unavailable.
///
/// Custom `encode(to:)` honors the `omit nulls` invariant without
/// requiring a top-level JSON encoder strategy flag. Foundation's
/// `JSONEncoder` does not have a per-key null-omit flag in iOS 13 (the
/// `.omitNulls` strategy did not land in the public API until later),
/// so we hand-encode keys that are present.
struct LocationPayload: Encodable {
    var latitude: Double?
    var longitude: Double?
    var accuracy: Double?
    /// ISO-8601 string OR unix-ms; spec allows both. RN sends a number
    /// (Date.now()) — native ports may send either form per
    /// `spec/wire/device-register.yaml`.
    var timestamp: String?

    init(
        latitude: Double? = nil,
        longitude: Double? = nil,
        accuracy: Double? = nil,
        timestamp: String? = nil
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.accuracy = accuracy
        self.timestamp = timestamp
    }

    enum CodingKeys: String, CodingKey {
        case latitude, longitude, accuracy, timestamp
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // Only emit non-nil fields. Mirrors Android's
        // `encodeDefaults=false, explicitNulls=false` JSON config and
        // RN's `location || {}` spread.
        if let latitude = latitude { try container.encode(latitude, forKey: .latitude) }
        if let longitude = longitude { try container.encode(longitude, forKey: .longitude) }
        if let accuracy = accuracy { try container.encode(accuracy, forKey: .accuracy) }
        if let timestamp = timestamp { try container.encode(timestamp, forKey: .timestamp) }
    }
}

/// Response from `POST /v2/device/register` (status 201).
///
/// Spec: `spec/wire/golden/device-register-response.json`
///
/// `deviceDoc` kept as a raw `[String: Any]` (decoded via JSONSerialization
/// at the call site) — it is server-managed and free-form, and we don't
/// want to bind the SDK to its evolving shape.
///
/// IMPORTANT: there is NO `first_seen_at` field on the wire. RN fabricates
/// that timestamp client-side; native ports do NOT (per
/// `spec/wire/device-register.yaml:156-159`).
struct DeviceRegisterResponse: Decodable {
    let success: Bool
    let message: String
    let deviceId: String?
    let generatedCDID: String?

    enum CodingKeys: String, CodingKey {
        case success, message, deviceId, generatedCDID
    }
}
