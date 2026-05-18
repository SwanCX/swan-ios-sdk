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
/// - Does NOT persist to ``PendingAckStore``. Cold-start path has no
///   guarantee that the SDK will ever run in this process; queueing
///   would create an "orphan" entry that the next warm-start
///   flushPending would re-fire (idempotent for backend but wasteful).
///   RN parity — `sendDirectNotificationAck` has no persistence layer.
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
    /// - Returns: `true` on success; `false` on missing creds /
    ///   blank messageId / network failure / missing ackUrl.
    @discardableResult
    static func send(
        messageId: String,
        event: AckEvent,
        credentialsStore: CredentialsStore,
        transport: DirectAckTransport? = nil
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
        let actualTransport = transport ?? DirectAckTransport(webhookUrl: ackUrl)
        return await actualTransport.post(payload)
    }

    /// Convenience overload for the most common entry point — a host
    /// that doesn't already hold a `CredentialsStore` instance. Reads
    /// from the same suite the SDK uses for the configured App Group
    /// (or the per-process suite when `appGroup` is `nil`).
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
        let suite = CredentialsStore.suiteName(forAppGroup: appGroup)
        let store = CredentialsStore(
            store: UserDefaultsKeyValueStore(suiteName: suite)
        )
        return await send(
            messageId: messageId,
            event: event,
            credentialsStore: store,
            transport: nil
        )
    }
}
