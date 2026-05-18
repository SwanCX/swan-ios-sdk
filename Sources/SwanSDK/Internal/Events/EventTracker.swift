import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Coordinator for the custom-events capability + the durable event queue.
///
/// **Capabilities:** `custom-events`, `semantic-ecommerce-events`,
/// `offline-queue`, `network-resilience`, `force-flush`.
///
/// Spec:
///   - `spec/api/events.yaml`                      (public surface)
///   - `spec/wire/event-ingest.yaml`               (HTTP contract)
///   - `spec/wire/golden/event-ingest-batch.json`  (Tier-1 byte-for-byte target)
///   - `spec/behavior/queue.yaml`                  (queue state machine + constants)
///   - `conformance/scenarios/custom-events.feature`
///   - `conformance/scenarios/semantic-ecommerce-events.feature`
///   - `conformance/scenarios/offline-queue.feature`
///   - `conformance/scenarios/network-resilience.feature`
///   - `conformance/scenarios/force-flush.feature`
///
/// Mirrors RN's [`trackEvent`](src/index.tsx:2121) and
/// [`sendEventBatch`](src/index.tsx:1641) (standard-events branch only),
/// and Android's `EventTracker.kt`.
///
/// ## Storage
///
/// Backed by ``DurableEventQueue`` → ``SqliteQueueStore`` (production) or
/// ``InMemoryQueueStore`` (tests). Earlier iterations used a pure in-memory
/// `[QueuedEvent]` array; the `offline-queue` capability port replaced it
/// with the durable surface so events survive process death.
///
/// ## Flush triggers
///
///   1. **Size threshold** — when pending count >= `EventConfig.batchSize`
///      after enqueue. Matches RN's `checkFlushNeeded`.
///   2. **Time threshold** — every `EventConfig.flushInterval` seconds.
///   3. **Explicit flush** — ``flush()`` forces a drain.
///   4. **AppState→background** — owned by ``SessionTracker``; calls into
///      ``flush()`` through the same closure path as the public API.
///   5. **Retry-scheduled** — after a 5xx / transport failure, retries fire
///      with `2s/4s/8s` exponential backoff (network-resilience capability).
///
/// ## Track-time CDID resolution
///
/// Per the port directive, we capture `currentCDID || generatedCDID` AT the
/// moment ``track(name:attributes:)`` enqueues the event — not at flush
/// time. Matches RN (src/index.tsx:1822 + :2155-2156).
internal final class EventTracker: @unchecked Sendable {

    // MARK: - Dependencies

    private let appId: String
    private let baseUrl: String
    private let sdkVersion: String
    private let client: HttpTransport
    private let credentialsStore: CredentialsStore
    private let sessionManager: SessionManager
    private let deviceInfoProvider: @Sendable () -> EventEnrichment.DeviceInfo
    private let clock: @Sendable () -> Date
    private let idGenerator: @Sendable () -> String

    /// Durable queue (offline-queue capability). Injected so tests can pass
    /// an `InMemoryQueueStore` and production wires a `SqliteQueueStore`.
    private let durableQueue: DurableEventQueue

    // MARK: - State (protected by `lock`)

    private let lock = NSLock()
    private var config: EventConfig
    private var flushInFlight: Bool = false
    private var periodicTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?

    /// Optional hook for the session-tracking port — when set, the periodic
    /// flush task skips ticks while the app is paused (backgrounded).
    private var pausedProvider: (@Sendable () -> Bool)?

    // MARK: - Init

    init(
        appId: String,
        baseUrl: String,
        sdkVersion: String,
        client: HttpTransport,
        credentialsStore: CredentialsStore,
        sessionManager: SessionManager,
        config: EventConfig = EventConfig(),
        deviceInfoProvider: @escaping @Sendable () -> EventEnrichment.DeviceInfo = { .current() },
        clock: @escaping @Sendable () -> Date = { Date() },
        idGenerator: @escaping @Sendable () -> String = { UUID().uuidString },
        queueStore: QueueStore? = nil
    ) {
        self.appId = appId
        self.baseUrl = Self.trimTrailingSlash(baseUrl)
        self.sdkVersion = sdkVersion
        self.client = client
        self.credentialsStore = credentialsStore
        self.sessionManager = sessionManager
        self.config = config
        self.deviceInfoProvider = deviceInfoProvider
        self.clock = clock
        self.idGenerator = idGenerator

        // Pick the store. Production callers pass `nil` and we try the
        // SQLite store; if it fails to open we fall back to in-memory so
        // the SDK never crashes on a corrupt user partition. Test paths
        // inject their own store explicitly.
        let resolvedStore: QueueStore
        if let qs = queueStore {
            resolvedStore = qs
        } else {
            do {
                resolvedStore = try SqliteQueueStore.open()
            } catch {
                SwanLogger.error(
                    "EventTracker: SQLite open failed (\(error)); falling back to in-memory queue."
                )
                resolvedStore = InMemoryQueueStore()
            }
        }
        // configProvider needs to see *current* config + lock — but `self`
        // isn't fully initialized yet, so we publish a shared box that the
        // closure captures and the EventTracker writes through. This keeps
        // the closure non-recursive on `self`.
        let configBox = ConfigBox(value: config)
        self.configBox = configBox
        self.durableQueue = DurableEventQueue(
            store: resolvedStore,
            credentialsStore: credentialsStore,
            sessionManager: sessionManager,
            deviceInfoProvider: deviceInfoProvider,
            configProvider: { configBox.snapshot() },
            clock: { Int64(clock().timeIntervalSince1970 * 1000) }
        )
    }

    /// Sendable shared box that holds the live ``EventConfig`` for the
    /// ``DurableEventQueue``'s `configProvider` closure. We can't capture
    /// `self` from the init body (durableQueue is being initialized), so
    /// this box plays the role of an indirection layer. Mutations land via
    /// ``updateConfig(_:)``.
    private final class ConfigBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: EventConfig
        init(value: EventConfig) { self.stored = value }
        func snapshot() -> EventConfig {
            lock.lock(); defer { lock.unlock() }
            return stored
        }
        func set(_ value: EventConfig) {
            lock.lock(); defer { lock.unlock() }
            stored = value
        }
    }
    private let configBox: ConfigBox

    // MARK: - Public surface (internal-only — Swan.shared bridges)

    /// Enqueue an event. Returns immediately. Triggers a size-threshold
    /// flush in the background if the pending count crossed
    /// `config.batchSize` after enqueue.
    ///
    /// - Parameter name: wire event name. MUST be non-empty and MUST NOT
    ///   be one of ``EventNames/reserved``.
    /// - Parameter attributes: caller-provided payload, merged into the
    ///   auto-enriched `data` object. SDK-managed keys override caller
    ///   values per RN.
    ///
    /// Pre-registration handling: if credentials aren't loaded yet, the
    /// row lands in the queue with `status = pre_reg`. When credentials
    /// arrive, ``onCredentialsAvailable()`` flips them to `pending` with
    /// full enrichment. Mirrors Android's offline-queue behavior; survives
    /// process death.
    func track(name: String, attributes: [String: JSONValue]) {
        guard !name.isEmpty else {
            SwanLogger.warn("Swan.track(): event name must not be empty; dropped.")
            return
        }
        guard !EventNames.reserved.contains(name) else {
            SwanLogger.warn(
                "Swan.track(): event name '\(name)' is reserved for SDK-internal routing; use the dedicated capability API instead."
            )
            return
        }

        let id = idGenerator()
        let nowMs = Int64(clock().timeIntervalSince1970 * 1000)
        let pendingCount = durableQueue.enqueueCustomEvent(
            id: id,
            name: name,
            attributes: attributes,
            timestamp: nowMs
        )
        let cfg = lock.sync { config }
        if pendingCount >= cfg.batchSize {
            Task.detached(priority: .utility) { [weak self] in
                _ = await self?.flushOnce()
            }
        }
    }

    /// Promote any pre-registration rows into the main queue.
    ///
    /// Called by ``Swan`` when credentials become available (registration
    /// succeeds, or cached credentials are loaded). MUST be called from a
    /// background context — touches the credentials store + SQLite.
    func onCredentialsAvailable() {
        let promoted = durableQueue.promotePreRegistration()
        let cfg = lock.sync { config }
        if promoted > 0 && durableQueue.pendingCount() >= cfg.batchSize {
            Task.detached(priority: .utility) { [weak self] in
                _ = await self?.flushOnce()
            }
        }
    }

    /// Drain up to one batch from the queue. Single-flight — concurrent
    /// callers see the second flush short-circuit. Mirrors RN's
    /// `FlushManager.isFlushing` lock.
    @discardableResult
    func flush() async -> EventBatchResponse? {
        return await flushOnce()
    }

    /// Snapshot of the pending-count. Excludes `pre_reg`/`sending`/`failed`,
    /// matching `conformance/scenarios/force-flush.feature` "getQueueSize
    /// counts only pending events".
    func queueSize() -> Int {
        return durableQueue.pendingCount()
    }

    /// Test seam — snapshot of pending events in FIFO order, decoded back
    /// from the durable store.
    func snapshotPending() -> [BatchEvent] {
        return durableQueue.snapshotPendingEvents()
    }

    /// Test seam — diagnostic counts of every row regardless of status.
    func snapshotAllRows() -> [QueueRow] {
        return durableQueue.snapshotAll()
    }

    /// Update the super-properties (country / currency / businessUnit /
    /// currentScreenName). Subsequent ``track(name:attributes:)`` calls see
    /// the new values; already-enqueued events keep their original
    /// enrichment (RN parity).
    func updateConfig(_ transform: (EventConfig) -> EventConfig) {
        lock.sync {
            config = transform(config)
            configBox.set(config)
        }
    }

    /// Snapshot of the current ``EventConfig``.
    func currentConfig() -> EventConfig {
        return lock.sync { config }
    }

    /// Snapshot of the device fingerprint the tracker captures at enqueue time.
    func currentDeviceInfo() -> EventEnrichment.DeviceInfo {
        return deviceInfoProvider()
    }

    /// Install the session-tracker's `isPaused()` predicate. While `true`,
    /// the periodic-flush task skips its tick. Size-threshold + retry flushes
    /// remain active.
    ///
    /// Owned by `session-tracking` capability — wired from ``Swan``.
    func setPausedProvider(_ provider: @escaping @Sendable () -> Bool) {
        lock.sync { pausedProvider = provider }
    }

    /// Start the periodic-flush timer + stale-sending recovery. Idempotent.
    ///
    /// Stale-sending recovery runs FIRST so crash-orphaned rows are eligible
    /// for the very first periodic flush. Doesn't bump retryCount — a crash
    /// isn't a retry, per `spec/behavior/queue.yaml`.
    func start() {
        // Stale-sending recovery before kicking off any work.
        _ = durableQueue.recoverStaleSending()

        lock.sync {
            if periodicTask != nil { return }
            let intervalNs: UInt64 = UInt64(config.flushInterval * 1_000_000_000)
            periodicTask = Task.detached(priority: .utility) { [weak self] in
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(nanoseconds: intervalNs)
                    } catch {
                        return
                    }
                    if let paused = self?.lock.sync({ self?.pausedProvider?() ?? false }),
                       paused {
                        // session-tracking: skip ticks while backgrounded.
                        continue
                    }
                    _ = await self?.flushOnce()
                    _ = self?.durableQueue.cleanupOldFailedEvents()
                }
            }
        }
    }

    /// Stop the periodic-flush task + any pending retry. Used by tests +
    /// ``Swan/resetForTests``.
    func stop() {
        lock.sync {
            periodicTask?.cancel()
            periodicTask = nil
            retryTask?.cancel()
            retryTask = nil
        }
    }

    /// Test-only — expose the underlying durable queue for assertions.
    func durableQueueForTests() -> DurableEventQueue {
        return durableQueue
    }

    // MARK: - Internals

    /// Dequeue a batch, POST to `/v2/trackEvent`, apply state transitions.
    /// Single-flight — concurrent callers short-circuit.
    @discardableResult
    private func flushOnce() async -> EventBatchResponse? {
        let cfg = lock.sync { () -> EventConfig in
            return config
        }
        // Single-flight guard. NOTE: we DON'T short-circuit-and-return-nil
        // outside the lock — flush() is supposed to be observable, so we
        // do return nil but only after marking the slot taken.
        let proceed: Bool = lock.sync {
            if flushInFlight { return false }
            flushInFlight = true
            return true
        }
        guard proceed else { return nil }
        defer { lock.sync { flushInFlight = false } }

        let dequeued = durableQueue.dequeueForSend(batchSize: cfg.batchSize)
        if dequeued.isEmpty { return nil }

        guard let creds = credentialsStore.read() else {
            // Credentials disappeared between dequeue and read — restore
            // rows without bumping retry; this isn't a real send attempt.
            durableQueue.restoreToPending(dequeued.map { $0.row.id })
            return nil
        }

        let payload = EventBatchPayload(
            common: EventBatchCommon(
                appId: appId,
                deviceId: creds.deviceId,
                sdkVersion: sdkVersion,
                platform: "ios"
            ),
            events: dequeued.map { $0.event },
            isBatch: true
        )

        let bodyData: Data
        do {
            bodyData = try Self.jsonEncoder.encode(payload)
        } catch {
            SwanLogger.error("Swan.flush(): JSON encode failed — \(error.localizedDescription)")
            // Treat as a batch failure — bump retryCount on every row.
            let outcome = durableQueue.markBatchFailed(dequeued.map { $0.row })
            if !outcome.retriedIds.isEmpty {
                scheduleRetry(delay: outcome.nextRetryDelay)
            }
            return nil
        }

        let url = URL(string: "\(baseUrl)\(Self.pathTrackEvent)?appId=\(appId)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData

        do {
            let response = try await client.send(request)
            guard (200..<300).contains(response.status) else {
                SwanLogger.warn(
                    "Swan.flush(): HTTP \(response.status); rescheduling \(dequeued.count) event(s)."
                )
                handleBatchFailure(dequeued.map { $0.row })
                return nil
            }
            let decoded = try? Self.jsonDecoder.decode(EventBatchResponse.self, from: response.data)
            handleBatchResponse(dequeued.map { $0.row }, response: decoded)
            return decoded
        } catch {
            SwanLogger.warn(
                "Swan.flush(): transport failure — \(error.localizedDescription); rescheduling \(dequeued.count) event(s)."
            )
            handleBatchFailure(dequeued.map { $0.row })
            return nil
        }
    }

    /// Apply per-event status transitions from a 200 OK response. Mirrors
    /// RN's `handleBatchResponse` (FlushManager.ts:164).
    ///
    ///   - No `results` array → assume all succeeded (RN's backward-compat
    ///     path).
    ///   - `results[i].success = true` → delete row.
    ///   - `results[i].success = false` → retry or terminal-fail per
    ///     ``EventConfig/maxRetries``.
    private func handleBatchResponse(_ rows: [QueueRow], response: EventBatchResponse?) {
        let byId: [String: QueueRow] = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        let results = response?.results
        guard let results = results, !results.isEmpty else {
            // No per-event detail — assume all succeeded.
            durableQueue.markSent(rows.map { $0.id })
            return
        }

        var successIds: [String] = []
        var failed: [String: Int] = [:]
        for r in results {
            guard let row = byId[r.id] else { continue }
            if r.success {
                successIds.append(r.id)
            } else {
                failed[r.id] = row.retryCount
                SwanLogger.warn(
                    "Swan.flush(): per-event failure id=\(r.id): \(r.error ?? "(no error)")"
                )
            }
        }
        // Defensive: rows the server didn't acknowledge at all → treat as
        // failed (partial response).
        let acked = Set(results.map { $0.id })
        for row in rows where !acked.contains(row.id) {
            failed[row.id] = row.retryCount
        }

        if !successIds.isEmpty {
            durableQueue.markSent(successIds)
        }
        if !failed.isEmpty {
            let outcome = durableQueue.recordPerEventFailures(failed)
            if !outcome.retriedIds.isEmpty {
                scheduleRetry(delay: outcome.nextRetryDelay)
            }
            if !outcome.terminalIds.isEmpty {
                SwanLogger.error(
                    "Swan.flush(): \(outcome.terminalIds.count) event(s) exhausted retries — moved to failed."
                )
            }
        }
    }

    /// Batch-wide failure (network error or non-2xx). All rows go through
    /// the per-event retry transition.
    private func handleBatchFailure(_ rows: [QueueRow]) {
        let outcome = durableQueue.markBatchFailed(rows)
        if !outcome.retriedIds.isEmpty {
            scheduleRetry(delay: outcome.nextRetryDelay)
        }
        if !outcome.terminalIds.isEmpty {
            SwanLogger.error(
                "Swan.flush(): batch failure exhausted retries for \(outcome.terminalIds.count) event(s) — moved to failed."
            )
        }
    }

    /// Schedule a delayed retry-flush. Cancels any pending retry first — if
    /// a new failure lands with a smaller delay, it takes precedence
    /// (mirrors RN holding ONE timeoutId in `retryTimeouts`).
    private func scheduleRetry(delay: TimeInterval) {
        lock.sync {
            retryTask?.cancel()
            let ns = UInt64(delay * 1_000_000_000)
            retryTask = Task.detached(priority: .utility) { [weak self] in
                do {
                    try await Task.sleep(nanoseconds: ns)
                } catch {
                    return
                }
                _ = await self?.flushOnce()
            }
        }
    }

    // MARK: - Static config

    static let pathTrackEvent = "/v2/trackEvent"

    /// Event-ingest JSON encoder.
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

// MARK: - NSLock sync sugar

private extension NSLock {
    func sync<T>(_ work: () -> T) -> T {
        lock(); defer { unlock() }
        return work()
    }
}
