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
/// # Storage
///
/// `UserDefaults` via ``KeyValueStore``. One JSON-array entry under
/// ``Keys/pendingAcks``. Each entry captures the bare `commId` +
/// event + optional deeplink metadata. CDID, appId, deviceId are NOT
/// persisted — resolved at flush time from ``CredentialsStore``,
/// mirroring RN's "CDID resolved at flush time" invariant
/// (src/index.tsx:1822).
///
/// Concurrent access is serialized at the
/// ``NotificationAckService`` level (single mutex); this store is
/// intentionally simple read-modify-write.
///
/// # Cap
///
/// Hard cap at 1000 entries (FIFO drop). Pathological client offline-
/// spam scenarios shouldn't grow UserDefaults without bound. v1 doesn't
/// surface a config knob; if a host hits the cap it's a backend /
/// connectivity bug.
final class PendingAckStore {

    /// One persisted ACK entry.
    ///
    /// `id` is a stable UUID for dedup on successful flush — rows are
    /// removed by id, not by commId, so re-enqueuing the same commId
    /// (e.g. a retry of the same notification) doesn't have one write
    /// wipe the other.
    struct PendingAck: Equatable {
        let id: String
        let commId: String
        let event: AckEvent
        let type: String?
        let linkId: String?
        let enqueuedAtMs: Int64
    }

    private let store: KeyValueStore

    init(store: KeyValueStore) {
        self.store = store
    }

    /// Append one pending ACK. FIFO-drops the oldest entry past
    /// ``maxEntries``.
    func enqueue(_ entry: PendingAck) {
        var current = readAll()
        current.append(entry)
        while current.count > Self.maxEntries {
            current.removeFirst()
        }
        write(current)
    }

    /// Snapshot of all pending ACKs in FIFO insert order. Non-destructive.
    func snapshot() -> [PendingAck] {
        return readAll()
    }

    /// Drop the supplied ids in one write — invoked after a successful flush.
    func remove(ids: [String]) {
        if ids.isEmpty { return }
        let set = Set(ids)
        let remaining = readAll().filter { !set.contains($0.id) }
        write(remaining)
    }

    /// Wipe everything — test seam + `Swan.resetForTests()` hook.
    func clear() {
        store.putString(Keys.pendingAcks, nil)
    }

    private func readAll() -> [PendingAck] {
        guard let raw = store.getString(Keys.pendingAcks),
              let data = raw.data(using: .utf8) else {
            return []
        }
        do {
            guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                return []
            }
            var out: [PendingAck] = []
            out.reserveCapacity(array.count)
            for dict in array {
                guard
                    let id = dict["id"] as? String,
                    let commId = dict["commId"] as? String,
                    let eventRaw = dict["event"] as? String,
                    let event = AckEvent(rawValue: eventRaw)
                else { continue }
                let type = dict["type"] as? String
                let linkId = dict["linkId"] as? String
                let enqueuedAtMs: Int64
                if let n = dict["enqueuedAtMs"] as? NSNumber {
                    enqueuedAtMs = n.int64Value
                } else if let s = dict["enqueuedAtMs"] as? String, let v = Int64(s) {
                    enqueuedAtMs = v
                } else {
                    enqueuedAtMs = 0
                }
                out.append(PendingAck(
                    id: id, commId: commId, event: event,
                    type: type, linkId: linkId, enqueuedAtMs: enqueuedAtMs
                ))
            }
            return out
        } catch {
            // Corrupted blob — drop it. Better than persistent retry-loop
            // on a parse error.
            store.putString(Keys.pendingAcks, nil)
            return []
        }
    }

    private func write(_ entries: [PendingAck]) {
        if entries.isEmpty {
            store.putString(Keys.pendingAcks, nil)
            return
        }
        let array: [[String: Any]] = entries.map { e in
            var dict: [String: Any] = [
                "id": e.id,
                "commId": e.commId,
                "event": e.event.rawValue,
                "enqueuedAtMs": NSNumber(value: e.enqueuedAtMs),
            ]
            if let t = e.type { dict["type"] = t }
            if let l = e.linkId { dict["linkId"] = l }
            return dict
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: array, options: [])
            let raw = String(data: data, encoding: .utf8)
            store.putString(Keys.pendingAcks, raw)
        } catch {
            SwanLogger.warn("PendingAckStore.write: serialize failed: \(error.localizedDescription)")
        }
    }

    enum Keys {
        static let pendingAcks = "pendingAcks"
    }

    /// Soft cap. RN has no cap (relies on backend rate limits + queue
    /// drain). We add one to prevent UserDefaults bloat in pathological
    /// offline scenarios.
    static let maxEntries = 1000
}
