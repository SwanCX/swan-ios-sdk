import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Implements the `user-attributes` capability — `Swan.enrichProfile()`.
///
/// Spec:
///   - `spec/api/identity.yaml` `/sdk/enrichProfile`         (public surface)
///   - `spec/wire/enrich-profile.yaml`                       (HTTP contract)
///   - `spec/wire/golden/enrich-profile.json`                (Tier-1 byte target)
///   - `spec/behavior/queue.yaml`                            (routing_by_eventName: PROFILE_ENRICH)
///   - `conformance/scenarios/user-attributes.feature`
///
/// Mirrors RN's `enrichProfile()` (src/index.tsx:2010) +
/// `sendEventBatch` (src/index.tsx:1786) PROFILE_ENRICH branch, and
/// Android's `EnrichProfileService.kt` (Phase 1.5).
///
/// # Behavior (RN parity — `spec/scope-v1.md`)
///
/// - **Async-queued, fire-and-forget.** `enrichProfile()` returns
///   immediately after appending to an in-memory FIFO queue. RN documents
///   this as a BREAKING CHANGE in its v2.x note (src/index.tsx:2004) —
///   `Promise<void>`, no server response surfaced to the caller. iOS
///   matches: caller gets `Result<Void, Error>` whose only failure mode is
///   pre-registration.
/// - **Pre-registration rejection.** If credentials aren't loaded yet, the
///   call returns `Result.failure` with ``EnrichProfileError/credentialsNotFound``.
///   RN throws "Credential not found! Please wait for Swan to register the
///   device!" (src/index.tsx:2014). Enrichments are NOT buffered like
///   `track()` — they share the identify/logout rejection posture.
/// - **CDID resolved at FLUSH time, not enqueue time.** RN's enrichPromises
///   block reads `decodedCredentials.currentCDID || generatedCDID` inside
///   sendEventBatch (src/index.tsx:1792). Mirroring that here means a host
///   app that calls `enrichProfile()` before login, then logs in before the
///   flush fires, will see the post-login CDID on the wire — which matches
///   RN exactly and is what the conformance scenario "CDID on flushed
///   enrich body uses currentCDID when logged in" asserts.
/// - **Per-event POST.** Each queued enrichment becomes one HTTP request
///   to `/v2/customer/enrich-profile?appId=<appId>` (RN's
///   `enrichPromises.map(async event => ...)` — NOT a single batch).
/// - **Best-effort flush.** On HTTP failure (5xx, transport error, …), the
///   event is re-queued at the FRONT of the queue and retried on the next
///   flush. v1 has no retry budget or backoff — those live with
///   `network-resilience` / `offline-queue`.
/// - **Body shape.** A flat JSON object with the caller's profileData
///   spread onto the top level, plus an auto-injected `CDID`. NO `common`
///   block, NO `events` array, NO `isBatch`. Caller-supplied `CDID` is
///   overridden (RN's `{...profileData, CDID}` spread — CDID wins because
///   it's last).
internal final class EnrichProfileService: @unchecked Sendable {

    // MARK: - Dependencies

    private let appId: String
    private let baseUrl: String
    private let client: HttpTransport
    private let credentialsStore: CredentialsStore
    private let idGenerator: @Sendable () -> String

    // MARK: - State

    private let lock = NSLock()
    private var queue: [PendingEnrichment] = []
    private let flushMutex = AsyncMutex()

    // MARK: - Init

    init(
        appId: String,
        baseUrl: String,
        client: HttpTransport,
        credentialsStore: CredentialsStore,
        idGenerator: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        self.appId = appId
        self.baseUrl = Self.trimTrailingSlash(baseUrl)
        self.client = client
        self.credentialsStore = credentialsStore
        self.idGenerator = idGenerator
    }

    // MARK: - Public surface (internal-only — Swan.shared bridges)

    /// Append a profile enrichment to the queue.
    ///
    /// - Parameter profileData: caller-provided attributes. Will be spread
    ///   verbatim onto the wire body. `CDID` (if supplied) is overridden
    ///   by the SDK-resolved one at flush time.
    /// - Returns: `.success(())` on enqueue, `.failure(EnrichProfileError)`
    ///   when credentials haven't loaded yet (pre-registration).
    @discardableResult
    func enrichProfile(_ profileData: [String: JSONValue]) -> Result<Void, Error> {
        // Assert credentials exist at call time — RN throws "Credential
        // not found" here (src/index.tsx:2014). The CDID itself is
        // resolved later at flush time so a login between enqueue and
        // flush is picked up.
        guard credentialsStore.read() != nil else {
            return .failure(EnrichProfileError.credentialsNotFound)
        }

        let pending = PendingEnrichment(
            id: idGenerator(),
            profileData: profileData
        )
        let size: Int = lockSync {
            queue.append(pending)
            return queue.count
        }
        SwanLogger.debug(
            "Swan.enrichProfile: queued enrichment \(pending.id) (queue size now \(size))."
        )
        return .success(())
    }

    /// Number of pending enrichments waiting to flush.
    func queueSize() -> Int {
        return lockSync { queue.count }
    }

    /// Snapshot of pending enrichments WITHOUT removing them. Used by tests.
    func snapshot() -> [PendingEnrichment] {
        return lockSync { queue }
    }

    /// Drain the queue and POST one request per enrichment.
    ///
    /// Single-flight via [flushMutex]. Per-event failures re-queue at the
    /// front in original order (so the next flush retries them before any
    /// newer enqueues). On unrecoverable creds-missing state, all drained
    /// events are pushed back and the call returns.
    func flush() async {
        await flushMutex.withLock { [self] in
            let drained: [PendingEnrichment] = lockSync {
                let out = queue
                queue = []
                return out
            }
            if drained.isEmpty { return }

            guard let creds = credentialsStore.read() else {
                // Race — creds wiped between enqueue and flush. Push
                // everything back at the front and bail. Defensive path.
                SwanLogger.warn(
                    "Swan.enrichProfile.flush: credentials missing — re-queueing \(drained.count) enrichments."
                )
                lockSync {
                    queue = drained + queue
                }
                return
            }

            let cdid = creds.currentCDID ?? creds.generatedCDID

            // Track failures so we can re-queue them at the front in order.
            var failed: [PendingEnrichment] = []
            for event in drained {
                let ok = await postOne(event: event, cdid: cdid)
                if !ok { failed.append(event) }
            }
            if !failed.isEmpty {
                let snapshot = failed
                lockSync {
                    queue = snapshot + queue
                }
            }
        }
    }

    /// Synchronous critical section helper — wraps NSLock so concurrent
    /// callers serialize without surfacing `lock.lock()` / `lock.unlock()`
    /// calls inside `async` bodies (those trip Swift 6 strict-concurrency
    /// warnings).
    private func lockSync<T>(_ work: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return work()
    }

    // MARK: - Internals

    /// POST one enrichment. Returns true on a 2xx, false otherwise.
    /// Errors caught and logged.
    private func postOne(event: PendingEnrichment, cdid: String) async -> Bool {
        let payload = Self.buildEnrichPayload(profileData: event.profileData, cdid: cdid)
        let bodyData: Data
        do {
            bodyData = try Self.jsonEncoder.encode(payload)
        } catch {
            SwanLogger.error(
                "Swan.enrichProfile.flush: JSON encode failed for \(event.id) — \(error.localizedDescription)"
            )
            return false
        }
        let url = URL(string: "\(baseUrl)\(Self.pathEnrichProfile)?appId=\(appId)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData

        do {
            let response = try await client.send(request)
            guard (200..<300).contains(response.status) else {
                SwanLogger.warn(
                    "Swan.enrichProfile.flush: enrichment \(event.id) failed HTTP \(response.status); will retry on next flush."
                )
                return false
            }
            // Body is discarded — RN's enrichPromises only checks
            // truthiness of the response. We don't surface "Customer
            // profile enriched successfully" to the caller.
            return true
        } catch {
            SwanLogger.warn(
                "Swan.enrichProfile.flush: enrichment \(event.id) failed; will retry on next flush: \(error.localizedDescription)"
            )
            return false
        }
    }

    /// Snapshot of one queued enrichment. Captured at enqueue time:
    ///   - `id` — uuid for logging + future per-event status tracking.
    ///   - `profileData` — caller's blob, frozen as immutable dict.
    ///
    /// Notably NOT captured: the CDID. RN resolves CDID at flush time
    /// (src/index.tsx:1792), and the conformance scenario "CDID on flushed
    /// enrich body uses currentCDID when logged in" requires that behavior.
    internal struct PendingEnrichment {
        let id: String
        let profileData: [String: JSONValue]
    }

    // MARK: - Wire payload (visible for testing)

    /// Build the enrich-profile wire body.
    ///
    /// Shape: flat JSON object. Caller's profileData keys are spread first
    /// (preserving their order), then `CDID` is appended LAST so it
    /// overrides any caller-supplied CDID. Matches RN's
    /// `{...profileData, CDID}` spread exactly.
    internal static func buildEnrichPayload(
        profileData: [String: JSONValue],
        cdid: String
    ) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for (key, value) in profileData {
            // Skip caller-supplied CDID — we re-emit the SDK one below.
            // Doing it this way (rather than relying on dict "last wins")
            // keeps the resulting key set predictable even when callers
            // slip in a CDID field.
            if key == "CDID" { continue }
            out[key] = value
        }
        out["CDID"] = .string(cdid)
        return out
    }

    // MARK: - Static helpers

    /// Matches RN's `ECOM_ENRICH_PROFILE_URL` (src/constants/ApiUrls.ts).
    static let pathEnrichProfile = "/v2/customer/enrich-profile"

    static let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        return encoder
    }()

    private static func trimTrailingSlash(_ s: String) -> String {
        var out = s
        while out.hasSuffix("/") { out.removeLast() }
        return out
    }
}

// MARK: - Errors

/// Programmer-error failures from
/// ``EnrichProfileService/enrichProfile(_:)``. Network failures DO NOT
/// throw these — they re-queue the event for retry on the next flush.
internal enum EnrichProfileError: Error, Equatable, CustomStringConvertible {
    case credentialsNotFound

    var description: String {
        switch self {
        case .credentialsNotFound:
            return "Credential not found! Please wait for Swan to register the device!"
        }
    }
}
