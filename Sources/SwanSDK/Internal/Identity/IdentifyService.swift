import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Result of a successful identify call. Mirrors RN's identify() return
/// shape: `{ CDID, profileSwitched }`. On a network or protocol failure
/// the SDK still resolves with `profileSwitched=false` + the unchanged
/// `CDID` — see [IdentifyService.identify] for the best-effort contract.
internal struct IdentifyResult: Equatable {
    let CDID: String?
    let profileSwitched: Bool
}

/// Implements the `identify-login` capability.
///
/// Spec:
///   - `spec/api/identity.yaml` `/sdk/identify`            (public surface)
///   - `spec/wire/event-ingest.yaml`                       (HTTP contract)
///   - `spec/wire/golden/event-ingest-identify-skipemission.json` (Tier-1 byte target)
///   - `spec/behavior/auth.yaml`, `spec/behavior/identity-merge.yaml`
///   - `conformance/scenarios/identify-login.feature`
///   - `spec/locked-decisions.md` (skipEmission honored ONLY on userLogin)
///
/// Mirrors RN's `identify()` (src/index.tsx:2557) +
/// `sendEventDirectly()` (src/index.tsx:1563) with `skipEmission: true`,
/// and Android's `IdentifyService.kt` (Phase 1.3).
///
/// # Behavior (RN parity — `spec/scope-v1.md`)
///
/// - **Validation**: empty `identifier` → returns `Result.failure` with
///   ``IdentifyError/emptyIdentifier``. (Swift idiom: surface via the
///   error path instead of throwing — the public ``Swan/identify(identifier:attributes:)``
///   wrapper is fire-and-forget and would swallow a throw anyway.)
/// - **Pre-registration**: if credentials aren't loaded yet, identify FAILS
///   with ``IdentifyError/credentialsNotFound``. Identify is NOT buffered
///   like `track()`. Mirrors Android Phase 1.3.
/// - **Idempotent**: if `storedIdentifier == identifier` AND a `currentCDID`
///   is already present, no-op (no network call) — matches RN's fast-path
///   (src/index.tsx:2585).
/// - **Network**: synchronous single-event POST to `/v2/trackEvent`,
///   `isBatch:false`, one `userLogin` event with `skipEmission:true`.
///   Backend gates Kafka/RMQ/cart/journey side-effects on the flag — only
///   the profile-switching path runs (eventProcessing.ts:90).
/// - **Best-effort**: on any network/protocol failure or unsuccessful
///   response the SDK identity is UNCHANGED. Resolves with the current CDID
///   + `profileSwitched=false`. RN parity (src/index.tsx:2637).
/// - **On success**: persists `identifier` always; persists `currentCDID`
///   only when the server reports `profileSwitched=true` with a non-empty
///   CDID (src/index.tsx:2650).
///
/// # Wire-shape parity
///
/// The identify body is BUILT BY HAND (not via [BatchEvent]) for two
/// reasons:
///   1. `skipEmission` must appear ONLY on the identify event — adding it
///      to [BatchEvent] would either pollute every custom event with
///      `"skipEmission":null` or require a separate encoder path.
///   2. The identify event's `data` shape is fixed (per the golden) —
///      there's no caller-supplied attributes path beyond `profileData`.
///      Building it inline keeps the field order predictable vs. the
///      golden.
///
/// # Concurrency
///
/// Single-flight via an `actor`-style serial DispatchQueue. Two concurrent
/// `identify()` calls with the same identifier resolve the second through
/// the idempotent fast-path AFTER the first has persisted state — matches
/// the Android `Mutex.withLock` pattern. Swift's `actor` would also work
/// but would require pushing every public surface caller to `await`; we
/// keep the SDK Foundation-only and use a serial queue for symmetry with
/// [Swan]'s own `lock`.
internal final class IdentifyService: @unchecked Sendable {

    // MARK: - Dependencies

    private let appId: String
    private let baseUrl: String
    private let sdkVersion: String
    private let client: HttpTransport
    private let credentialsStore: CredentialsStore
    private let sessionManager: SessionManager
    private let configProvider: @Sendable () -> EventConfig
    private let deviceInfoProvider: @Sendable () -> EventEnrichment.DeviceInfo
    private let clock: @Sendable () -> Date
    private let idGenerator: @Sendable () -> String
    private let identifierChangedListener: (@Sendable (String) -> Void)?

    /// Single-flight gate. A second concurrent identify() call awaits the
    /// first; once the first persists state, the second hits the idempotent
    /// fast-path. Matches Android's `Mutex.withLock`.
    private let mutex = AsyncMutex()

    // MARK: - Init

    init(
        appId: String,
        baseUrl: String,
        sdkVersion: String,
        client: HttpTransport,
        credentialsStore: CredentialsStore,
        sessionManager: SessionManager,
        configProvider: @escaping @Sendable () -> EventConfig,
        deviceInfoProvider: @escaping @Sendable () -> EventEnrichment.DeviceInfo = { .current() },
        clock: @escaping @Sendable () -> Date = { Date() },
        idGenerator: @escaping @Sendable () -> String = { UUID().uuidString },
        identifierChangedListener: (@Sendable (String) -> Void)? = nil
    ) {
        self.appId = appId
        self.baseUrl = Self.trimTrailingSlash(baseUrl)
        self.sdkVersion = sdkVersion
        self.client = client
        self.credentialsStore = credentialsStore
        self.sessionManager = sessionManager
        self.configProvider = configProvider
        self.deviceInfoProvider = deviceInfoProvider
        self.clock = clock
        self.idGenerator = idGenerator
        self.identifierChangedListener = identifierChangedListener
    }

    // MARK: - Public surface (internal-only — Swan.shared bridges)

    /// Assert identity on the SDK. Reusable on every cold start; idempotent
    /// when called with the same identifier the SDK already knows.
    ///
    /// - Parameters:
    ///   - identifier: external user identifier (email, phone, loyalty ID).
    ///     MUST be non-empty.
    ///   - profileData: optional `profileData` blob passed to the backend
    ///     in the userLogin event payload. Backend strips it from the event
    ///     before forwarding downstream (eventProcessing.ts:140).
    /// - Returns: `.success(IdentifyResult)` on a successful (best-effort)
    ///   call; `.failure(IdentifyError)` only for validation / pre-reg
    ///   programmer errors.
    func identify(
        identifier: String,
        profileData: [String: JSONValue]? = nil
    ) async -> Result<IdentifyResult, Error> {
        guard !identifier.isEmpty else {
            return .failure(IdentifyError.emptyIdentifier)
        }

        return await mutex.withLock { [self] in
            guard let creds = credentialsStore.read() else {
                return .failure(IdentifyError.credentialsNotFound)
            }

            // Idempotent fast-path: same identifier + a CDID already present
            // → no network call. Matches RN src/index.tsx:2585.
            if let currentCDID = creds.currentCDID,
               creds.identifier == identifier {
                SwanLogger.debug(
                    "Swan.identify: SDK already identified as '\(identifier)', skipping (no network call)."
                )
                return .success(IdentifyResult(CDID: currentCDID, profileSwitched: false))
            }

            // Best-effort network call. Any failure → return success with
            // unchanged CDID, do NOT propagate. RN src/index.tsx:2637.
            let response: EventBatchResponse?
            do {
                response = try await postIdentify(
                    creds: creds,
                    identifier: identifier,
                    profileData: profileData
                )
            } catch {
                SwanLogger.warn(
                    "Swan.identify: server request failed — SDK identity unchanged, will retry on next identify() call: \(error.localizedDescription)"
                )
                return .success(IdentifyResult(CDID: creds.currentCDID, profileSwitched: false))
            }

            guard let response = response, response.success else {
                if response != nil {
                    SwanLogger.warn(
                        "Swan.identify: no successful response from server — SDK identity unchanged."
                    )
                }
                return .success(IdentifyResult(CDID: creds.currentCDID, profileSwitched: false))
            }

            let firstResult = response.results?.first
            let resolvedCDID = firstResult?.CDID
            let profileSwitched = firstResult?.profileSwitched == true

            // Persist BEFORE notifying the listener so any post-callback
            // swanIdentifier read sees the new state.
            let newCurrentCDID: String?
            if profileSwitched, let cdid = resolvedCDID, !cdid.isEmpty {
                newCurrentCDID = cdid
            } else {
                newCurrentCDID = creds.currentCDID
            }
            // PRESERVE pushNotificationToken + ackUrl across identify —
            // they're owned by push-fcm-ios / delivery-click-ack, not
            // identity. Direct construction here would silently clear
            // them and force a re-subscribe round-trip on next push.
            credentialsStore.save(
                SwanCredentials(
                    appId: creds.appId,
                    deviceId: creds.deviceId,
                    generatedCDID: creds.generatedCDID,
                    currentCDID: newCurrentCDID,
                    identifier: identifier,
                    pushNotificationToken: creds.pushNotificationToken,
                    ackUrl: creds.ackUrl
                )
            )

            if profileSwitched,
               let cdid = resolvedCDID,
               !cdid.isEmpty,
               cdid != creds.currentCDID {
                SwanLogger.debug(
                    "Swan.identify: profile switched on server (\(creds.currentCDID ?? "anonymous") → \(cdid))."
                )
                identifierChangedListener?(cdid)
            }

            return .success(
                IdentifyResult(
                    CDID: resolvedCDID ?? newCurrentCDID,
                    profileSwitched: profileSwitched
                )
            )
        }
    }

    // MARK: - Internals

    private func postIdentify(
        creds: SwanCredentials,
        identifier: String,
        profileData: [String: JSONValue]?
    ) async throws -> EventBatchResponse? {
        let cfg = configProvider()
        let info = deviceInfoProvider()
        let now = clock()
        let timestampMs = Int64(now.timeIntervalSince1970 * 1000)
        let timeOfLogin = Self.isoUtc(now)
        let sessionId = sessionManager.getId()

        let payload = Self.buildIdentifyPayload(
            appId: appId,
            sdkVersion: sdkVersion,
            creds: creds,
            identifier: identifier,
            profileData: profileData,
            eventId: idGenerator(),
            timestamp: timestampMs,
            timeOfLogin: timeOfLogin,
            sessionId: sessionId,
            config: cfg,
            deviceInfo: info
        )

        let bodyData = try Self.jsonEncoder.encode(payload)
        let url = URL(string: "\(baseUrl)\(Self.pathTrackEvent)?appId=\(appId)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData

        let response = try await client.send(request)
        guard (200..<300).contains(response.status) else {
            throw HttpError.nonSuccess(
                status: response.status,
                body: String(data: response.data, encoding: .utf8) ?? ""
            )
        }
        if response.data.isEmpty {
            return nil
        }
        return try? Self.jsonDecoder.decode(EventBatchResponse.self, from: response.data)
    }

    // MARK: - Wire payload (visible for testing)

    /// Build the identify wire payload.
    ///
    /// Field order matches `spec/wire/golden/event-ingest-identify-skipemission.json`
    /// (common → events[0] → isBatch). Encoded via [IdentifyPayload]'s
    /// hand-rolled `encode(to:)` so `currentCDID:null` (not omitted) and
    /// `profileData:null` (not omitted) reach the wire.
    internal static func buildIdentifyPayload(
        appId: String,
        sdkVersion: String,
        creds: SwanCredentials,
        identifier: String,
        profileData: [String: JSONValue]?,
        eventId: String,
        timestamp: Int64,
        timeOfLogin: String,
        sessionId: String,
        config: EventConfig,
        deviceInfo: EventEnrichment.DeviceInfo
    ) -> IdentifyPayload {
        let data = IdentifyEventData(
            timeOfLogin: timeOfLogin,
            identifier: identifier,
            profileData: profileData,
            platform: deviceInfo.platform,
            osModal: deviceInfo.osModal,
            deviceModal: deviceInfo.deviceModal,
            deviceBrand: deviceInfo.deviceBrand,
            country: config.country,
            currency: config.currency,
            businessUnit: config.businessUnit,
            sessionId: sessionId
        )
        let userId = creds.currentCDID ?? creds.generatedCDID
        let event = IdentifyEvent(
            id: eventId,
            name: EventNames.userLogin,
            timestamp: timestamp,
            data: data,
            userId: userId,
            currentCDID: creds.currentCDID,
            generatedCDID: creds.generatedCDID,
            skipEmission: true
        )
        let common = EventBatchCommon(
            appId: appId,
            deviceId: creds.deviceId,
            sdkVersion: sdkVersion,
            platform: deviceInfo.platform
        )
        return IdentifyPayload(common: common, events: [event], isBatch: false)
    }

    // MARK: - Static helpers

    static let pathTrackEvent = "/v2/trackEvent"

    /// ISO-8601 UTC timestamp matching JavaScript `new Date().toISOString()`.
    /// Example: `2026-05-11T12:34:56.789Z`. RN sends this on the wire.
    internal static func isoUtc(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return formatter.string(from: date)
    }

    static let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        return encoder
    }()

    static let jsonDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        return decoder
    }()

    private static func trimTrailingSlash(_ s: String) -> String {
        var out = s
        while out.hasSuffix("/") { out.removeLast() }
        return out
    }
}

// MARK: - Wire models (identify-only)

/// Wire model for the identify POST body. Top-level shape mirrors
/// ``EventBatchPayload`` but encodes a fixed-shape ``IdentifyEvent``
/// instead of the generic [BatchEvent], because identify has bespoke
/// fields (`skipEmission`, fixed `data` shape, `profileData`) that don't
/// belong in the shared events model.
internal struct IdentifyPayload: Encodable {
    let common: EventBatchCommon
    let events: [IdentifyEvent]
    let isBatch: Bool

    enum CodingKeys: String, CodingKey {
        case common, events, isBatch
    }
}

/// One identify event. Same field set as [BatchEvent] PLUS `skipEmission`,
/// MINUS the free-form `data` (replaced with the fixed ``IdentifyEventData``).
internal struct IdentifyEvent: Encodable {
    let id: String
    let name: String
    let timestamp: Int64
    let data: IdentifyEventData
    let userId: String
    let currentCDID: String?
    let generatedCDID: String
    let skipEmission: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, timestamp, data, userId, currentCDID, generatedCDID, skipEmission
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(timestamp, forKey: .timestamp)
        try c.encode(data, forKey: .data)
        try c.encode(userId, forKey: .userId)
        // currentCDID must be present as JSON null on the wire (backend
        // reads it by key — eventProcessing.ts:115). NOT omitted.
        if let cdid = currentCDID {
            try c.encode(cdid, forKey: .currentCDID)
        } else {
            try c.encodeNil(forKey: .currentCDID)
        }
        try c.encode(generatedCDID, forKey: .generatedCDID)
        // skipEmission is the whole point of identify — must be `true`.
        try c.encode(skipEmission, forKey: .skipEmission)
    }
}

/// Fixed-shape `data` block for identify. NOT auto-enriched via
/// [EventEnrichment] — RN identify() builds eventData inline
/// (src/index.tsx:2605). Country/currency/businessUnit are emitted as
/// EMPTY STRINGS when unset to match the golden field order exactly
/// (the golden has them present even when empty — see line 22-24).
internal struct IdentifyEventData: Encodable {
    let timeOfLogin: String
    let identifier: String
    let profileData: [String: JSONValue]?
    let platform: String
    let osModal: String
    let deviceModal: String
    let deviceBrand: String
    let country: String
    let currency: String
    let businessUnit: String
    let sessionId: String

    enum CodingKeys: String, CodingKey {
        case timeOfLogin, identifier, profileData,
             platform, osModal, deviceModal, deviceBrand,
             country, currency, businessUnit, sessionId
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(timeOfLogin, forKey: .timeOfLogin)
        try c.encode(identifier, forKey: .identifier)
        // profileData present even when nil — backend tolerates JSON null
        // and the golden carries `"profileData": null`. RN parity
        // (src/index.tsx:2608 — `profileData: data` always set).
        if let pd = profileData {
            try c.encode(pd, forKey: .profileData)
        } else {
            try c.encodeNil(forKey: .profileData)
        }
        try c.encode(platform, forKey: .platform)
        try c.encode(osModal, forKey: .osModal)
        try c.encode(deviceModal, forKey: .deviceModal)
        try c.encode(deviceBrand, forKey: .deviceBrand)
        try c.encode(country, forKey: .country)
        try c.encode(currency, forKey: .currency)
        try c.encode(businessUnit, forKey: .businessUnit)
        try c.encode(sessionId, forKey: .sessionId)
    }
}

// MARK: - Errors

/// Programmer-error failures from ``IdentifyService/identify(identifier:profileData:)``.
/// Network/protocol failures DO NOT throw these — they resolve as success
/// with `profileSwitched=false` per RN best-effort parity.
internal enum IdentifyError: Error, Equatable, CustomStringConvertible {
    case emptyIdentifier
    case credentialsNotFound

    var description: String {
        switch self {
        case .emptyIdentifier:
            return "identify(identifier): identifier must be a non-empty string"
        case .credentialsNotFound:
            return "Credential not found! Please wait for Swan to register the device!"
        }
    }
}
