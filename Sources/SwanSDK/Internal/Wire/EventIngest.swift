import Foundation

/// Wire models for `POST /v2/trackEvent`.
///
/// **Capabilities:** `custom-events`, `semantic-ecommerce-events`.
///
/// Spec:
///   - `spec/wire/event-ingest.yaml`                       (HTTP contract)
///   - `spec/wire/golden/event-ingest-batch.json`          (request shape — Tier 1)
///   - `spec/wire/golden/event-ingest-login-direct.json`   (single-event request)
///   - `spec/wire/golden/event-ingest-response.json`       (response shape)
///
/// Mirrors the body that RN's `sendEventBatch` (src/index.tsx:1641) puts on
/// the wire for the standard-events branch (LZW64-encoded by ``SwanHttpClient``).
///
/// ## RN-PARITY notes
///
///   - `isBatch` is RN-only (backend ignores) but MUST be on the wire —
///     `true` for queue-flushed batches, `false` for synchronous
///     single-event sends (login/logout/identify). The custom-events port
///     only emits `isBatch = true`; `false` is reserved for the
///     identify-login port.
///   - `skipEmission` is NOT on `BatchEvent`. That field belongs to the
///     identify-login port (userLogin event only). Keeping it out of the
///     custom-events model prevents accidental emission.
///   - `currentCDID: null` MUST be on the wire (not omitted) on the
///     anonymous path — backend reads `currentCDID: null` explicitly
///     (eventProcessing.ts:115). Encoded via a custom container instead
///     of `JSONEncoder`'s `keyEncodingStrategy` / `nilEncodingStrategy`
///     because Foundation doesn't expose a per-field null-emit flag on
///     iOS 13.
///
/// Mirror of Android's `EventIngest.kt` (renamed types because Swift
/// doesn't have package-private and we want the public-API surface to
/// stay clean).
internal struct EventBatchPayload: Encodable {
    let common: EventBatchCommon
    let events: [BatchEvent]
    let isBatch: Bool

    enum CodingKeys: String, CodingKey {
        case common, events, isBatch
    }
}

/// Capabilities this SDK advertises to the backend on the `common` block of
/// every tracking request (SWA-7372 / SWA-7343 / SWA-7366).
///
/// `/v2/trackEvent` is shared across all SDKs (RN / iOS / Android / Web), so
/// the backend must NOT infer capability from the (per-platform,
/// non-comparable) `sdkVersion` — the SDK declares it here. This is the SINGLE
/// SOURCE OF TRUTH: every payload built with ``EventBatchCommon`` (batch flush,
/// identify, login, logout) stamps the same list, so the direct-send (logout /
/// login) and batch paths can never drift apart.
///
/// - `anon-cdid-rotation`: this SDK will ADOPT a rotated anonymous CDID
///   returned by `logout()` (the adopt side lives in
///   ``LogoutService/logout()``). Only when the backend sees this flag does it
///   mint + return a fresh anonymous CDID on a conversion-logout; without it
///   the backend leaves logout behavior unchanged (so it never creates orphan
///   anonymous profiles for clients that would ignore the value).
///
/// Mirrors RN's `SDK_CAPABILITIES` (src/utils/sdkCapabilities.ts).
internal enum SwanCapabilities {
    static let all: [String] = ["anon-cdid-rotation"]
}

internal struct EventBatchCommon: Encodable {
    let appId: String
    let deviceId: String
    let sdkVersion: String
    /// `"ios"` for iOS, `"android"` for Android. Locked.
    let platform: String
    /// Capabilities the SDK advertises to the backend. Defaults to the SDK's
    /// full ``SwanCapabilities/all`` list so every construction site stamps the
    /// same single source of truth — callers never pass this explicitly.
    let capabilities: [String]

    init(
        appId: String,
        deviceId: String,
        sdkVersion: String,
        platform: String,
        capabilities: [String] = SwanCapabilities.all
    ) {
        self.appId = appId
        self.deviceId = deviceId
        self.sdkVersion = sdkVersion
        self.platform = platform
        self.capabilities = capabilities
    }
}

/// One event inside a batch.
///
/// `data` is a free-form `[String: JSONValue]` — RN auto-enriches with
/// platform, osModal, deviceModal, deviceBrand, country, currency,
/// businessUnit, deviceId, sessionId. Caller-provided keys are merged on
/// top (overridden by SDK-managed keys per ``EventEnrichment``).
internal struct BatchEvent: Codable, Equatable {
    let id: String
    let name: String
    /// Unix milliseconds (matches RN `Date.now()` and Android
    /// `System.currentTimeMillis()`).
    let timestamp: Int64
    let data: [String: JSONValue]
    let userId: String
    /// Nullable; MUST be written as JSON `null` on the wire when nil.
    let currentCDID: String?
    let generatedCDID: String

    init(
        id: String,
        name: String,
        timestamp: Int64,
        data: [String: JSONValue],
        userId: String,
        currentCDID: String?,
        generatedCDID: String
    ) {
        self.id = id
        self.name = name
        self.timestamp = timestamp
        self.data = data
        self.userId = userId
        self.currentCDID = currentCDID
        self.generatedCDID = generatedCDID
    }

    enum CodingKeys: String, CodingKey {
        case id, name, timestamp, data, userId, currentCDID, generatedCDID
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(timestamp, forKey: .timestamp)
        try c.encode(data, forKey: .data)
        try c.encode(userId, forKey: .userId)
        // Critical: write `null` (not omit) when currentCDID is nil.
        // Backend reads the field explicitly.
        if let cdid = currentCDID {
            try c.encode(cdid, forKey: .currentCDID)
        } else {
            try c.encodeNil(forKey: .currentCDID)
        }
        try c.encode(generatedCDID, forKey: .generatedCDID)
    }

    /// Decoder — used by ``DurableEventQueue`` to round-trip BatchEvents
    /// stored in the SQLite `EventQueue.eventData` column. Symmetric with
    /// `encode(to:)`; the `currentCDID = null` case round-trips back to
    /// `nil`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.timestamp = try c.decode(Int64.self, forKey: .timestamp)
        self.data = try c.decode([String: JSONValue].self, forKey: .data)
        self.userId = try c.decode(String.self, forKey: .userId)
        // currentCDID is on the wire as JSON null (not omitted) for the
        // anonymous path. `decodeIfPresent` + explicit-nil handling.
        if try c.decodeNil(forKey: .currentCDID) {
            self.currentCDID = nil
        } else {
            self.currentCDID = try c.decodeIfPresent(String.self, forKey: .currentCDID)
        }
        self.generatedCDID = try c.decode(String.self, forKey: .generatedCDID)
    }
}

/// Response from `POST /v2/trackEvent`.
///
/// Spec: `spec/wire/golden/event-ingest-response.json`,
/// `spec/behavior/identity-merge.yaml` `logout_response_contract`.
///
/// ## Transport-seam note (SWA-7372 / SWA-7343)
///
/// `generatedCDID` / `newAnonymousCDID` are the FRESH anonymous CDID the
/// backend mints on a conversion-logout. They are TOP-LEVEL on the userLogout
/// response (alongside `success`), NOT inside `results[]`. They MUST be decoded
/// here so ``LogoutService/logout()`` can adopt the rotated CDID.
///
/// This is the seam RN regressed on (SWA-7343): a response shaper that
/// hard-picked only `{ success, CDID, profileSwitched }` silently dropped the
/// rotation fields, making the adopt logic dead code. Swift `Codable` would do
/// the same — an unlisted key is simply not decoded — so these fields are
/// listed explicitly. The fields are optional + backward-compatible: an older
/// backend that returns neither leaves them `nil` and logout behavior unchanged.
internal struct EventBatchResponse: Decodable {
    let success: Bool
    let processedCount: Int?
    let failedCount: Int?
    let results: [BatchResult]?
    /// Fresh anonymous CDID minted by the backend on conversion-logout
    /// (canonical — same field name as the `/v2/device/register` response).
    let generatedCDID: String?
    /// Accepted alias for ``generatedCDID`` on the logout response.
    let newAnonymousCDID: String?
}

/// Per-event result inside ``EventBatchResponse``.
///
/// `CDID`, `profileSwitched`, `error` are all optional — see
/// `spec/wire/event-ingest.yaml` `BatchResult`. Login flows return
/// `profileSwitched=true` + the post-switch CDID; failures carry an
/// `error` string.
internal struct BatchResult: Decodable, Equatable {
    let id: String
    let success: Bool
    let CDID: String?
    let profileSwitched: Bool?
    let error: String?
}
