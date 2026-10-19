import Foundation

/// Durable retry queue for ACKs that failed direct POST.
///
/// **Capability:** `delivery-click-ack` (Phase 1.16 port).
///
/// # Why a dedicated store (and not the DurableEventQueue)
///
/// iOS doesn't ship a durable-event-queue yet (Android's
/// offline-queue port). Even when it lands, routing ACKs through it
/// would require widening the row schema — ACKs hit a different
/// endpoint with a different body. Mirror Android's posture: each
/// non-standard routing branch gets its own service. See Android
/// `PendingAckStore.kt` kdoc.
///
/// # Storage — one key PER ENTRY (SWA-9468)
///
/// `UserDefaults` via ``KeyValueStore``. Each entry is its own key,
/// ``Keys/entryPrefix`` + the entry's `id`, holding a small JSON object.
/// Each entry captures the bare `commId` + event + optional deeplink
/// metadata + the optional carousel `itemIndex`. CDID, appId, deviceId are NOT persisted — resolved at flush
/// time from ``CredentialsStore``, mirroring RN's "CDID resolved at flush
/// time" invariant (src/index.tsx:1822).
///
/// ## Why per-key and not one JSON array
///
/// This store became **cross-process** in SWA-9468: the iOS Notification
/// Service Extension write-ahead-enqueues cold-start ACKs into the App
/// Group suite, and the host app drains the same suite from a different
/// process. The original single-blob layout was read-modify-write
/// (`readAll` → mutate → `write(all)`), which two processes cannot do
/// safely — there is no cross-process lock, and `flushMutex` only
/// serializes within one process. Interleaved, a blob layout can:
///
///   - **lose** an entry — NSE reads `[A]`, host removes A and writes
///     `[]`, NSE writes `[A,B]`… then the host's next write clobbers B;
///   - **resurrect** a removed entry — the loser's stale snapshot is
///     written back over the winner's deletion.
///
/// Losing an entry is exactly the data loss SWA-9468 exists to prevent,
/// so the blob is gone. With one key per entry, a write only ever touches
/// its OWN key: concurrent `enqueue`s cannot overwrite each other, and an
/// `enqueue` racing a `remove` of a DIFFERENT id cannot interfere at all.
/// No index key is kept either — an index would itself be a shared blob
/// and would reintroduce the race — so enumeration goes through
/// ``KeyValueStore/keys(withPrefix:)``.
///
/// Residual, deliberately accepted: `enqueue` and `remove` of the SAME id
/// racing across processes is last-writer-wins on that one key, which can
/// resurrect a single entry that was just flushed. That costs one
/// duplicate ACK (the backend dedups by `commId`), never a lost one.
///
/// # Ordering
///
/// Insertion order is not recoverable from a key-space scan, so
/// ``snapshot()`` sorts by `enqueuedAtMs`, with `id` as a tie-break so the
/// order is total and deterministic rather than dependent on dictionary
/// iteration. FIFO in practice; exact ordering among ACKs enqueued in the
/// same millisecond carries no meaning.
///
/// # Retention — size cap AND age bound
///
/// Two independent bounds, both enforced on read/enqueue:
///
///   - **Size:** hard cap at 1000 entries, evicting oldest-first by
///     `enqueuedAtMs`. Pathological client offline-spam scenarios shouldn't
///     grow UserDefaults without bound. v1 doesn't surface a config knob; if
///     a host hits the cap it's a backend / connectivity bug.
///   - **Age:** entries older than ``maxAgeMs`` (7 days) are dropped, as are
///     entries dated in the FUTURE. Matches RN's
///     `MAX_PENDING_ACK_AGE_MS` (react-native/src/core/PendingAckStore.ts).
///     Without it a permanently-unsendable entry — no credentials at flush
///     time, a revoked `ackUrl` — replays on every flush forever, since ACK
///     retry has no per-entry attempt counter. SWA-9468 made that sharper:
///     the cold-start path write-ahead-persists entries the device may never
///     succeed in sending. A week-old delivery receipt has no analytical
///     value anyway.
///
/// The future-dated check matters because `enqueuedAtMs` comes from wall
/// clock: a device with a badly-skewed clock (or one the user manually set
/// forward and back) can persist a timestamp that would otherwise read as
/// "not yet expired" for years. Any negative age is treated as corrupt.
///
/// **Undatable rows are DROPPED, deliberately.** A missing or unparseable
/// `enqueuedAtMs` decodes to `0`, so its age is measured from the epoch —
/// decades, hence far over the bound, hence reaped. Note the reap follows
/// from real wall-clock time being far past epoch 0, which holds in
/// production but NOT under a test clock pinned near 0: such a row has a
/// small age there and legitimately survives. That is the injected clock
/// behaving correctly, not a hole. This outcome matches Android and RN.
/// Do NOT add a "keep rows we cannot date" branch here: a row
/// that can never be age-judged can never be reaped, which is precisely the
/// replay-forever hole this bound exists to close. Not failing the whole
/// parse on a missing field is a SEPARATE concern, already handled by
/// defaulting to `0` instead of throwing — keeping the row is not required to
/// get that, and Android carried exactly that conflation briefly before it
/// was removed.
final class PendingAckStore {

    /// One persisted ACK entry.
    ///
    /// `id` is a stable UUID for dedup on successful flush — rows are
    /// removed by id, not by commId, so re-enqueuing the same commId
    /// (e.g. a retry of the same notification) doesn't have one write
    /// wipe the other. Since SWA-9468 the `id` is also the storage key
    /// suffix, which is what makes writes mutually non-conflicting.
    struct PendingAck: Equatable {
        let id: String
        let commId: String
        let event: AckEvent
        let type: String?
        let linkId: String?
        let enqueuedAtMs: Int64
        /// 0-based `carouselItems` position of the tapped card on a carousel
        /// `clicked` ACK, so a replay still names the card. Entries written
        /// before this field existed decode as `nil` (no card).
        var itemIndex: Int?
    }

    private let store: KeyValueStore
    private let clock: () -> Int64

    /// - Parameters:
    ///   - store: backing key-value store.
    ///   - clock: wall-clock in epoch-ms, used only for the age bound.
    ///     Injectable so tests can pin "now"; production takes the default.
    init(
        store: KeyValueStore,
        clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.store = store
        self.clock = clock
    }

    /// Append one pending ACK. Evicts oldest-first past ``maxEntries``, and
    /// prunes anything outside the age bound.
    func enqueue(_ entry: PendingAck) {
        migrateLegacyBlobIfNeeded()
        writeEntry(entry)
        enforceCap()
    }

    /// Snapshot of all pending ACKs, oldest first.
    ///
    /// Not purely a read: entries outside the age bound (and unreadable ones)
    /// are DELETED as they're encountered, so a poison entry is gone after the
    /// first flush that sees it rather than being filtered out of the result
    /// on every future one.
    func snapshot() -> [PendingAck] {
        migrateLegacyBlobIfNeeded()
        return readAll()
    }

    /// Drop the supplied ids — invoked after a successful flush. Each id is
    /// an independent key delete, so this cannot disturb an entry another
    /// process is concurrently enqueuing.
    func remove(ids: [String]) {
        if ids.isEmpty { return }
        migrateLegacyBlobIfNeeded()
        for id in ids {
            store.putString(Keys.entryKey(id), nil)
        }
    }

    /// Wipe everything — test seam + `Swan.resetForTests()` hook.
    ///
    /// Deletes only this store's own keys. It deliberately does NOT call
    /// ``KeyValueStore/clear()``: the cold-start queue shares the App Group
    /// suite with ``CredentialsStore``, so a blanket wipe here would take
    /// the device's credentials with it.
    func clear() {
        for key in store.keys(withPrefix: Keys.entryPrefix) {
            store.putString(key, nil)
        }
        store.putString(Keys.pendingAcks, nil)
    }

    // MARK: - Internals

    private func readAll() -> [PendingAck] {
        var out: [PendingAck] = []
        let now = clock()
        for key in store.keys(withPrefix: Keys.entryPrefix) {
            guard let raw = store.getString(key) else { continue }
            guard let entry = decode(raw) else {
                // Corrupt single entry — drop just that key. Blast radius is
                // one ACK; the rest of the queue still flushes.
                SwanLogger.warn("PendingAckStore: dropping unreadable entry at \(key).")
                store.putString(key, nil)
                continue
            }
            // Age bound. Deleted here, in the same pass, rather than merely
            // filtered — otherwise a poison entry stays on disk forever and is
            // re-decoded on every flush.
            let age = now - entry.enqueuedAtMs
            if age < 0 || age > Self.maxAgeMs {
                SwanLogger.debug(
                    "PendingAckStore: dropping \(age < 0 ? "future-dated" : "expired") ACK " +
                    "commId=\(entry.commId) age=\(age)ms."
                )
                store.putString(key, nil)
                continue
            }
            out.append(entry)
        }
        out.sort { lhs, rhs in
            if lhs.enqueuedAtMs != rhs.enqueuedAtMs {
                return lhs.enqueuedAtMs < rhs.enqueuedAtMs
            }
            return lhs.id < rhs.id
        }
        return out
    }

    private func writeEntry(_ entry: PendingAck) {
        var dict: [String: Any] = [
            "id": entry.id,
            "commId": entry.commId,
            "event": entry.event.rawValue,
            "enqueuedAtMs": NSNumber(value: entry.enqueuedAtMs),
        ]
        if let type = entry.type { dict["type"] = type }
        if let linkId = entry.linkId { dict["linkId"] = linkId }
        if let itemIndex = entry.itemIndex { dict["itemIndex"] = NSNumber(value: itemIndex) }
        do {
            let data = try JSONSerialization.data(withJSONObject: dict, options: [])
            store.putString(Keys.entryKey(entry.id), String(data: data, encoding: .utf8))
        } catch {
            SwanLogger.warn("PendingAckStore.writeEntry: serialize failed: \(error.localizedDescription)")
        }
    }

    private func decode(_ raw: String) -> PendingAck? {
        guard let data = raw.data(using: .utf8) else { return nil }
        guard
            let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let id = dict["id"] as? String,
            let commId = dict["commId"] as? String,
            let eventRaw = dict["event"] as? String,
            let event = AckEvent(rawValue: eventRaw)
        else {
            return nil
        }
        let enqueuedAtMs: Int64
        if let number = dict["enqueuedAtMs"] as? NSNumber {
            enqueuedAtMs = number.int64Value
        } else if let str = dict["enqueuedAtMs"] as? String, let parsed = Int64(str) {
            enqueuedAtMs = parsed
        } else {
            enqueuedAtMs = 0
        }
        return PendingAck(
            id: id, commId: commId, event: event,
            type: dict["type"] as? String,
            linkId: dict["linkId"] as? String,
            enqueuedAtMs: enqueuedAtMs,
            itemIndex: CarouselItemIndex.normalize(dict["itemIndex"])
        )
    }

    /// Evict oldest-first once the queue exceeds ``maxEntries``.
    ///
    /// Counts keys before decoding: the over-cap path is pathological, so the
    /// common case pays only a key scan.
    private func enforceCap() {
        let keys = store.keys(withPrefix: Keys.entryPrefix)
        if keys.count <= Self.maxEntries { return }
        let all = readAll()
        guard all.count > Self.maxEntries else { return }
        for entry in all.prefix(all.count - Self.maxEntries) {
            store.putString(Keys.entryKey(entry.id), nil)
        }
    }

    /// One-time upgrade from the pre-SWA-9468 single-JSON-array blob.
    ///
    /// Folds each blob entry into its own key, then deletes the blob, so a
    /// device that upgrades with ACKs already queued doesn't orphan them. A
    /// corrupt blob is dropped outright — better than a permanent retry loop
    /// on a parse error, and matches the pre-SWA-9468 behaviour.
    ///
    /// Idempotent and safe to race: two processes migrating at once write
    /// byte-identical values to the same per-entry keys, then both delete the
    /// blob. The one narrow cost is a process still holding a pre-deletion
    /// read of the blob re-writing an entry the other process just flushed —
    /// one duplicate ACK, once, during the upgrade window only.
    private func migrateLegacyBlobIfNeeded() {
        guard let raw = store.getString(Keys.pendingAcks) else { return }
        defer { store.putString(Keys.pendingAcks, nil) }
        guard
            let data = raw.data(using: .utf8),
            let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        else {
            SwanLogger.warn("PendingAckStore: legacy blob unreadable; dropping it.")
            return
        }
        var migrated = 0
        for dict in array {
            guard
                let entryData = try? JSONSerialization.data(withJSONObject: dict, options: []),
                let entryRaw = String(data: entryData, encoding: .utf8),
                let entry = decode(entryRaw)
            else { continue }
            writeEntry(entry)
            migrated += 1
        }
        if migrated > 0 {
            SwanLogger.debug("PendingAckStore: migrated \(migrated) ACK(s) from the legacy blob to per-key storage.")
        }
    }

    enum Keys {
        /// Pre-SWA-9468 single-blob key. Read once by the migration, then
        /// deleted; never written again.
        static let pendingAcks = "pendingAcks"

        /// Namespace for per-entry keys. The trailing dot keeps it from
        /// prefix-matching the legacy ``pendingAcks`` key.
        /// MUST stay in sync with `UserDefaultsKeyValueStore.knownSwanKeyPrefixes`.
        static let entryPrefix = "pendingAck."

        static func entryKey(_ id: String) -> String { entryPrefix + id }
    }

    /// Soft cap. RN has no cap (relies on backend rate limits + queue
    /// drain). We add one to prevent UserDefaults bloat in pathological
    /// offline scenarios.
    static let maxEntries = 1000

    /// Age bound — entries older than this (or dated in the future) are
    /// dropped on read. 7 days, matching RN's `MAX_PENDING_ACK_AGE_MS`
    /// (react-native/src/core/PendingAckStore.ts).
    static let maxAgeMs: Int64 = 7 * 24 * 60 * 60 * 1000
}
