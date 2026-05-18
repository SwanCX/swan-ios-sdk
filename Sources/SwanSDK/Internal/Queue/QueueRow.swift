import Foundation

/// One row in the persistent event queue.
///
/// **Capability:** `offline-queue` (Phase 1.8 iOS port).
///
/// Spec:
///   - `spec/behavior/queue.yaml`                            (state machine)
///   - `spec/wire/event-ingest.yaml`                         (BatchEvent shape stored in `eventDataJson`)
///   - `conformance/scenarios/offline-queue.feature`
///   - `conformance/scenarios/network-resilience.feature`
///   - `conformance/scenarios/force-flush.feature`
///
/// Mirror of Android's `QueueRow.kt`. Schema mirrors RN's `EventQueue` SQLite
/// table (`swan-react-native-sdk/src/core/EventQueueManager.ts:32-42`) verbatim
/// — same column names + same indexes — so tooling that inspects the on-disk
/// database (ADB pulls / Xcode container browser) sees the same table name +
/// columns regardless of platform.
///
/// ## iOS-vs-Android divergences (flagged)
///
///   - `eventDataJson` is the JSON-serialized form of EITHER a fully-enriched
///     ``BatchEvent`` (for `pending`/`sending`/`failed`), OR a
///     ``DurableEventQueue/PreRegPayload`` (status `pre_reg` only). The two
///     cases never mix within a row. Same as Android.
///
///   - `priority` is RN-defined `[0, 1]` and v1 only emits `0`. Kept for
///     schema parity. Same as Android.
///
///   - Times are `Int64` Unix milliseconds — matches Android's `Long` and
///     RN's `Date.now()`. Swift's `TimeInterval` (Double seconds) is NOT
///     used here; the wire is unambiguously ms-precision.
struct QueueRow: Equatable {

    /// Stable UUID for this row. Becomes `events[i].id` on the wire.
    let id: String

    /// Wire event name (e.g. `productViewed`, `PROFILE_ENRICH`,
    /// `SWAN_NOTIFICATION_ACK`). The flush path routes by this string —
    /// see `spec/behavior/queue.yaml#routing_by_eventName`.
    ///
    /// v1 of offline-queue routes `*` → `/v2/trackEvent` only; the push-
    /// subscription / push-ack / enrich-profile branches are owned by later
    /// ports.
    let eventName: String

    /// Serialized JSON. For `pending`/`sending`/`failed` rows this is the
    /// full ``BatchEvent`` (id, name, timestamp, data, userId, currentCDID,
    /// generatedCDID) — i.e. what gets shipped as one element of `events[]`
    /// on the next flush. For `pre_reg` rows this is the caller-supplied
    /// attributes only; enrichment happens at promotion time.
    let eventDataJson: String

    /// Unix ms — when `Swan.track` was called. Order-by column for FIFO drains.
    let timestamp: Int64

    /// 0 (normal) | 1 (high). v1 never emits 1. Kept for RN parity.
    let priority: Int

    /// Number of failed send attempts. 0 on enqueue.
    let retryCount: Int

    /// State-machine status. See ``QueueStatus``.
    let status: QueueStatus

    /// Unix ms — same as `timestamp` on first enqueue.
    let createdAt: Int64

    /// Unix ms — set each time the row is moved to `sending`. Nil until
    /// first attempt.
    let lastAttemptAt: Int64?

    init(
        id: String,
        eventName: String,
        eventDataJson: String,
        timestamp: Int64,
        priority: Int = 0,
        retryCount: Int = 0,
        status: QueueStatus,
        createdAt: Int64,
        lastAttemptAt: Int64? = nil
    ) {
        self.id = id
        self.eventName = eventName
        self.eventDataJson = eventDataJson
        self.timestamp = timestamp
        self.priority = priority
        self.retryCount = retryCount
        self.status = status
        self.createdAt = createdAt
        self.lastAttemptAt = lastAttemptAt
    }

    /// Functional update — returns a copy with the supplied fields changed.
    /// Swift's `struct` literal init doesn't give us Kotlin's `data class
    /// copy(...)` for free, so this helper keeps call sites readable.
    func copy(
        eventDataJson: String? = nil,
        retryCount: Int? = nil,
        status: QueueStatus? = nil,
        lastAttemptAt: Int64?? = nil
    ) -> QueueRow {
        return QueueRow(
            id: self.id,
            eventName: self.eventName,
            eventDataJson: eventDataJson ?? self.eventDataJson,
            timestamp: self.timestamp,
            priority: self.priority,
            retryCount: retryCount ?? self.retryCount,
            status: status ?? self.status,
            createdAt: self.createdAt,
            lastAttemptAt: lastAttemptAt ?? self.lastAttemptAt
        )
    }
}
