import Foundation

/// High-level facade over the persistent event queue.
///
/// **Capabilities:** `offline-queue`, `network-resilience`, `force-flush`.
///
/// Spec:
///   - `spec/behavior/queue.yaml`                            (state machine + constants)
///   - `spec/api/offline.yaml`                               (flushEvents + getQueueSize)
///   - `conformance/scenarios/offline-queue.feature`         (all six scenarios)
///   - `conformance/scenarios/force-flush.feature`           (getQueueSize counts pending only)
///   - `conformance/scenarios/network-resilience.feature`    (retry budget + backoff)
///
/// Mirror of Android's `DurableEventQueue.kt`. Owns:
///
///   - Track-time CDID + enrichment capture (build the ``BatchEvent``
///     eagerly when credentials are available, store as `pending`).
///   - Pre-registration buffer durability (events accepted before creds
///     land are stored as `pre_reg`; ``promotePreRegistration()`` flips them
///     to `pending` with full enrichment once `Swan.initialize` finishes
///     registering).
///   - Overflow drop-oldest policy.
///   - Atomic dequeue → `sending`.
///   - Per-event success / failure transitions (retryCount + max-retry →
///     `failed`, otherwise back to `pending`).
///   - Batch network failure (re-pending all rows with retryCount+1).
///   - Stale `sending` recovery on init.
///   - Periodic cleanup of `failed` rows older than ``EventConfig``.
///   - Exponential-backoff TIMING math (2s/4s/8s) via ``computeBackoffDelay``.
///
/// ## iOS-vs-Android divergences
///
///   - `pre_reg` status is mirrored from Android (RN's pre-reg path is a 15s
///     wait-loop that THROWS on timeout — see RN `src/index.tsx:2147-2151`).
///     Native ports' buffer is non-blocking. Conformance scenarios pass
///     because `pre_reg` doesn't count toward `getQueueSize`.
///
///   - JSON encoding uses Foundation's `JSONEncoder` instead of Kotlin's
///     `kotlinx.serialization.Json` — but the produced bytes are
///     parsed-tree-equivalent. `BatchEvent.encode(to:)` carries the
///     `currentCDID = nil → JSON null` invariant that Foundation's default
///     wouldn't preserve.
///
///   - Stale-sending recovery preserves retryCount (matches Android + RN).
final class DurableEventQueue {

    private let store: QueueStore
    private let credentialsStore: CredentialsStore
    private let sessionManager: SessionManager
    private let deviceInfoProvider: @Sendable () -> EventEnrichment.DeviceInfo
    private let configProvider: @Sendable () -> EventConfig
    private let clock: @Sendable () -> Int64

    init(
        store: QueueStore,
        credentialsStore: CredentialsStore,
        sessionManager: SessionManager,
        deviceInfoProvider: @escaping @Sendable () -> EventEnrichment.DeviceInfo,
        configProvider: @escaping @Sendable () -> EventConfig,
        clock: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.store = store
        self.credentialsStore = credentialsStore
        self.sessionManager = sessionManager
        self.deviceInfoProvider = deviceInfoProvider
        self.configProvider = configProvider
        self.clock = clock
    }

    // MARK: - Enqueue

    /// Enqueue a custom event. If credentials are available, the event is
    /// stored as `pending` with the FULL enriched payload (track-time CDID
    /// + enrichment capture, RN parity). If not, it is stored as `pre_reg`
    /// with the caller's attributes only — promotion via
    /// ``promotePreRegistration()`` will enrich + flip to `pending`.
    ///
    /// After insertion, the `pending` slice is trimmed to
    /// `EventConfig.maxQueueSize` by dropping the OLDEST rows.
    /// `pre_reg` rows are not counted toward the budget.
    ///
    /// Returns the post-enqueue count of `pending` rows so the caller can
    /// decide whether to trigger a size-threshold flush.
    @discardableResult
    func enqueueCustomEvent(
        id: String,
        name: String,
        attributes: [String: JSONValue],
        timestamp: Int64? = nil
    ) -> Int {
        let now = timestamp ?? clock()
        let creds = credentialsStore.read()
        let row: QueueRow
        if let creds = creds {
            // Fully-enriched path — matches RN's trackEvent which builds the
            // full payload at enqueue time (src/index.tsx:2166-2199).
            let batchEvent = buildBatchEvent(
                id: id,
                name: name,
                timestamp: now,
                attributes: attributes,
                creds: creds
            )
            row = QueueRow(
                id: id,
                eventName: name,
                eventDataJson: encodeBatchEvent(batchEvent),
                timestamp: now,
                priority: 0,
                retryCount: 0,
                status: .pending,
                createdAt: now,
                lastAttemptAt: nil
            )
        } else {
            // Pre-reg path — only the caller attributes are durable; the
            // session/CDID/enrichment is resolved at promote time.
            let payload = PreRegPayload(name: name, attributes: attributes)
            row = QueueRow(
                id: id,
                eventName: name,
                eventDataJson: encodePreReg(payload),
                timestamp: now,
                priority: 0,
                retryCount: 0,
                status: .preReg,
                createdAt: now,
                lastAttemptAt: nil
            )
        }
        store.insert(row)
        // Enforce queue cap on the pending slice ONLY (pre_reg doesn't count).
        let dropped = store.enforcePendingLimit(maxSize: configProvider().maxQueueSize)
        if dropped > 0 {
            SwanLogger.warn(
                "Queue cap reached — dropped \(dropped) oldest pending event(s)."
            )
        }
        return store.countPending()
    }

    /// Drain pre-registration rows, enrich each with current credentials +
    /// session id, and re-insert as `pending`. Called by EventTracker after
    /// `Swan.initialize` resolves credentials. FIFO order preserved by
    /// timestamp ASC.
    ///
    /// Returns the number of rows promoted (0 if creds are still missing
    /// or there were no pre_reg rows).
    @discardableResult
    func promotePreRegistration() -> Int {
        guard let creds = credentialsStore.read() else { return 0 }
        let preReg = store.drainPreRegistration()
        guard !preReg.isEmpty else { return 0 }
        for row in preReg {
            guard let parsed = decodePreReg(row.eventDataJson) else {
                SwanLogger.warn("Pre-reg row \(row.id) had unparseable payload; dropped.")
                continue
            }
            let batchEvent = buildBatchEvent(
                id: row.id,
                name: parsed.name,
                timestamp: row.timestamp,
                attributes: parsed.attributes,
                creds: creds
            )
            store.insert(QueueRow(
                id: row.id,
                eventName: row.eventName,
                eventDataJson: encodeBatchEvent(batchEvent),
                timestamp: row.timestamp,
                priority: row.priority,
                retryCount: row.retryCount,
                status: .pending,
                createdAt: row.createdAt,
                lastAttemptAt: row.lastAttemptAt
            ))
        }
        let dropped = store.enforcePendingLimit(maxSize: configProvider().maxQueueSize)
        if dropped > 0 {
            SwanLogger.warn(
                "Queue cap reached on promotion — dropped \(dropped) oldest event(s)."
            )
        }
        return preReg.count
    }

    // MARK: - Recovery / cleanup

    /// Recover any `sending` rows that crashed mid-flush. Resets them back
    /// to `pending` with retryCount UNCHANGED. Called by EventTracker on init.
    @discardableResult
    func recoverStaleSending() -> Int {
        let cutoff = clock() - DurableEventQueue.staleSendingThresholdMs
        let recovered = store.recoverStaleSending(olderThanMs: cutoff)
        if recovered > 0 {
            SwanLogger.debug(
                "Recovered \(recovered) stale 'sending' row(s) after crash mid-flush."
            )
        }
        return recovered
    }

    /// Clean up `failed` rows older than `queueCleanupDays`. Called from the
    /// periodic-flush coroutine — RN runs this opportunistically inside
    /// FlushManager.
    @discardableResult
    func cleanupOldFailedEvents() -> Int {
        let cfg = configProvider()
        let cutoff = clock() - Int64(cfg.queueCleanupDays) * 24 * 60 * 60 * 1000
        let deleted = store.deleteFailedBefore(cutoff)
        if deleted > 0 {
            SwanLogger.debug(
                "Cleaned up \(deleted) failed row(s) older than \(cfg.queueCleanupDays) day(s)."
            )
        }
        return deleted
    }

    // MARK: - Send-side state machine

    /// Atomically dequeue up to `batchSize` `pending` rows and mark them
    /// `sending`. Returns the decoded ``BatchEvent``s ready to be POSTed
    /// along with the underlying ``QueueRow``s (so the caller can refund
    /// retryCount on failure).
    func dequeueForSend(batchSize: Int) -> [DequeuedRow] {
        let rows = store.moveToSending(limit: batchSize, now: clock())
        return rows.compactMap { row in
            guard let event = decodeBatchEvent(row.eventDataJson) else {
                SwanLogger.warn(
                    "Queue row \(row.id) had unparseable BatchEvent JSON; treating as send-failed."
                )
                // Drop the unparseable row — leaving it in `sending` would
                // bloat the queue and re-driving it serves no purpose.
                store.deleteByIds([row.id])
                return nil
            }
            return DequeuedRow(row: row, event: event)
        }
    }

    /// Per-event success → delete row(s).
    func markSent(_ ids: [String]) {
        store.deleteByIds(ids)
    }

    /// Per-event failure → bump retryCount, transition to `pending` or
    /// terminal `failed` per `EventConfig.maxRetries`. Returns the ids that
    /// were terminally failed + the ids that were re-queued + the suggested
    /// backoff delay for the next retry.
    func recordPerEventFailures(_ previousRetryCounts: [String: Int]) -> PerEventFailureResult {
        let cfg = configProvider()
        let now = clock()
        var terminal: [String] = []
        var retried: [String] = []
        for (id, prev) in previousRetryCounts {
            let next = prev + 1
            if next >= cfg.maxRetries {
                store.markFailed([id], newRetryCount: next, now: now)
                terminal.append(id)
            } else {
                store.markPending([id], newRetryCount: next, now: now)
                retried.append(id)
            }
        }
        let minPrev = previousRetryCounts.values.min() ?? 0
        return PerEventFailureResult(
            terminalIds: terminal,
            retriedIds: retried,
            nextRetryDelay: DurableEventQueue.computeBackoffDelay(
                retryCount: minPrev + 1,
                config: cfg
            )
        )
    }

    /// Batch network failure (no HTTP response). Spec
    /// `spec/behavior/queue.yaml#batch_network_failure`: ALL rows in the
    /// batch get retryCount+1, those still under maxRetries go back to
    /// `pending`, the rest become `failed`.
    func markBatchFailed(_ rows: [QueueRow]) -> PerEventFailureResult {
        var map: [String: Int] = [:]
        for row in rows { map[row.id] = row.retryCount }
        return recordPerEventFailures(map)
    }

    /// Push rows back to `pending` WITHOUT touching retryCount — used when
    /// an in-flight batch is returned to the queue for a reason that isn't
    /// a real send attempt (e.g. credentials disappear between dequeue and
    /// HTTP setup).
    func restoreToPending(_ ids: [String]) {
        store.restorePending(ids)
    }

    // MARK: - Observation

    /// Number of `pending` rows. Used by `Swan.getQueueSize()`.
    func pendingCount() -> Int { store.countPending() }

    /// Count of `pre_reg` rows (test seam / diagnostics).
    func preRegCount() -> Int {
        store.selectAll().reduce(into: 0) { $0 += ($1.status == .preReg ? 1 : 0) }
    }

    /// Snapshot every row currently in the store, in createdAt order
    /// (oldest first). Test-only.
    func snapshotAll() -> [QueueRow] { store.selectAll() }

    /// Snapshot of pending rows decoded back into ``BatchEvent``s, FIFO
    /// order. Test seam.
    func snapshotPendingEvents() -> [BatchEvent] {
        return store.selectAll()
            .filter { $0.status == .pending }
            .sorted { $0.timestamp < $1.timestamp }
            .compactMap { decodeBatchEvent($0.eventDataJson) }
    }

    /// Wipe everything. Test-only.
    func clear() { store.deleteAll() }

    /// Free underlying handles.
    func close() { store.close() }

    // MARK: - Wire-shape building

    private func buildBatchEvent(
        id: String,
        name: String,
        timestamp: Int64,
        attributes: [String: JSONValue],
        creds: SwanCredentials
    ) -> BatchEvent {
        let cfg = configProvider()
        let data = EventEnrichment.enrich(
            attributes: attributes,
            config: cfg,
            deviceId: creds.deviceId,
            sessionId: sessionManager.getId(),
            deviceInfo: deviceInfoProvider()
        )
        return BatchEvent(
            id: id,
            name: name,
            timestamp: timestamp,
            data: data,
            // Track-time CDID capture — see EventTracker class doc.
            userId: creds.currentCDID ?? creds.generatedCDID,
            currentCDID: creds.currentCDID,
            generatedCDID: creds.generatedCDID
        )
    }

    // MARK: - JSON helpers

    private static let jsonEncoder: JSONEncoder = {
        let enc = JSONEncoder()
        return enc
    }()

    private static let jsonDecoder: JSONDecoder = {
        let dec = JSONDecoder()
        return dec
    }()

    private func encodeBatchEvent(_ event: BatchEvent) -> String {
        do {
            let data = try DurableEventQueue.jsonEncoder.encode(event)
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            SwanLogger.error("DurableEventQueue.encodeBatchEvent failed: \(error)")
            return ""
        }
    }

    private func decodeBatchEvent(_ json: String) -> BatchEvent? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? DurableEventQueue.jsonDecoder.decode(BatchEvent.self, from: data)
    }

    private func encodePreReg(_ payload: PreRegPayload) -> String {
        do {
            let data = try DurableEventQueue.jsonEncoder.encode(payload)
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            SwanLogger.error("DurableEventQueue.encodePreReg failed: \(error)")
            return ""
        }
    }

    private func decodePreReg(_ json: String) -> PreRegPayload? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? DurableEventQueue.jsonDecoder.decode(PreRegPayload.self, from: data)
    }

    // MARK: - Static config (mirrors Android `companion object`)

    /// `spec/behavior/queue.yaml staleSendingThreshold_ms = 300000`. Rows
    /// stuck in `sending` longer than this are reset to `pending` on init.
    static let staleSendingThresholdMs: Int64 = 5 * 60 * 1000

    /// `spec/behavior/queue.yaml maxRetries / retryBaseDelay` exponential
    /// sequence. Caller passes the NEW retryCount (post-increment).
    ///
    /// `2s, 4s, 8s` pattern: `base * 2^(retryCount-1)`. Matches RN's
    /// `FlushManager.ts:228`.
    static func computeBackoffDelay(retryCount: Int, config: EventConfig) -> TimeInterval {
        let safe = max(retryCount, 1)
        let factor = Double(1 << (safe - 1))
        return config.retryBaseDelay * factor
    }

    // MARK: - Nested types

    /// Caller-supplied data captured for a `pre_reg` row. We persist this
    /// minimal shape (name + attributes) and re-enrich on promotion so the
    /// post-promote BatchEvent picks up the session id + device info that
    /// exists when credentials land, not when `track()` was called pre-init.
    struct PreRegPayload: Codable {
        let name: String
        let attributes: [String: JSONValue]

        enum CodingKeys: String, CodingKey {
            case name = "_name"
            case attributes = "_attrs"
        }
    }

    /// A row dequeued for send — both the original row (so we can refund
    /// retryCount on failure) and the decoded ``BatchEvent`` (ready to
    /// ship).
    struct DequeuedRow {
        let row: QueueRow
        let event: BatchEvent
    }

    /// Outcome of a per-event failure round.
    struct PerEventFailureResult {
        let terminalIds: [String]
        let retriedIds: [String]
        let nextRetryDelay: TimeInterval
    }
}
