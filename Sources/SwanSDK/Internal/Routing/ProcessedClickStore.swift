import Foundation

/// Thread-safe, time-bounded dedup set for notification messageIds.
///
/// **Capability:** `cold-start-routing`.
///
/// Mirrors RN's `processedClickIds` Set + `markClickProcessed`
/// (src/index.tsx:142-152) and Android's `ProcessedClickStore`.
///
/// The same notification tap on iOS can fire multiple handlers — the
/// background `UNUserNotificationCenterDelegate.userNotificationCenter(_:
/// didReceive:withCompletionHandler:)` path, an in-app cold-start launch
/// that re-extracts the userInfo from
/// `UIApplication.LaunchOptionsKey.remoteNotification`, and any
/// `NotificationServiceExtension` reflection. Without dedup, each handler
/// would emit its own NOTIFICATION_OPENED event + clicked ACK,
/// double-billing the campaign.
///
/// # Why per-router instance (not singleton)
///
/// Owned by ``NotificationRouter`` so SDK re-init / ``Swan/resetForTests``
/// fully drains the dedup state. A singleton would leak ids across tests
/// and across host-app SDK lifecycles — same bug RN dodges by virtue of
/// its module-scope `Set` being reset on JS bundle reload.
///
/// # TTL semantics
///
/// 30 seconds, matching RN. Tied to the wall clock
/// (`Date().timeIntervalSince1970 * 1000` by default; injectable for
/// tests). Eviction is LAZY — entries are checked on every
/// ``markProcessed(_:)`` call, so a process that hibernates past the TTL
/// boundary observes the correct un-processed pool on wake. RN uses
/// `setTimeout` which keeps a JS timer alive; on iOS, eager eviction
/// would burn a `Timer` for what is effectively disposable state.
/// (Per the iOS implementer brief: NO `Timer`s — lazy check on each call.)
///
/// # Blank / empty id semantics
///
/// Mirrors RN's `messageId &&` guard at every call-site (src/index.tsx:983,
/// :2299, :3669, :3758, :4821, :4912, :5027) — empty / blank ids are
/// never recorded, and ``markProcessed(_:)`` always returns `true` for
/// them. This prevents a single rogue un-keyed push from blocking dedup
/// for other un-keyed pushes downstream.
internal final class ProcessedClickStore: @unchecked Sendable {

    /// RN parity: src/index.tsx:143 `CLICK_ID_TTL_MS = 30_000`.
    static let ttlMs: Int64 = 30_000

    private let lock = NSLock()
    /// id → expiryTimestampMs (wall clock).
    private var entries: [String: Int64] = [:]
    private let timeProvider: () -> Int64
    private let ttl: Int64

    init(
        timeProvider: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
        ttlMs: Int64 = ProcessedClickStore.ttlMs
    ) {
        self.timeProvider = timeProvider
        self.ttl = ttlMs
    }

    /// Returns `true` on the first call for `id` within the TTL window,
    /// `false` on every subsequent call for the same id until expiry.
    ///
    /// Empty / blank ids always return `true` and are NEVER recorded —
    /// mirrors RN's `messageId &&` guard pattern at every call-site.
    ///
    /// Thread-safe — concurrent calls for the same id from multiple
    /// threads produce exactly one `true` return. Serialized via a plain
    /// `NSLock` (Android's `ConcurrentHashMap.compute` doesn't have a
    /// direct Swift equivalent; the lock is cheap for the call rate of
    /// notification taps).
    func markProcessed(_ id: String) -> Bool {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        let now = timeProvider()
        lock.lock()
        defer { lock.unlock() }
        evictExpired(now: now)
        // Look up + store via TRIMMED id, not raw — the same messageId
        // arriving via two different paths (e.g. cold-start launchOptions
        // vs didReceive(response:), or simctl-push vs APNs) sometimes
        // carries trailing whitespace from one path but not the other.
        // Looking up via raw `id` bypassed dedup on whitespace mismatch.
        // Caught 2026-05-18 — Bug 12 in the senior-engineer audit.
        if let exp = entries[trimmed], exp > now {
            return false
        }
        entries[trimmed] = now + ttl
        return true
    }

    /// Total number of un-expired entries, with lazy eviction.
    func size() -> Int {
        lock.lock()
        defer { lock.unlock() }
        evictExpired(now: timeProvider())
        return entries.count
    }

    /// Drop every entry — used by test seams + SDK reset.
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
    }

    private func evictExpired(now: Int64) {
        // Filter in place. `entries` is small (capped by traffic in a
        // 30s window); the cost is dominated by the lock acquisition.
        entries = entries.filter { $0.value > now }
    }
}
