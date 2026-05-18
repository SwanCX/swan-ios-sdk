import Foundation

/// Lightweight session-id provider — a UUID that rolls over after 20 minutes
/// of inactivity.
///
/// **Capabilities:** `custom-events` (stamps `data.sessionId`),
/// `semantic-ecommerce-events`.
///
/// Mirrors RN's `getSessionId()` (src/index.tsx:2083) but persists state via
/// [KeyValueStore] instead of `AsyncStorage` + base64. RN base64-wraps a JSON
/// blob `{ sessionId, lastActiveTime }`; native ports break it into two
/// plain string keys per `spec/wire/RN-PARITY.md` field-stability rules —
/// persistence is per-platform, only the wire is the contract.
///
/// Spec: `spec/api/events.yaml` (`data.sessionId` is one of the auto-enriched
/// fields).
///
/// **Scope for this port (custom-events):** ONLY exposes ``getId()``. The
/// `session-tracking` capability port will wire foreground/background
/// lifecycle observers (UIApplication notifications) when it lands; for now
/// inactivity is the sole rollover trigger and aligns with RN's behavior.
internal final class SessionManager {

    /// Per `spec/api/events.yaml` data.sessionId + RN's `20 * 60 * 1000`.
    static let sessionTimeout: TimeInterval = 20 * 60

    /// Persistence keys — internal only. Distinct from RN's
    /// `_swanSessionId` blob key because we store fields separately.
    static let keySessionId = "swanSessionId"
    static let keyLastActiveTime = "swanSessionLastActiveTime"

    private let store: KeyValueStore
    private let clock: @Sendable () -> Date
    private let idGenerator: @Sendable () -> String
    private let sessionTimeout: TimeInterval
    private let lock = NSLock()

    init(
        store: KeyValueStore,
        clock: @escaping @Sendable () -> Date = { Date() },
        idGenerator: @escaping @Sendable () -> String = { UUID().uuidString },
        sessionTimeout: TimeInterval = SessionManager.sessionTimeout
    ) {
        self.store = store
        self.clock = clock
        self.idGenerator = idGenerator
        self.sessionTimeout = sessionTimeout
    }

    /// Returns the current session id, refreshing `lastActiveTime` on every
    /// call. Idempotent within a 20-minute window; a 20-min idle gap mints
    /// a fresh UUID.
    func getId() -> String {
        lock.lock()
        defer { lock.unlock() }

        let now = clock()
        let existing = store.getString(Self.keySessionId)
        let lastActive: Date? = {
            guard let raw = store.getString(Self.keyLastActiveTime),
                  let ms = Double(raw) else { return nil }
            return Date(timeIntervalSince1970: ms / 1000.0)
        }()

        if let id = existing,
           let last = lastActive,
           now.timeIntervalSince(last) < sessionTimeout {
            // Session still valid — bump lastActiveTime + return it.
            store.putString(Self.keyLastActiveTime, msString(now))
            return id
        }

        let fresh = idGenerator()
        store.putString(Self.keySessionId, fresh)
        store.putString(Self.keyLastActiveTime, msString(now))
        return fresh
    }

    /// Returns the current session id WITHOUT refreshing `lastActiveTime`.
    /// Used by ``EventEnrichment`` so that a fast burst of events inside
    /// a single `track()` call doesn't end up with each event nudging the
    /// inactivity slider mid-batch — caller (``EventTracker``) refreshes
    /// once per enqueue via ``getId()``.
    func peekId() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return store.getString(Self.keySessionId)
    }

    private func msString(_ date: Date) -> String {
        return String(Int64(date.timeIntervalSince1970 * 1000))
    }
}
