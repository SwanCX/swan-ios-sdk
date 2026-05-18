import Foundation

/// Test fake — pure Swift, no SQLite dep.
///
/// **Capability:** `offline-queue` (Phase 1.8 iOS port).
///
/// Mirrors the SQL ordering and predicate semantics of ``SqliteQueueStore``
/// 1:1 so unit-test results match production. Insertion-order is the
/// default tiebreaker for rows with identical timestamps.
///
/// Mirror of Android's `InMemoryQueueStore.kt`. Same set of operations,
/// same ordering rules, same locking discipline (a single `NSLock`).
final class InMemoryQueueStore: QueueStore {

    private let lock = NSLock()
    /// Preserve insertion order so deletes are O(1) and iteration stable.
    /// Swift's `Dictionary` is unordered; we keep a parallel ordered keys
    /// array.
    private var rows: [String: QueueRow] = [:]
    private var orderedKeys: [String] = []

    init() {}

    func insert(_ row: QueueRow) {
        lock.lock(); defer { lock.unlock() }
        if rows[row.id] == nil {
            orderedKeys.append(row.id)
        }
        rows[row.id] = row
    }

    func moveToSending(limit: Int, now: Int64) -> [QueueRow] {
        lock.lock(); defer { lock.unlock() }
        guard limit > 0 else { return [] }
        // Match SqliteQueueStore: ORDER BY priority DESC, timestamp ASC,
        // retryCount ASC.
        let selected = orderedKeys.compactMap { rows[$0] }
            .filter { $0.status == .pending }
            .sorted { lhs, rhs in
                if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
                if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
                return lhs.retryCount < rhs.retryCount
            }
            .prefix(limit)
        var out: [QueueRow] = []
        for row in selected {
            let updated = row.copy(status: .sending, lastAttemptAt: .some(now))
            rows[row.id] = updated
            out.append(updated)
        }
        return out
    }

    func deleteByIds(_ ids: [String]) {
        lock.lock(); defer { lock.unlock() }
        for id in ids {
            rows.removeValue(forKey: id)
        }
        let removed = Set(ids)
        orderedKeys.removeAll { removed.contains($0) }
    }

    func markPending(_ ids: [String], newRetryCount: Int, now: Int64) {
        lock.lock(); defer { lock.unlock() }
        for id in ids {
            guard let row = rows[id] else { continue }
            rows[id] = row.copy(
                retryCount: newRetryCount,
                status: .pending,
                lastAttemptAt: .some(now)
            )
        }
    }

    func restorePending(_ ids: [String]) {
        lock.lock(); defer { lock.unlock() }
        for id in ids {
            guard let row = rows[id] else { continue }
            rows[id] = row.copy(status: .pending)
        }
    }

    func markFailed(_ ids: [String], newRetryCount: Int, now: Int64) {
        lock.lock(); defer { lock.unlock() }
        for id in ids {
            guard let row = rows[id] else { continue }
            rows[id] = row.copy(
                retryCount: newRetryCount,
                status: .failed,
                lastAttemptAt: .some(now)
            )
        }
    }

    func countPending() -> Int {
        lock.lock(); defer { lock.unlock() }
        return rows.values.reduce(into: 0) { $0 += ($1.status == .pending ? 1 : 0) }
    }

    func enforcePendingLimit(maxSize: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        let pendings = orderedKeys.compactMap { rows[$0] }
            .filter { $0.status == .pending }
            .sorted { $0.timestamp < $1.timestamp }
        let excess = pendings.count - maxSize
        guard excess > 0 else { return 0 }
        let toDrop = pendings.prefix(excess).map { $0.id }
        for id in toDrop {
            rows.removeValue(forKey: id)
        }
        let removed = Set(toDrop)
        orderedKeys.removeAll { removed.contains($0) }
        return excess
    }

    func recoverStaleSending(olderThanMs: Int64) -> Int {
        lock.lock(); defer { lock.unlock() }
        // Per spec the recovery only flips status — retryCount and
        // lastAttemptAt are preserved (RN's recoverStaleEvents does NOT
        // increment retryCount either; src/core/EventQueueManager.ts:428).
        var count = 0
        for (id, row) in rows {
            if row.status == .sending && (row.lastAttemptAt ?? 0) < olderThanMs {
                rows[id] = row.copy(status: .pending)
                count += 1
            }
        }
        return count
    }

    func deleteFailedBefore(_ olderThanMs: Int64) -> Int {
        lock.lock(); defer { lock.unlock() }
        let toDelete = rows.values
            .filter { $0.status == .failed && $0.createdAt < olderThanMs }
            .map { $0.id }
        for id in toDelete {
            rows.removeValue(forKey: id)
        }
        let removed = Set(toDelete)
        orderedKeys.removeAll { removed.contains($0) }
        return toDelete.count
    }

    func drainPreRegistration() -> [QueueRow] {
        lock.lock(); defer { lock.unlock() }
        let drained = rows.values
            .filter { $0.status == .preReg }
            .sorted { $0.timestamp < $1.timestamp }
        let ids = Set(drained.map { $0.id })
        for id in ids {
            rows.removeValue(forKey: id)
        }
        orderedKeys.removeAll { ids.contains($0) }
        return drained
    }

    func selectAll() -> [QueueRow] {
        lock.lock(); defer { lock.unlock() }
        return orderedKeys.compactMap { rows[$0] }
    }

    func deleteAll() {
        lock.lock(); defer { lock.unlock() }
        rows.removeAll()
        orderedKeys.removeAll()
    }

    func close() {
        // No-op.
    }
}
