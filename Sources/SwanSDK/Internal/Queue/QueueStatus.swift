import Foundation

/// State machine for a queue row.
///
/// **Capability:** `offline-queue` (Phase 1.8 iOS port).
///
/// Spec: `spec/behavior/queue.yaml` `states`.
///
/// Mirror of Android's `QueueStatus` enum.
///
/// Transitions (driven by ``DurableEventQueue``):
///   - `preReg` → `pending`  on credentials available (promoted with enrichment).
///   - `pending` → `sending` on dequeue (atomic update).
///   - `sending` → deleted   on per-event success (row removed).
///   - `sending` → `pending` on per-event failure if retryCount+1 < maxRetries.
///   - `sending` → `failed`  on per-event failure if retryCount+1 >= maxRetries.
///   - `sending` → `pending` on stale recovery (>5min in sending — crash mid-flush).
///   - `failed`  → deleted   after `queueCleanupDays` (RN parity 7d).
///
/// `preReg` is the v1 pre-registration sentinel (mirrors Android's
/// addition over RN). The conformance scenarios only refer to
/// `pending`/`sending`/`failed`; `preReg` is an internal-only state that
/// doesn't surface in `getQueueSize()` (which counts ONLY `pending`, per
/// `conformance/scenarios/force-flush.feature` "getQueueSize counts only
/// pending events").
enum QueueStatus: String, Equatable {
    case preReg = "pre_reg"
    case pending = "pending"
    case sending = "sending"
    case failed = "failed"

    /// Returns the canonical on-wire string ("pending", "sending", "failed",
    /// "pre_reg"). Matches Android `QueueStatus.wire` so the on-disk SQLite
    /// schema is byte-identical across platforms.
    var wire: String { rawValue }

    /// Decode the on-disk wire string. Returns `nil` for unknown values so
    /// callers can either drop the row or fall back to `pending`.
    static func fromWire(_ value: String) -> QueueStatus? {
        return QueueStatus(rawValue: value)
    }
}
