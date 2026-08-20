import Foundation

/// Cold-start direct-ACK sender — the third transport.
///
/// **Capability:** `delivery-click-ack` (Phase 1.16 port).
///
/// Spec:
///   - `spec/behavior/notification-ack.yaml#direct_ack_path`
///   - `spec/wire/notification-ack.yaml` — same plain-JSON shape as
///     the other two transports.
///
/// # When to use
///
/// iOS hosts that fire delivery / click ACKs from a Notification Service
/// Extension (NSE) or from a cold-start path where the SDK hasn't been
/// initialized yet (e.g. the app was force-killed and the push arrived
/// to the NSE process). Equivalent to RN's
/// `sendDirectNotificationAck` (src/index.tsx:5109) and the existing
/// RN iOS NSE `NotificationService.swift:97` path.
///
/// # Contract
///
/// - Reads ``CredentialsStore`` directly from UserDefaults. If no
///   credentials are persisted yet (first-ever launch) this is a no-op
///   — matches RN at src/index.tsx:5124-5127.
/// - Reads ``SwanCredentials/ackUrl`` for the env-resolved webhook URL.
///   If `ackUrl` is missing (creds saved before delivery-click-ack
///   shipped), the call no-ops. Host apps that initialize the SDK at
///   least once will land an `ackUrl` for subsequent cold starts.
/// - Asynchronous URLSession POST. NSE has ~30s budget to do its work
///   so we don't impose extra latency here; the caller awaits.
/// - Best-effort: every error is swallowed (logged only). RN parity at
///   src/index.tsx:5190-5200.
/// - **Durable (SWA-9468):** the ACK is write-ahead-persisted to a
///   ``PendingAckStore`` BEFORE the POST and removed on a 2xx. A device
///   briefly offline at push arrival — the dominant killed-app / NSE
///   case — therefore no longer loses the receipt: the entry stays
///   queued and the next warm start replays it. Mirrors RN's durable
///   `sendDirectNotificationAck` + `flushPendingAcks` (src/index.tsx)
///   and Android's `ColdStartAckSender` write-ahead.
///
/// # Cross-process store placement
///
/// Unlike Android — where the cold-start path runs inside the app's own
/// process and can share the warm-start prefs file directly — the iOS
/// NSE is a **separate process**. It can only share state with the host
/// app through the App Group suite. The warm-start queue lives on the
/// app-private `swanPendingAcks` suite, which the NSE cannot see, so the
/// cold-start queue is backed by the **App-Group** suite instead
/// (``CredentialsStore/suiteName(forAppGroup:)`` — the same suite that
/// already carries credentials cross-process). Both stores use the
/// ``PendingAckStore/Keys/entryPrefix`` namespace inside their own suite,
/// so they never collide.
///
/// REQUIREMENT: `Swan.initialize` must keep passing a store on this suite to
/// ``NotificationAckService`` as its `coldStartStore`, because that is the
/// only thing that drains what this process persists. If that wiring is
/// dropped, nothing fails loudly: the NSE keeps queueing ACKs into the App
/// Group and the host app simply never reads them, so delivery receipts
/// strand silently and the durability this file exists for is gone. The suite
/// choice is now the single source of truth in
/// ``Swan/ackColdStartSuiteName(forAppGroup:)`` and pinned by
/// `SwanColdStartSuiteTests` (it must resolve to the App-Group suite and never
/// the app-private warm-queue suite), so rewiring it onto the wrong suite fails
/// a test rather than stranding receipts silently.
///
/// Because the NSE and the host app write this queue from two processes
/// with no lock between them, ``PendingAckStore`` persists one key per
/// entry rather than a single JSON blob — a blob would be
/// read-modify-written and could silently drop the very ACK this fix
/// exists to keep. See that type's docs for the full argument.
///
/// One consequence of sharing the credentials suite: a credential wipe
/// (`CredentialsStore.clear()`, i.e. logout) also drops queued cold-start
/// ACKs, because the `pendingAck.` namespace is in the Swan-owned prefix
/// allowlist. That is the desired behaviour — a queued receipt can only be
/// flushed against the CDID that was current when the push arrived, and
/// after a logout that CDID is gone.
///
/// # Modeled as a `enum` (Swift singleton)
///
/// Mirrors Android's `object ColdStartAckSender` (Kotlin singleton). The
/// function is intentionally pure (no SDK state) so NSE / unit tests can
/// call it standalone.
enum ColdStartAckSender {

    /// POST a delivered/clicked ACK directly. No SDK init required.
    ///
    /// - Parameters:
    ///   - messageId: FCM/APNs messageId → wire `commId`.
    ///   - event: ``AckEvent/delivered`` or ``AckEvent/clicked``.
    ///   - credentialsStore: source of truth for appId / deviceId / CDID
    ///     / ackUrl. Production callers construct with the same
    ///     UserDefaults suite the SDK uses
    ///     (``CredentialsStore/suiteName``).
    ///   - transport: production callers leave as default (URLSession);
    ///     tests inject a fake.
    ///   - pendingStore: durable write-ahead queue. Production callers
    ///     pass a store backed by the App-Group suite so the host app's
    ///     ``NotificationAckService/flushPending()`` can drain what this
    ///     (possibly NSE) process persisted. `nil` restores the legacy
    ///     fire-and-forget behaviour (tests / callers with no App Group).
    ///   - idGenerator: id for the write-ahead row; also its storage key
    ///     suffix. Tests pin it to assert on a specific entry.
    ///   - clock: stamps `enqueuedAtMs` on the write-ahead row.
    ///
    ///     NOT diagnostics-only — ``PendingAckStore`` READS it back to
    ///     apply the age bound, so this clock and the STORE's clock are
    ///     compared against each other. A test that pins one and not the
    ///     other can have its entry silently reaped as expired (or as
    ///     future-dated) before it asserts. To age an entry out
    ///     deliberately, pin the STORE's clock — that is the "now" side of
    ///     the comparison.
    /// - Returns: `true` on success; `false` on missing creds /
    ///   blank messageId / network failure / missing ackUrl. A `false`
    ///   return with a `pendingStore` leaves the ACK queued for replay.
    @discardableResult
    static func send(
        messageId: String,
        event: AckEvent,
        credentialsStore: CredentialsStore,
        transport: DirectAckTransport? = nil,
        pendingStore: PendingAckStore? = nil,
        idGenerator: () -> String = { UUID().uuidString },
        clock: () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) async -> Bool {
        if messageId.isEmpty {
            SwanLogger.warn("ColdStartAckSender.send: blank messageId; dropping.")
            return false
        }
        guard let creds = credentialsStore.read() else {
            // First-launch NSE-before-host race: app installed, push
            // arrives, NSE spawns BEFORE the host has ever run → no
            // CredentialsStore entry exists in the App Group, so the
            // ACK is dropped permanently. This is a documented contract
            // (RN parity — src/index.tsx:5124-5127), but it should be
            // loud, not silent: ops dashboards looking at delivery-ACK
            // funnels will see a gap that they can correlate with
            // first-install distribution. Caught 2026-05-18 — Bug 11
            // in the senior-engineer audit.
            SwanLogger.warn(
                "ColdStartAckSender.send: no credentials in App Group — first-launch NSE-before-host race. " +
                "Dropping \(event.rawValue) ACK for messageId=\(messageId). " +
                "The host MUST run at least once for credentials to land in the App Group before NSE can fire ACKs."
            )
            return false
        }
        guard let ackUrl = creds.ackUrl, !ackUrl.isEmpty else {
            // Creds blob from before delivery-click-ack shipped; the
            // warm-start init() will backfill `ackUrl` next launch.
            SwanLogger.warn(
                "ColdStartAckSender.send: creds present but ackUrl absent (pre-delivery-click-ack blob). Dropping \(event.rawValue) ACK for messageId=\(messageId)."
            )
            return false
        }
        let payload = AckPayload(
            commId: messageId,
            appId: creds.appId,
            CDID: creds.currentCDID ?? creds.generatedCDID,
            event: event,
            deviceId: creds.deviceId
        )
        // WRITE-AHEAD (SWA-9468): persist to the App-Group-backed durable queue
        // BEFORE the fire-and-forget POST. The NSE runs in a separate process
        // that iOS can suspend the moment it finishes rendering, so a POST that
        // fails (device briefly offline at push arrival — the dominant killed-app
        // case) or never completes would otherwise be lost. The host app's
        // `flushPending()` drains the same App-Group queue on next launch.
        // Removed on a 2xx.
        var pendingId: String?
        if let pendingStore = pendingStore {
            let id = idGenerator()
            pendingStore.enqueue(PendingAckStore.PendingAck(
                id: id, commId: messageId, event: event,
                type: nil, linkId: nil, enqueuedAtMs: clock()
            ))
            pendingId = id
        }
        let actualTransport = transport ?? DirectAckTransport(webhookUrl: ackUrl)
        let ok = await actualTransport.post(payload)
        if ok, let pendingId = pendingId {
            pendingStore?.remove(ids: [pendingId])
        }
        return ok
    }

    /// Convenience overload for the most common entry point — a host
    /// that doesn't already hold a `CredentialsStore` instance. Reads
    /// from the same suite the SDK uses for the configured App Group
    /// (or the per-process suite when `appGroup` is `nil`), and
    /// write-ahead-persists to the durable queue on that same suite so a
    /// failed POST survives to the next warm start.
    ///
    /// - Parameters:
    ///   - messageId: FCM/APNs messageId → wire `commId`.
    ///   - event: ``AckEvent/delivered`` or ``AckEvent/clicked``.
    ///   - appGroup: App Group identifier shared between the host app
    ///     and the NSE. Pass the same identifier configured on
    ///     ``SwanConfig/appGroup``. Pass `nil` for the legacy
    ///     per-process suite path (host-process callers only — NSE
    ///     callers MUST set `appGroup`).
    @discardableResult
    static func send(
        messageId: String,
        event: AckEvent,
        appGroup: String? = nil
    ) async -> Bool {
        // Single source of truth for the cold-start suite (same helper the
        // production wiring in `Swan.makeInternalsIfNeeded` uses), so both the
        // reader and this writer resolve it identically.
        let suite = Swan.ackColdStartSuiteName(forAppGroup: appGroup)
        let store = CredentialsStore(
            store: UserDefaultsKeyValueStore(suiteName: suite)
        )
        // Same suite as credentials — the only container the NSE process
        // and the host app both see. `Swan.initialize` builds a
        // PendingAckStore on this suite too and passes it to
        // NotificationAckService as `coldStartStore`, which is what
        // drains these entries on the next warm start.
        let pendingStore = PendingAckStore(
            store: UserDefaultsKeyValueStore(suiteName: suite)
        )
        return await send(
            messageId: messageId,
            event: event,
            credentialsStore: store,
            transport: nil,
            pendingStore: pendingStore
        )
    }
}
