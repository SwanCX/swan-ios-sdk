import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Result of a logout call. `CDID` is the post-logout identifier — the
/// anonymous `generatedCDID`, or `nil` when the SDK was already anonymous
/// and no state change happened.
internal struct LogoutResult: Equatable {
    let CDID: String?
}

/// Implements the `logout-profile-reset` capability.
///
/// Spec:
///   - `spec/api/identity.yaml` `/sdk/logout`             (public surface)
///   - `spec/wire/event-ingest.yaml`                      (HTTP contract)
///   - `spec/behavior/auth.yaml`, `spec/behavior/identity-merge.yaml`
///   - `spec/behavior/queue.yaml`                         (flush-before-swap invariant)
///   - `conformance/scenarios/logout-profile-reset.feature`
///   - `spec/locked-decisions.md`                         (skipEmission honored ONLY on userLogin)
///
/// Mirrors RN's `logout()` (src/index.tsx:2759) +
/// `sendEventDirectly()` (src/index.tsx:1563) WITHOUT `skipEmission`, and
/// Android's `LogoutService.kt` (Phase 1.4).
///
/// # Behavior (RN parity — `spec/scope-v1.md`)
///
/// - **Pre-registration**: if credentials aren't loaded yet, logout FAILS
///   with ``LogoutError/credentialsNotFound``. Matches RN
///   (src/index.tsx:2764).
/// - **Already logged out**: if `currentCDID` is already nil, logout is a
///   no-op (no HTTP call, no listener notification). Mirrors the
///   `spec/behavior/auth.yaml` logged_out→logout_called transition
///   (`action: noop_warn_already_logged_out`).
/// - **Flush-before-swap invariant**: the SDK calls ``flushPendingEvents``
///   BEFORE clearing `currentCDID`. Pending events thus reach the backend
///   tagged with the logged-in `userId`, not the post-logout anonymous one.
///   Locked invariant from `spec/behavior/queue.yaml` +
///   `conformance/scenarios/logout-profile-reset.feature@tier2`.
/// - **Best-effort network**: any failure (HTTP 5xx, transport error, etc.)
///   is swallowed. The SDK STILL clears `currentCDID` + `identifier`
///   locally. Matches RN (src/index.tsx:2802-2807).
/// - **No skipEmission on userLogout**: backend `eventProcessing.ts:90`
///   only honors `skipEmission` when `normalizeEventName(name) === 'userlogin'`.
///   RN logout calls `sendEventDirectly(USER_LOGOUT, eventData)` without
///   opts — no flag set, no flag on the wire. We follow RN.
/// - **Identifier reset**: BOTH `currentCDID` AND `identifier` are
///   cleared. Locally clearing `identifier` ensures a subsequent
///   identify() with the SAME external id correctly triggers a new
///   profile-switch network call (the idempotent fast-path in
///   [IdentifyService] would skip it otherwise).
internal final class LogoutService: @unchecked Sendable {

    // MARK: - Dependencies

    private let appId: String
    private let baseUrl: String
    private let sdkVersion: String
    private let client: HttpTransport
    private let credentialsStore: CredentialsStore
    private let sessionManager: SessionManager
    private let configProvider: @Sendable () -> EventConfig
    /// Flush pending queued events before the logout HTTP call. Injected
    /// as a seam so this service doesn't need a direct dependency on
    /// [EventTracker] — the [Swan] facade wires it to
    /// `tracker.flush()` + `enrichService.flush()`. Returns when the
    /// flush completes; failures are NOT propagated (RN parity).
    private let flushPendingEvents: @Sendable () async -> Void
    private let deviceInfoProvider: @Sendable () -> EventEnrichment.DeviceInfo
    private let clock: @Sendable () -> Date
    private let idGenerator: @Sendable () -> String
    private let identifierChangedListener: (@Sendable (String) -> Void)?

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
        flushPendingEvents: @escaping @Sendable () async -> Void,
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
        self.flushPendingEvents = flushPendingEvents
        self.deviceInfoProvider = deviceInfoProvider
        self.clock = clock
        self.idGenerator = idGenerator
        self.identifierChangedListener = identifierChangedListener
    }

    // MARK: - Public surface (internal-only — Swan.shared bridges)

    /// Log the user out, switch back to the anonymous profile, and clear
    /// the cached identifier.
    ///
    /// - Returns: `.success(LogoutResult)` with the post-logout identifier
    ///   (the anonymous `generatedCDID`, or nil when already logged out and
    ///   no state change happened). Returns `.failure(LogoutError)` ONLY
    ///   for the pre-registration case — server errors are swallowed.
    func logout() async -> Result<LogoutResult, Error> {
        return await mutex.withLock { [self] in
            guard let creds = credentialsStore.read() else {
                return .failure(LogoutError.credentialsNotFound)
            }

            // Already-logged-out fast-path. Matches spec/behavior/auth.yaml
            // logged_out → logout_called noop_warn transition.
            if creds.currentCDID == nil {
                SwanLogger.debug("Swan.logout: SDK is already anonymous; nothing to do.")
                return .success(LogoutResult(CDID: nil))
            }

            // CRITICAL invariant — flush BEFORE the CDID swap. Pending
            // events must reach the backend stamped with the logged-in
            // CDID, not the anonymous one we're about to revert to.
            // RN: src/index.tsx:2789-2791.
            await flushPendingEvents()

            // Best-effort server notification. Any error is logged and we
            // proceed with the local clear — RN parity contract.
            do {
                _ = try await postLogout(creds: creds)
            } catch {
                SwanLogger.warn(
                    "Swan.logout: server request failed — user is logged out locally: \(error.localizedDescription)"
                )
            }

            // Clear currentCDID + identifier. generatedCDID + deviceId stay
            // so the SDK reverts to anonymous-identity state (Phase 1.0).
            // PRESERVE pushNotificationToken + ackUrl — logout doesn't
            // revoke the push subscription (that's `unsubscribePush()`)
            // and the cold-start sender still needs `ackUrl`.
            credentialsStore.save(
                SwanCredentials(
                    appId: creds.appId,
                    deviceId: creds.deviceId,
                    generatedCDID: creds.generatedCDID,
                    currentCDID: nil,
                    identifier: nil,
                    pushNotificationToken: creds.pushNotificationToken,
                    ackUrl: creds.ackUrl
                )
            )

            SwanLogger.debug(
                "Swan.logout: user logged out locally; reverted to anonymous CDID \(creds.generatedCDID)."
            )

            // Mirrors RN's `emit('swanIdentifierChanged', await getSwanIdentifier())`
            // at src/index.tsx:2824. Listeners receive the new (anonymous)
            // identifier.
            identifierChangedListener?(creds.generatedCDID)

            return .success(LogoutResult(CDID: creds.generatedCDID))
        }
    }

    // MARK: - Internals

    private func postLogout(creds: SwanCredentials) async throws -> EventBatchResponse? {
        let cfg = configProvider()
        let info = deviceInfoProvider()
        let now = clock()
        let timestampMs = Int64(now.timeIntervalSince1970 * 1000)
        let sessionId = sessionManager.getId()

        let payload = Self.buildLogoutPayload(
            appId: appId,
            sdkVersion: sdkVersion,
            creds: creds,
            eventId: idGenerator(),
            timestamp: timestampMs,
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

    /// Build the logout wire payload.
    ///
    /// Field order matches the identify payload structure (common →
    /// events[0] → isBatch) so wire diffs vs identify are minimal and
    /// human-readable. KEY DIFFERENCE: `skipEmission` is absent (RN parity
    /// — backend only honors the flag on userlogin), and the `data` shape
    /// has NO identifier + NO profileData (logout doesn't carry those).
    internal static func buildLogoutPayload(
        appId: String,
        sdkVersion: String,
        creds: SwanCredentials,
        eventId: String,
        timestamp: Int64,
        sessionId: String,
        config: EventConfig,
        deviceInfo: EventEnrichment.DeviceInfo
    ) -> LogoutPayload {
        let data = LogoutEventData(
            timeOfLogin: nil,  // identify never persisted timeOfLogin — JSON null on wire
            platform: deviceInfo.platform,
            osModal: deviceInfo.osModal,
            deviceModal: deviceInfo.deviceModal,
            deviceBrand: deviceInfo.deviceBrand,
            country: config.country,
            currency: config.currency,
            businessUnit: config.businessUnit,
            sessionId: sessionId
        )
        // userId is the PRE-logout CDID (we already short-circuited the
        // anonymous case before getting here).
        let userId = creds.currentCDID ?? creds.generatedCDID
        let event = LogoutEvent(
            id: eventId,
            name: EventNames.userLogout,
            timestamp: timestamp,
            data: data,
            userId: userId,
            currentCDID: creds.currentCDID,
            generatedCDID: creds.generatedCDID
        )
        let common = EventBatchCommon(
            appId: appId,
            deviceId: creds.deviceId,
            sdkVersion: sdkVersion,
            platform: deviceInfo.platform
        )
        return LogoutPayload(common: common, events: [event], isBatch: false)
    }

    // MARK: - Static helpers

    static let pathTrackEvent = "/v2/trackEvent"

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

// MARK: - Wire models (logout-only)

/// Wire model for the logout POST body. Same top-level shape as
/// ``IdentifyPayload`` but with ``LogoutEvent`` (no `skipEmission`).
internal struct LogoutPayload: Encodable {
    let common: EventBatchCommon
    let events: [LogoutEvent]
    let isBatch: Bool

    enum CodingKeys: String, CodingKey {
        case common, events, isBatch
    }
}

/// One logout event. NO `skipEmission` field — backend only honors it on
/// userLogin. `currentCDID` MUST be on the wire as JSON null when nil.
internal struct LogoutEvent: Encodable {
    let id: String
    let name: String
    let timestamp: Int64
    let data: LogoutEventData
    let userId: String
    let currentCDID: String?
    let generatedCDID: String

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
        if let cdid = currentCDID {
            try c.encode(cdid, forKey: .currentCDID)
        } else {
            try c.encodeNil(forKey: .currentCDID)
        }
        try c.encode(generatedCDID, forKey: .generatedCDID)
        // NB: NO skipEmission field. RN parity (src/index.tsx:2797).
    }
}

/// Fixed-shape `data` block for logout. Notably NO identifier + NO
/// profileData (those are login-specific). `timeOfLogin` is present as
/// JSON null when unset — the iOS port has never persisted timeOfLogin
/// (identify() doesn't set it; only a full login() would). Mirrors RN's
/// `decodedCredentials.timeOfLogin` read at logout time when none was
/// previously stashed.
internal struct LogoutEventData: Encodable {
    let timeOfLogin: String?
    let platform: String
    let osModal: String
    let deviceModal: String
    let deviceBrand: String
    let country: String
    let currency: String
    let businessUnit: String
    let sessionId: String

    enum CodingKeys: String, CodingKey {
        case timeOfLogin, platform, osModal, deviceModal, deviceBrand,
             country, currency, businessUnit, sessionId
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if let t = timeOfLogin {
            try c.encode(t, forKey: .timeOfLogin)
        } else {
            try c.encodeNil(forKey: .timeOfLogin)
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

/// Programmer-error failures from ``LogoutService/logout()``. Network /
/// protocol failures DO NOT throw these — they resolve as success with
/// the local clear having happened anyway per RN best-effort parity.
internal enum LogoutError: Error, Equatable, CustomStringConvertible {
    case credentialsNotFound

    var description: String {
        switch self {
        case .credentialsNotFound:
            return "Credential not found! Please wait for Swan to register the device!"
        }
    }
}
