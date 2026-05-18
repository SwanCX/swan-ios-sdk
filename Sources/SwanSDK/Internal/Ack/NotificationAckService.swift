import Foundation

/// Orchestrates the three ACK transports for `delivery-click-ack`.
///
/// **Capability:** `delivery-click-ack` (Phase 1.16 port).
///
/// Spec:
///   - `spec/api/push.yaml#sendNotificationAck`
///   - `spec/wire/notification-ack.yaml`
///   - `spec/behavior/notification-ack.yaml`
///   - `conformance/scenarios/delivery-click-ack.feature`
///
/// # Transports
///
/// 1. **Direct warm-start** — ``sendDelivered(_:)`` / ``sendClicked(_:type:linkId:)``.
///    SDK is initialized and creds are loaded; fire the POST asynchronously.
///    Mirrors RN's queue-flushed transport when the queue drains
///    immediately (src/index.tsx:1814).
///
/// 2. **Queued retry** — failed direct POSTs persist via ``PendingAckStore``
///    and replay on ``flushPending()``. Re-fires the same plain-JSON shape;
///    backend cannot tell the transport apart.
///
/// 3. **Cold-start direct** — ``ColdStartAckSender/send(...)``. Used when
///    `Swan.shared.initialize(...)` hasn't been called yet (NSE / cold-start
///    background notification). Reads creds straight from UserDefaults and
///    POSTs without the SDK bootstrap. Mirrors RN's
///    `sendDirectNotificationAck` (src/index.tsx:5109) and the iOS NSE
///    path (NotificationService.swift:97). NOT owned by this class —
///    documented here for the contract.
///
/// # RN parity
///
/// - `commId` ≡ FCM/APNs messageId for push ACKs.
/// - CDID resolved at SEND time: `currentCDID ?? generatedCDID`. RN
///   does this at flush time (src/index.tsx:1822); we do it identically
///   when each transport runs.
/// - Failed direct POSTs go into the retry queue. RN re-uses the
///   DurableEventQueue for the same purpose.
/// - Dedup is the router's responsibility (the 30s `markClickProcessed`
///   window). This service trusts the caller: every call becomes one
///   POST. The A19 router enforces dedup before invoking us.
///
/// # Thread-safety
///
/// ``flushPending()`` is serialized via the ``flushMutex`` actor — a
/// network-up event during a flush in progress can't double-drain.
/// Per-call ``sendDelivered(_:)`` / ``sendClicked(_:type:linkId:)`` are
/// stateless and reentrant; multiple in-flight POSTs are fine.
final class NotificationAckService {

    private let appId: String
    private let credentialsStore: CredentialsStore
    private let transport: DirectAckTransport
    private let pendingStore: PendingAckStore
    private let idGenerator: () -> String
    private let clock: () -> Int64

    /// Serializes concurrent flushPending calls. Using an actor since we
    /// have async-context already; an NSLock would also work but actor
    /// is the idiomatic Swift seam.
    private let flushMutex = AsyncMutex()

    init(
        appId: String,
        credentialsStore: CredentialsStore,
        transport: DirectAckTransport,
        pendingStore: PendingAckStore,
        idGenerator: @escaping () -> String = { UUID().uuidString },
        clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.appId = appId
        self.credentialsStore = credentialsStore
        self.transport = transport
        self.pendingStore = pendingStore
        self.idGenerator = idGenerator
        self.clock = clock
    }

    /// Fire a "delivered" ACK for a push.
    ///
    /// - Returns: `true` if the ACK was scheduled (POSTed or queued for
    ///   retry); `false` if credentials are missing (caller should fall
    ///   through to ``ColdStartAckSender``) or messageId is blank.
    @discardableResult
    func sendDelivered(_ messageId: String) -> Bool {
        return sendInternal(messageId: messageId, event: .delivered, type: nil, linkId: nil)
    }

    /// Fire a "clicked" ACK for a push.
    ///
    /// - Parameters:
    ///   - messageId: FCM/APNs messageId → wire `commId`.
    ///   - type: optional — set to `"deepLink"` for deep-link clicks.
    ///   - linkId: optional — the `swan_link_id` URL param.
    @discardableResult
    func sendClicked(_ messageId: String, type: String? = nil, linkId: String? = nil) -> Bool {
        return sendInternal(messageId: messageId, event: .clicked, type: type, linkId: linkId)
    }

    /// Drain the retry queue. Each entry POSTed independently; failures
    /// stay queued. Single-flight via ``flushMutex``.
    ///
    /// Called by ``Swan/initialize(appId:baseUrl:config:)`` on
    /// credentials-available. Idempotent.
    func flushPending() async {
        await flushMutex.withLock { [self] in
            guard let creds = credentialsStore.read() else {
                SwanLogger.debug("flushPending: no credentials yet; deferring.")
                return
            }
            let pending = pendingStore.snapshot()
            if pending.isEmpty { return }
            SwanLogger.debug("flushPending: draining \(pending.count) queued ACK(s).")
            var sent: [String] = []
            sent.reserveCapacity(pending.count)
            for entry in pending {
                let payload = AckPayload(
                    commId: entry.commId,
                    appId: appId,
                    CDID: creds.currentCDID ?? creds.generatedCDID,
                    event: entry.event,
                    deviceId: creds.deviceId,
                    type: entry.type,
                    linkId: entry.linkId
                )
                let ok = await transport.post(payload)
                if ok { sent.append(entry.id) }
                // No early-exit: transient 5xx on one row shouldn't
                // block the rest. FIFO order preserved by the persisted
                // queue.
            }
            if !sent.isEmpty { pendingStore.remove(ids: sent) }
        }
    }

    /// Number of ACKs currently waiting in the retry queue.
    func pendingCount() -> Int {
        return pendingStore.snapshot().count
    }

    /// Wipes the retry queue. Test seam + `Swan.resetForTests()` hook.
    func clear() {
        pendingStore.clear()
    }

    /// Synchronous variant of [sendInternal] used by tests + the
    /// background-task-only path inside `Swan.shared.ackPushDelivered(_:)`.
    /// Returns the same bool as the fire-and-forget version — `true` if
    /// scheduling succeeded, `false` if creds were missing.
    @discardableResult
    func sendInternalForTests(
        messageId: String,
        event: AckEvent,
        type: String? = nil,
        linkId: String? = nil
    ) async -> Bool {
        return await sendBlocking(
            messageId: messageId,
            event: event,
            type: type,
            linkId: linkId
        )
    }

    private func sendInternal(
        messageId: String,
        event: AckEvent,
        type: String?,
        linkId: String?
    ) -> Bool {
        if messageId.isEmpty {
            SwanLogger.warn("NotificationAckService: blank messageId for \(event); dropping.")
            return false
        }
        guard credentialsStore.read() != nil else {
            // No creds yet → host should fall back to ColdStartAckSender.
            // Don't enqueue here (the queue's flushPending() also needs
            // creds for CDID resolution; persisting now would just defer
            // the same problem).
            SwanLogger.debug("NotificationAckService: no credentials; caller should use cold-start path.")
            return false
        }
        SwanLogger.info("[SwanSDK] Notification ACK queued: \(messageId) \(event.rawValue)")
        // Fire-and-forget background task. Returns immediately; the POST
        // runs on the SDK's Task scope.
        Task.detached(priority: .utility) { [weak self] in
            _ = await self?.sendBlocking(messageId: messageId, event: event, type: type, linkId: linkId)
        }
        return true
    }

    /// Awaitable variant — the actual transport call + retry-queue
    /// fallback. Both the fire-and-forget public API and tests call into
    /// this.
    private func sendBlocking(
        messageId: String,
        event: AckEvent,
        type: String?,
        linkId: String?
    ) async -> Bool {
        guard let creds = credentialsStore.read() else {
            return false
        }
        let payload = AckPayload(
            commId: messageId,
            appId: appId,
            CDID: creds.currentCDID ?? creds.generatedCDID,
            event: event,
            deviceId: creds.deviceId,
            type: type,
            linkId: linkId
        )
        let ok = await transport.post(payload)
        if !ok {
            pendingStore.enqueue(
                PendingAckStore.PendingAck(
                    id: idGenerator(),
                    commId: messageId,
                    event: event,
                    type: type,
                    linkId: linkId,
                    enqueuedAtMs: clock()
                )
            )
        }
        return ok
    }
}
