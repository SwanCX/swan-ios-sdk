import Foundation

/// Per-process configuration for event tracking — flush thresholds, retry
/// budget, and the host-app-supplied super-properties (country/currency/
/// businessUnit) that auto-enrich every event payload.
///
/// **Capabilities:** `custom-events`, `semantic-ecommerce-events`.
///
/// Spec: `spec/behavior/queue.yaml constants` for the flush knobs;
/// `spec/api/events.yaml` enriched-`data` description for the super-properties.
///
/// Defaults match RN's [`BatchConfig`](src/config/BatchConfig.ts). Strict
/// RN parity per `spec/scope-v1.md` — DO NOT deviate without a user
/// directive even when there's a plausible "we could optimize" argument.
/// Wire-format compatibility extends to flush triggers because customers'
/// delivery-rate expectations are tuned against RN's behavior.
///
/// Mirror of Android's `EventConfig.kt`. Held as a `struct` (value type)
/// so each ``EventTracker`` update copy-on-writes — saves a lock when
/// the config flips while a flush is mid-flight.
internal struct EventConfig: Equatable, Sendable {

    /// Number of events that triggers an automatic flush after enqueue.
    var batchSize: Int = Self.defaultBatchSize

    /// Periodic flush interval — every N seconds a flush fires regardless
    /// of size. Kept as `TimeInterval` (Swift idiom) instead of Android's
    /// `Long` milliseconds.
    var flushInterval: TimeInterval = Self.defaultFlushInterval

    /// Hard cap on the in-memory queue. Oldest events are dropped on overflow.
    /// (When the durable-queue port lands, this becomes the SQLite row cap.)
    var maxQueueSize: Int = Self.defaultMaxQueueSize

    /// Maximum send attempts per event before terminal `failed` state.
    /// `spec/behavior/queue.yaml constants.maxRetries = 3`.
    var maxRetries: Int = Self.defaultMaxRetries

    /// Base delay for exponential backoff: `base * 2^(retryCount-1)`.
    /// `spec/behavior/queue.yaml constants.retryBaseDelay_ms = 2000`.
    var retryBaseDelay: TimeInterval = Self.defaultRetryBaseDelay

    /// Number of days `failed` rows are kept before the periodic cleanup
    /// pass deletes them. `spec/behavior/queue.yaml constants.queueCleanupDays = 7`.
    /// Added with `offline-queue` capability.
    var queueCleanupDays: Int = Self.defaultQueueCleanupDays

    // MARK: - Super-properties (host-app supplied; empty by default per RN)
    var country: String = ""
    var currency: String = ""
    var businessUnit: String = ""

    /// Current screen name super-property.
    ///
    /// `screen-tracking` capability. Set via `Swan.setCurrentScreenName(name)`,
    /// cleared with the empty string. RN source: `currentScreenName` private
    /// field at src/index.tsx:230 + setter at :1466.
    ///
    /// Wire emission rule: emitted into event `data.currentScreenName` ONLY
    /// when non-empty — preserves byte-parity with RN for hosts that never
    /// set it (the field is absent in `event-ingest-batch.json`). Once set,
    /// every subsequent enqueued custom event carries the value, mirroring
    /// the country/currency/businessUnit super-properties.
    ///
    /// Note: RN itself does NOT auto-enrich events with `currentScreenName` —
    /// it only uses the field for in-app notification gating (`displayIn`).
    /// v1 native ports add the enrichment because the conformance scenario
    /// `screen-tracking.feature` "setCurrentScreenName updates the
    /// super-property" explicitly requires it. Backend tolerates unknown
    /// keys per `spec/wire/RN-PARITY.md` field-stability rules.
    var currentScreenName: String = ""

    // MARK: - Constants

    /// 10, per RN `BatchConfig` and `spec/behavior/queue.yaml constants.batchSize`.
    /// NOTE: NOT 25 — earlier iOS port deviation was caught and reverted.
    /// Wire-format byte parity REQUIRES this value to stay at 10.
    static let defaultBatchSize: Int = 10

    /// 30 s, per `spec/behavior/queue.yaml constants.flushInterval_ms`.
    static let defaultFlushInterval: TimeInterval = 30.0

    /// 5000, per `spec/behavior/queue.yaml constants.maxQueueSize`.
    static let defaultMaxQueueSize: Int = 5_000

    /// 3, per `spec/behavior/queue.yaml constants.maxRetries`.
    static let defaultMaxRetries: Int = 3

    /// 2 s, per `spec/behavior/queue.yaml constants.retryBaseDelay_ms`.
    static let defaultRetryBaseDelay: TimeInterval = 2.0

    /// 7 days, per `spec/behavior/queue.yaml constants.queueCleanupDays`.
    static let defaultQueueCleanupDays: Int = 7
}
