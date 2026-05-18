import Foundation
import SQLite3

/// SQLite-backed ``QueueStore``.
///
/// **Capability:** `offline-queue` (Phase 1.8 iOS port).
///
/// Schema mirrors RN's `EventQueue` table
/// (`swan-react-native-sdk/src/core/EventQueueManager.ts:32-42`) verbatim —
/// same table name `EventQueue`, same column names, same indexes — so a
/// device migrating from RN sees a recognisable database, and conformance
/// scenarios that reference the schema verbatim hold on iOS the same way
/// they hold on Android.
///
/// ## Why raw SQLite (the `sqlite3` C API), not GRDB / FMDB / SQLite.swift
///
///   - **Zero new dependencies**: `import SQLite3` works on every Apple
///     platform back to iOS 8 with no Package.swift change. GRDB / FMDB /
///     SQLite.swift would each add a dep + version-resolution surface for
///     every host app that pulls SwanSDK in.
///   - **Mirrors Android's posture**: Android also dropped raw SQLite over
///     Room. Native ports stay consistent.
///   - **Tooling parity with RN**: RN's WebSQL is raw SQLite under the
///     covers. Anyone inspecting the on-device DB (Xcode container browser,
///     `sqlite3` CLI) sees the same byte layout regardless of the SDK
///     they're holding.
///
/// If we ever need observation (combine publishers on queue size, etc.) in
/// v2, swapping to GRDB behind the ``QueueStore`` protocol is contained.
///
/// ## Concurrency
///
/// `sqlite3` itself serializes statements when opened in
/// `SQLITE_OPEN_FULLMUTEX` mode (the default for `sqlite3_open_v2` with no
/// flags), but we open in `SQLITE_OPEN_NOMUTEX` and pair every operation
/// with our own `NSLock` — that lets us batch multiple statements inside a
/// transaction without a second mutex hop, and keeps the threading story
/// identical to ``InMemoryQueueStore`` (single coarse lock).
///
/// Mirror of Android's `SqliteQueueStore.kt` — same SQL, same column names.
final class SqliteQueueStore: QueueStore {

    // MARK: - Constants (mirror Android's `companion object`)

    static let defaultDbName = "swan_event_queue.db"

    static let table = "EventQueue"
    static let colId = "id"
    static let colEventName = "eventName"
    static let colEventData = "eventData"
    static let colTimestamp = "timestamp"
    static let colPriority = "priority"
    static let colRetryCount = "retryCount"
    static let colStatus = "status"
    static let colCreatedAt = "createdAt"
    static let colLastAttemptAt = "lastAttemptAt"

    private static let dbVersion: Int32 = 1

    /// Schema mirrors RN's `EventQueue` verbatim. Status defaults to
    /// 'pending' for byte-parity.
    private static let createTableSql = """
    CREATE TABLE IF NOT EXISTS EventQueue (
        id TEXT PRIMARY KEY,
        eventName TEXT NOT NULL,
        eventData TEXT NOT NULL,
        timestamp INTEGER NOT NULL,
        priority INTEGER NOT NULL DEFAULT 0,
        retryCount INTEGER NOT NULL DEFAULT 0,
        status TEXT NOT NULL DEFAULT 'pending',
        createdAt INTEGER NOT NULL,
        lastAttemptAt INTEGER
    )
    """

    private static let createIdxStatusSql =
        "CREATE INDEX IF NOT EXISTS idx_status ON EventQueue(status)"
    private static let createIdxPrioritySql =
        "CREATE INDEX IF NOT EXISTS idx_priority ON EventQueue(priority DESC)"
    private static let createIdxTimestampSql =
        "CREATE INDEX IF NOT EXISTS idx_timestamp ON EventQueue(timestamp ASC)"

    // MARK: - State

    private var db: OpaquePointer?
    private let lock = NSLock()
    private let dbPath: String

    // MARK: - Init / open

    /// Factory — opens the SQLite DB at the SDK's default Application Support
    /// directory location and applies the schema. Throws on file-system or
    /// SQLite errors.
    ///
    /// - Parameter dbName: file basename inside Application Support. Defaults
    ///   to ``defaultDbName`` (`"swan_event_queue.db"`).
    static func open(dbName: String = SqliteQueueStore.defaultDbName) throws -> SqliteQueueStore {
        let fm = FileManager.default
        // Application Support is the canonical location for app-specific
        // SQLite databases per Apple's File System Programming Guide. It's
        // backed up by iCloud / iTunes by default (we don't tag with the
        // exclusion attribute because the event queue IS user data).
        let supportDir = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let swanDir = supportDir.appendingPathComponent("SwanSDK", isDirectory: true)
        if !fm.fileExists(atPath: swanDir.path) {
            try fm.createDirectory(at: swanDir, withIntermediateDirectories: true)
        }
        let dbUrl = swanDir.appendingPathComponent(dbName)
        return try SqliteQueueStore(path: dbUrl.path)
    }

    /// Test-only — opens the DB at a caller-supplied path. Mirrors Android's
    /// `SqliteQueueStore(helper)` constructor for in-memory test instances.
    /// Pass `":memory:"` for a transient store.
    init(path: String) throws {
        self.dbPath = path
        var handle: OpaquePointer?
        // SQLITE_OPEN_NOMUTEX: we coordinate access via NSLock above.
        let flags: Int32 = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        guard rc == SQLITE_OK, let h = handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown sqlite open error"
            handle.map { sqlite3_close($0) }
            throw SqliteError.open(rc: rc, message: msg)
        }
        self.db = h
        try exec(SqliteQueueStore.createTableSql)
        try exec(SqliteQueueStore.createIdxStatusSql)
        try exec(SqliteQueueStore.createIdxPrioritySql)
        try exec(SqliteQueueStore.createIdxTimestampSql)
    }

    deinit {
        if let db = db { sqlite3_close(db) }
    }

    // MARK: - QueueStore impl

    func insert(_ row: QueueRow) {
        lock.lock(); defer { lock.unlock() }
        // REPLACE handles the edge case where the same UUID is enqueued
        // twice — defensive only, idGenerator() is collision-free. Same as
        // Android.
        let sql = """
        INSERT OR REPLACE INTO EventQueue
            (id, eventName, eventData, timestamp, priority, retryCount, status, createdAt, lastAttemptAt)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        do {
            try prepare(sql) { stmt in
                bindText(stmt, 1, row.id)
                bindText(stmt, 2, row.eventName)
                bindText(stmt, 3, row.eventDataJson)
                sqlite3_bind_int64(stmt, 4, row.timestamp)
                sqlite3_bind_int(stmt, 5, Int32(row.priority))
                sqlite3_bind_int(stmt, 6, Int32(row.retryCount))
                bindText(stmt, 7, row.status.wire)
                sqlite3_bind_int64(stmt, 8, row.createdAt)
                if let last = row.lastAttemptAt {
                    sqlite3_bind_int64(stmt, 9, last)
                } else {
                    sqlite3_bind_null(stmt, 9)
                }
                let rc = sqlite3_step(stmt)
                if rc != SQLITE_DONE {
                    throw SqliteError.step(rc: rc, message: lastErrorMessage())
                }
            }
        } catch {
            SwanLogger.error("SqliteQueueStore.insert: \(error)")
        }
    }

    func moveToSending(limit: Int, now: Int64) -> [QueueRow] {
        lock.lock(); defer { lock.unlock() }
        guard limit > 0 else { return [] }
        var rows: [QueueRow] = []
        do {
            try exec("BEGIN")
            // SELECT pending in order.
            let select = """
            SELECT id, eventName, eventData, timestamp, priority, retryCount, status, createdAt, lastAttemptAt
            FROM EventQueue
            WHERE status = ?
            ORDER BY priority DESC, timestamp ASC, retryCount ASC
            LIMIT ?
            """
            try prepare(select) { stmt in
                bindText(stmt, 1, QueueStatus.pending.wire)
                sqlite3_bind_int(stmt, 2, Int32(limit))
                while sqlite3_step(stmt) == SQLITE_ROW {
                    rows.append(readRow(stmt))
                }
            }
            // UPDATE selected rows → sending.
            if !rows.isEmpty {
                let placeholders = Array(repeating: "?", count: rows.count).joined(separator: ",")
                let update = "UPDATE EventQueue SET status = ?, lastAttemptAt = ? WHERE id IN (\(placeholders))"
                try prepare(update) { stmt in
                    bindText(stmt, 1, QueueStatus.sending.wire)
                    sqlite3_bind_int64(stmt, 2, now)
                    var idx: Int32 = 3
                    for row in rows {
                        bindText(stmt, idx, row.id)
                        idx += 1
                    }
                    let rc = sqlite3_step(stmt)
                    if rc != SQLITE_DONE {
                        throw SqliteError.step(rc: rc, message: lastErrorMessage())
                    }
                }
            }
            try exec("COMMIT")
        } catch {
            _ = try? exec("ROLLBACK")
            SwanLogger.error("SqliteQueueStore.moveToSending: \(error)")
            return []
        }
        return rows.map { $0.copy(status: .sending, lastAttemptAt: .some(now)) }
    }

    func deleteByIds(_ ids: [String]) {
        lock.lock(); defer { lock.unlock() }
        guard !ids.isEmpty else { return }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let sql = "DELETE FROM EventQueue WHERE id IN (\(placeholders))"
        do {
            try prepare(sql) { stmt in
                for (i, id) in ids.enumerated() {
                    bindText(stmt, Int32(i + 1), id)
                }
                let rc = sqlite3_step(stmt)
                if rc != SQLITE_DONE {
                    throw SqliteError.step(rc: rc, message: lastErrorMessage())
                }
            }
        } catch {
            SwanLogger.error("SqliteQueueStore.deleteByIds: \(error)")
        }
    }

    func markPending(_ ids: [String], newRetryCount: Int, now: Int64) {
        updateMany(
            ids: ids,
            sql: "UPDATE EventQueue SET status = ?, retryCount = ?, lastAttemptAt = ? WHERE id IN",
            bindPrefix: { stmt in
                bindText(stmt, 1, QueueStatus.pending.wire)
                sqlite3_bind_int(stmt, 2, Int32(newRetryCount))
                sqlite3_bind_int64(stmt, 3, now)
            },
            firstIdParam: 4
        )
    }

    func restorePending(_ ids: [String]) {
        updateMany(
            ids: ids,
            sql: "UPDATE EventQueue SET status = ? WHERE id IN",
            bindPrefix: { stmt in
                bindText(stmt, 1, QueueStatus.pending.wire)
            },
            firstIdParam: 2
        )
    }

    func markFailed(_ ids: [String], newRetryCount: Int, now: Int64) {
        updateMany(
            ids: ids,
            sql: "UPDATE EventQueue SET status = ?, retryCount = ?, lastAttemptAt = ? WHERE id IN",
            bindPrefix: { stmt in
                bindText(stmt, 1, QueueStatus.failed.wire)
                sqlite3_bind_int(stmt, 2, Int32(newRetryCount))
                sqlite3_bind_int64(stmt, 3, now)
            },
            firstIdParam: 4
        )
    }

    func countPending() -> Int {
        lock.lock(); defer { lock.unlock() }
        var result = 0
        do {
            try prepare("SELECT COUNT(*) FROM EventQueue WHERE status = ?") { stmt in
                bindText(stmt, 1, QueueStatus.pending.wire)
                if sqlite3_step(stmt) == SQLITE_ROW {
                    result = Int(sqlite3_column_int(stmt, 0))
                }
            }
        } catch {
            SwanLogger.error("SqliteQueueStore.countPending: \(error)")
        }
        return result
    }

    func enforcePendingLimit(maxSize: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        // 1. Compute excess.
        var excess = 0
        do {
            try prepare("SELECT MAX(0, COUNT(*) - ?) FROM EventQueue WHERE status = ?") { stmt in
                sqlite3_bind_int(stmt, 1, Int32(maxSize))
                bindText(stmt, 2, QueueStatus.pending.wire)
                if sqlite3_step(stmt) == SQLITE_ROW {
                    excess = Int(sqlite3_column_int(stmt, 0))
                }
            }
        } catch {
            SwanLogger.error("SqliteQueueStore.enforcePendingLimit (count): \(error)")
            return 0
        }
        guard excess > 0 else { return 0 }
        // 2. SELECT the OLDEST `excess` pending ids.
        var toDelete: [String] = []
        do {
            try prepare("""
            SELECT id FROM EventQueue
            WHERE status = ?
            ORDER BY timestamp ASC
            LIMIT ?
            """) { stmt in
                bindText(stmt, 1, QueueStatus.pending.wire)
                sqlite3_bind_int(stmt, 2, Int32(excess))
                while sqlite3_step(stmt) == SQLITE_ROW {
                    if let cstr = sqlite3_column_text(stmt, 0) {
                        toDelete.append(String(cString: cstr))
                    }
                }
            }
        } catch {
            SwanLogger.error("SqliteQueueStore.enforcePendingLimit (select): \(error)")
            return 0
        }
        // 3. Delete them.
        if !toDelete.isEmpty {
            // deleteByIds takes its own lock — re-enter is safe via NSLock?
            // NSLock isn't recursive. Inline the delete.
            let placeholders = Array(repeating: "?", count: toDelete.count).joined(separator: ",")
            let sql = "DELETE FROM EventQueue WHERE id IN (\(placeholders))"
            do {
                try prepare(sql) { stmt in
                    for (i, id) in toDelete.enumerated() {
                        bindText(stmt, Int32(i + 1), id)
                    }
                    let rc = sqlite3_step(stmt)
                    if rc != SQLITE_DONE {
                        throw SqliteError.step(rc: rc, message: lastErrorMessage())
                    }
                }
            } catch {
                SwanLogger.error("SqliteQueueStore.enforcePendingLimit (delete): \(error)")
                return 0
            }
        }
        return toDelete.count
    }

    func recoverStaleSending(olderThanMs: Int64) -> Int {
        lock.lock(); defer { lock.unlock() }
        do {
            try prepare("""
            UPDATE EventQueue
            SET status = ?
            WHERE status = ? AND lastAttemptAt < ?
            """) { stmt in
                bindText(stmt, 1, QueueStatus.pending.wire)
                bindText(stmt, 2, QueueStatus.sending.wire)
                sqlite3_bind_int64(stmt, 3, olderThanMs)
                let rc = sqlite3_step(stmt)
                if rc != SQLITE_DONE {
                    throw SqliteError.step(rc: rc, message: lastErrorMessage())
                }
            }
            return Int(sqlite3_changes(db))
        } catch {
            SwanLogger.error("SqliteQueueStore.recoverStaleSending: \(error)")
            return 0
        }
    }

    func deleteFailedBefore(_ olderThanMs: Int64) -> Int {
        lock.lock(); defer { lock.unlock() }
        do {
            try prepare("DELETE FROM EventQueue WHERE status = ? AND createdAt < ?") { stmt in
                bindText(stmt, 1, QueueStatus.failed.wire)
                sqlite3_bind_int64(stmt, 2, olderThanMs)
                let rc = sqlite3_step(stmt)
                if rc != SQLITE_DONE {
                    throw SqliteError.step(rc: rc, message: lastErrorMessage())
                }
            }
            return Int(sqlite3_changes(db))
        } catch {
            SwanLogger.error("SqliteQueueStore.deleteFailedBefore: \(error)")
            return 0
        }
    }

    func drainPreRegistration() -> [QueueRow] {
        lock.lock(); defer { lock.unlock() }
        var out: [QueueRow] = []
        do {
            try exec("BEGIN")
            try prepare("""
            SELECT id, eventName, eventData, timestamp, priority, retryCount, status, createdAt, lastAttemptAt
            FROM EventQueue
            WHERE status = ?
            ORDER BY timestamp ASC
            """) { stmt in
                bindText(stmt, 1, QueueStatus.preReg.wire)
                while sqlite3_step(stmt) == SQLITE_ROW {
                    out.append(readRow(stmt))
                }
            }
            if !out.isEmpty {
                try prepare("DELETE FROM EventQueue WHERE status = ?") { stmt in
                    bindText(stmt, 1, QueueStatus.preReg.wire)
                    let rc = sqlite3_step(stmt)
                    if rc != SQLITE_DONE {
                        throw SqliteError.step(rc: rc, message: lastErrorMessage())
                    }
                }
            }
            try exec("COMMIT")
        } catch {
            _ = try? exec("ROLLBACK")
            SwanLogger.error("SqliteQueueStore.drainPreRegistration: \(error)")
            return []
        }
        return out
    }

    func selectAll() -> [QueueRow] {
        lock.lock(); defer { lock.unlock() }
        var rows: [QueueRow] = []
        do {
            try prepare("""
            SELECT id, eventName, eventData, timestamp, priority, retryCount, status, createdAt, lastAttemptAt
            FROM EventQueue
            ORDER BY createdAt ASC
            """) { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    rows.append(readRow(stmt))
                }
            }
        } catch {
            SwanLogger.error("SqliteQueueStore.selectAll: \(error)")
        }
        return rows
    }

    func deleteAll() {
        lock.lock(); defer { lock.unlock() }
        _ = try? exec("DELETE FROM EventQueue")
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        if let db = db {
            sqlite3_close(db)
            self.db = nil
        }
    }

    // MARK: - SQLite helpers

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<Int8>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw SqliteError.exec(rc: rc, message: msg)
        }
    }

    private func prepare(_ sql: String, _ body: (OpaquePointer) throws -> Void) throws {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        if rc != SQLITE_OK || stmt == nil {
            let msg = lastErrorMessage()
            stmt.map { sqlite3_finalize($0) }
            throw SqliteError.prepare(rc: rc, message: msg)
        }
        defer { sqlite3_finalize(stmt) }
        try body(stmt!)
    }

    /// `SQLITE_TRANSIENT` — tells sqlite3 to make its own copy of the bound
    /// bytes. Constant is `(sqlite3_destructor_type)-1` in C; Swift can't
    /// directly cast `-1` to a function-pointer type, so we manufacture it
    /// via `unsafeBitCast` from an `Int`. Apple's SQLite ships the same
    /// macro layout.
    private static let SQLITE_TRANSIENT: sqlite3_destructor_type =
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func readText(_ stmt: OpaquePointer, _ pos: Int32) -> String {
        guard let cstr = sqlite3_column_text(stmt, pos) else { return "" }
        return String(cString: cstr)
    }

    private func bindText(_ stmt: OpaquePointer, _ pos: Int32, _ text: String) {
        // SQLITE_TRANSIENT — sqlite3 makes its own copy of the bytes; safe
        // even if the Swift String is deallocated before step().
        sqlite3_bind_text(stmt, pos, text, -1, SqliteQueueStore.SQLITE_TRANSIENT)
    }

    private func lastErrorMessage() -> String {
        guard let db = db else { return "(no db)" }
        return String(cString: sqlite3_errmsg(db))
    }

    private func readRow(_ stmt: OpaquePointer) -> QueueRow {
        // Columns 0..2, 6 are NOT NULL per schema — but sqlite3_column_text
        // still returns an Optional. Use the helper to keep call sites tidy.
        let id = readText(stmt, 0)
        let name = readText(stmt, 1)
        let data = readText(stmt, 2)
        let timestamp = sqlite3_column_int64(stmt, 3)
        let priority = Int(sqlite3_column_int(stmt, 4))
        let retryCount = Int(sqlite3_column_int(stmt, 5))
        let statusStr = readText(stmt, 6)
        let createdAt = sqlite3_column_int64(stmt, 7)
        let lastAttemptAt: Int64? = sqlite3_column_type(stmt, 8) == SQLITE_NULL
            ? nil
            : sqlite3_column_int64(stmt, 8)
        return QueueRow(
            id: id,
            eventName: name,
            eventDataJson: data,
            timestamp: timestamp,
            priority: priority,
            retryCount: retryCount,
            status: QueueStatus.fromWire(statusStr) ?? .pending,
            createdAt: createdAt,
            lastAttemptAt: lastAttemptAt
        )
    }

    private func updateMany(
        ids: [String],
        sql sqlPrefix: String,
        bindPrefix: (OpaquePointer) -> Void,
        firstIdParam: Int32
    ) {
        lock.lock(); defer { lock.unlock() }
        guard !ids.isEmpty else { return }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let sql = "\(sqlPrefix) (\(placeholders))"
        do {
            try prepare(sql) { stmt in
                bindPrefix(stmt)
                var idx: Int32 = firstIdParam
                for id in ids {
                    bindText(stmt, idx, id)
                    idx += 1
                }
                let rc = sqlite3_step(stmt)
                if rc != SQLITE_DONE {
                    throw SqliteError.step(rc: rc, message: lastErrorMessage())
                }
            }
        } catch {
            SwanLogger.error("SqliteQueueStore.updateMany: \(error)")
        }
    }
}

/// SQLite call failures. Surface them via ``SwanLogger`` rather than throwing
/// at the public API — losing a queue mutation is recoverable (we'll re-emit
/// at the next track call), but crashing the host app is not.
enum SqliteError: Error, CustomStringConvertible {
    case open(rc: Int32, message: String)
    case exec(rc: Int32, message: String)
    case prepare(rc: Int32, message: String)
    case step(rc: Int32, message: String)

    var description: String {
        switch self {
        case .open(let rc, let m): return "sqlite open failed (\(rc)): \(m)"
        case .exec(let rc, let m): return "sqlite exec failed (\(rc)): \(m)"
        case .prepare(let rc, let m): return "sqlite prepare failed (\(rc)): \(m)"
        case .step(let rc, let m): return "sqlite step failed (\(rc)): \(m)"
        }
    }
}
