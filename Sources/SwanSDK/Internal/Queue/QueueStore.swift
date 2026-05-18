import Foundation

/// Thin storage abstraction over the persistent event queue.
///
/// **Capability:** `offline-queue` (Phase 1.8 iOS port).
///
/// Mirror of Android's `QueueStore` interface. Same method signatures,
/// same semantics — only the language idioms differ.
///
/// Why a seam: the raw SQLite C API isn't worth dragging into pure-Swift
/// unit tests. Production wires ``SqliteQueueStore``; unit tests use
/// ``InMemoryQueueStore``.
///
/// All operations are synchronous + blocking — callers (the
/// ``DurableEventQueue`` facade) push the heavy ones off to a `Task.detached`
/// when the call site is async.
///
/// Implementations MUST be thread-safe: the SDK can call `insert(...)`
/// from any actor / task while a flush is running. SQLite handles its own
/// locking; the in-memory fake uses an `NSLock`.
protocol QueueStore: AnyObject {

    /// Insert a row. Caller has already constructed the ``QueueRow`` in full.
    func insert(_ row: QueueRow)

    /// Atomically:
    ///   1. SELECT up to `limit` rows WHERE status='pending',
    ///      ORDER BY priority DESC, timestamp ASC, retryCount ASC.
    ///   2. UPDATE those rows status='sending', lastAttemptAt=now.
    ///
    /// The "retryCount ASC" tertiary keeps just-failed rows from immediately
    /// monopolizing the next dequeue if a younger event hasn't been tried.
    /// RN orders by `priority DESC, timestamp ASC` only — adding retryCount
    /// is a native-port refinement that doesn't change the wire (timestamp
    /// is the dominant order).
    ///
    /// Returns the affected rows AFTER the status flip.
    func moveToSending(limit: Int, now: Int64) -> [QueueRow]

    /// Remove rows by id. Used after per-event success.
    func deleteByIds(_ ids: [String])

    /// Mark rows as `pending` again with `retryCount=newRetryCount` AND
    /// `lastAttemptAt=now`.
    func markPending(_ ids: [String], newRetryCount: Int, now: Int64)

    /// Restore rows to `pending` WITHOUT changing retryCount or
    /// lastAttemptAt. Used when an in-flight batch needs to be returned to
    /// the queue for a non-retry reason (e.g. credentials disappeared
    /// between dequeue and HTTP setup). Mirrors Android's `restorePending`.
    func restorePending(_ ids: [String])

    /// Mark rows as terminally `failed` with `retryCount=newRetryCount` AND
    /// `lastAttemptAt=now`. Rows stay until ``deleteFailedBefore(_:)``
    /// sweeps them.
    func markFailed(_ ids: [String], newRetryCount: Int, now: Int64)

    /// Count rows with status='pending'. `pre_reg`, `sending`, `failed` are
    /// NOT counted — matches RN
    /// (`EventQueueManager.getQueueSize` SELECT WHERE status='pending') and
    /// the `getQueueSize counts only pending events` conformance scenario.
    func countPending() -> Int

    /// Drop oldest `pending` rows so that the total `pending` count is at
    /// most `maxSize`. Returns the number of rows deleted.
    ///
    /// "drop oldest" matches `spec/behavior/queue.yaml`
    /// `max_queue_exceeded → drop_oldest_events`. Only `pending` rows are
    /// eligible for eviction; `sending` rows are mid-flight, `failed` rows
    /// are kept until cleanup, and `pre_reg` rows are NOT counted toward
    /// the budget.
    func enforcePendingLimit(maxSize: Int) -> Int

    /// Reset `sending` rows whose `lastAttemptAt < olderThanMs` back to
    /// `pending`. Caller passes `(now - staleSendingThresholdMs)`. Returns
    /// the number of rows recovered.
    ///
    /// Spec: `spec/behavior/queue.yaml` `stale_sending_recovery`, threshold
    /// 300_000 ms. retryCount is preserved — a crash isn't a retry.
    func recoverStaleSending(olderThanMs: Int64) -> Int

    /// Delete rows with status='failed' AND createdAt < olderThanMs.
    /// Matches RN `clearOldEvents`.
    func deleteFailedBefore(_ olderThanMs: Int64) -> Int

    /// Return all `pre_reg` rows in enqueue order (timestamp ASC) AND
    /// delete them. Caller (the promote path) decodes
    /// `QueueRow.eventDataJson` as the caller attributes, enriches with
    /// current credentials, and re-inserts with status='pending'.
    func drainPreRegistration() -> [QueueRow]

    // MARK: - Test seams

    /// Returns every row, in insertion order. Test-only — production code
    /// uses targeted queries.
    func selectAll() -> [QueueRow]

    /// Wipe everything. Test-only seam, also useful for "wipe data" in v2.
    func deleteAll()

    /// Close any underlying handles (SQLite db). No-op on the in-memory fake.
    func close()
}
