import Foundation

/// Routes notification taps to host-app listeners.
///
/// **Capabilities:** `deeplink-url`, `deeplink-key-value`, `cold-start-routing`.
///
/// Spec:
///   - `spec/api/push.yaml#NotificationOpenedPayload` / `#DeepLinkOpenedPayload`
///   - `spec/wire/push-payload-fcm.yaml#FcmDataField` (route / defaultRoute /
///     keyValuePairs / oneLinkParams / oneLinkConfig)
///   - `spec/behavior/notification-ack.yaml` (dedup TTL + direct_ack_path)
///   - `conformance/scenarios/deeplink-url.feature`
///   - `conformance/scenarios/deeplink-key-value.feature` — keyValuePairs +
///     oneLink* fields are carried from
///     ``NotificationOpenedPayload`` through to the paired
///     ``DeepLinkOpenedPayload`` without parsing or filtering.
///   - `conformance/scenarios/cold-start-routing.feature`
///
/// # RN parity
///
/// Mirrors RN's `emitNotificationOpened` (src/index.tsx:833) +
/// `emitDeepLinkOpened` (src/index.tsx:859) + `markClickProcessed`
/// (src/index.tsx:145):
///
/// - Every notification-opened emission ALSO fires a DEEP_LINK_OPENED event
///   with `source=push` (RN src/index.tsx:847-852). Host apps that only
///   want the unified hook subscribe to
///   ``addDeepLinkOpenedListener(_:)``; host apps that want push-only
///   routing subscribe to ``addOpenedListener(_:)``.
///
/// - When no listener is registered yet, the most recent payload is
///   BUFFERED (RN src/index.tsx:836-844 `pendingNotificationPayload`). On
///   the next listener subscribe the buffered payload is delivered
///   synchronously, then cleared. This handles the cold-start case: the
///   APNs tap may resolve the payload before the host app has registered
///   its listener (the listener typically registers in `AppDelegate.
///   application(_:didFinishLaunchingWithOptions:)` / first view, the
///   APNs tap data is extracted in the same call but the listener
///   arrives later on the same thread — so synchronous delivery on
///   subscribe is the correct semantics).
///
/// - RN bug NOT replicated: RN buffers ONLY for NOTIFICATION_OPENED
///   listeners (src/index.tsx:781-808) — DEEP_LINK_OPENED listeners that
///   register late silently miss the event. We buffer for BOTH event
///   surfaces, since both are public API and the cold-start use-case
///   applies equally to either. Same fix as the Android port.
///
/// - Buffering is single-slot: a second tap before the first is delivered
///   overwrites the buffer. This is intentional — RN behavior — and
///   reflects the assumption that the listener registration is a
///   one-time setup, not an event-stream subscriber.
///
/// # cold-start-routing additions
///
/// - ``emitOpened(_:messageId:)`` consults ``ProcessedClickStore`` before
///   firing. The same notification tap can reach the router from multiple
///   paths on iOS (the `UNUserNotificationCenter.delegate` callback +
///   the `UIApplication.launchOptions` cold-start re-extraction +
///   a `NotificationServiceExtension` rebroadcast). Dedup makes the
///   router emit-once across all of them within the 30s window.
///
/// - ``clickAckHook`` is a seam owned by the (future) `delivery-click-ack`
///   capability. When ``emitOpened(_:messageId:)`` accepts a tap, the
///   hook is invoked with the messageId so the ACK transport can POST
///   exactly one `clicked` payload per accepted tap. Dedup'd taps DO NOT
///   fire the hook. The `delivery-click-ack` port wires this to its
///   3-transport ACK pipeline; until that port lands, the hook stays nil
///   and the click ACK is the host app's responsibility.
///
/// # Thread-safety
///
/// All mutable state (listener arrays, single-slot buffers, click-ack
/// hook) is protected by a single `NSLock`. Listeners are snapshotted
/// inside the lock and dispatched OUTSIDE — same pattern as
/// ``TelemetryEmitter`` — so a listener that takes a while or even
/// calls back into the router does not deadlock or block other taps.
internal final class NotificationRouter: @unchecked Sendable {

    typealias OpenedListener = @Sendable (NotificationOpenedPayload) -> Void
    typealias DeepLinkListener = @Sendable (DeepLinkOpenedPayload) -> Void
    typealias ClickAckHook = @Sendable (String) -> Void

    /// Wrapped listener with a stable UUID identity so the unregister
    /// closure can target an exact registration without relying on
    /// closure pointer equality (which Swift doesn't guarantee for
    /// `@Sendable` value closures — the optimizer may fuse identical
    /// captures into a shared block, so the same lambda variable
    /// passed to `addOpenedListener` twice would unregister both —
    /// or neither — under `unsafeBitCast` comparison). Caught
    /// 2026-05-18 — Bug 16 in the senior-engineer audit.
    private struct OpenedEntry {
        let id: UUID
        let fn: OpenedListener
    }
    private struct DeepLinkEntry {
        let id: UUID
        let fn: DeepLinkListener
    }

    private let lock = NSLock()
    private var openedListeners: [OpenedEntry] = []
    private var deepLinkListeners: [DeepLinkEntry] = []

    // Single-slot buffer. RN parity: `pendingNotificationPayload`
    // (src/index.tsx:213). Set to non-nil on a tap with no listener;
    // cleared on the next subscribe (after synchronous delivery) or on
    // the next emission with at least one listener already registered.
    private var bufferedOpened: NotificationOpenedPayload?
    private var bufferedDeepLink: DeepLinkOpenedPayload?

    // `delivery-click-ack` seam — invoked with the messageId on every
    // tap that survives dedup. The (future) delivery-click-ack
    // capability sets this hook to its 3-transport ACK transport. When
    // nil, no ACK is fired by the SDK and the host app owns the
    // round-trip.
    private var clickAckHook: ClickAckHook?

    private let processedClicks: ProcessedClickStore

    init(processedClicks: ProcessedClickStore = ProcessedClickStore()) {
        self.processedClicks = processedClicks
    }

    /// Register a listener for NOTIFICATION_OPENED. Returns an unregister
    /// closure for symmetric add/remove.
    @discardableResult
    func addOpenedListener(_ listener: @escaping OpenedListener) -> () -> Void {
        let entry = OpenedEntry(id: UUID(), fn: listener)
        // Drain the buffer BEFORE adding so a concurrent emit() can't
        // double-fire. Mirrors Android's getAndSet pattern.
        lock.lock()
        let buffered = bufferedOpened
        bufferedOpened = nil
        openedListeners.append(entry)
        lock.unlock()
        if let buffered = buffered {
            // Dispatch outside the lock; listener exceptions can't
            // re-enter under the lock and deadlock.
            invokeOpened(listener, payload: buffered, label: "buffered NOTIFICATION_OPENED")
        }
        let id = entry.id
        return { [weak self] in
            self?.removeListener(id: id)
        }
    }

    /// Register a listener for DEEP_LINK_OPENED. Returns an unregister
    /// closure.
    @discardableResult
    func addDeepLinkOpenedListener(_ listener: @escaping DeepLinkListener) -> () -> Void {
        let entry = DeepLinkEntry(id: UUID(), fn: listener)
        lock.lock()
        let buffered = bufferedDeepLink
        bufferedDeepLink = nil
        deepLinkListeners.append(entry)
        lock.unlock()
        if let buffered = buffered {
            invokeDeepLink(listener, payload: buffered, label: "buffered DEEP_LINK_OPENED")
        }
        let id = entry.id
        return { [weak self] in
            self?.removeDeepLinkListener(id: id)
        }
    }

    /// Emit a NOTIFICATION_OPENED event for the given payload.
    ///
    /// If no listener is registered, the payload is buffered for the next
    /// subscribe (single-slot). If listeners ARE registered the buffer
    /// is cleared and the payload fans out synchronously.
    ///
    /// Also emits the unified ``DeepLinkOpenedPayload`` with `source=push`
    /// (RN parity, src/index.tsx:847-852).
    ///
    /// # Dedup (cold-start-routing)
    ///
    /// If `messageId` is non-blank and the processed-clicks store reports
    /// it as already-processed within the 30s TTL, this call is a no-op.
    /// Empty / blank messageIds bypass dedup entirely (matches RN's
    /// `messageId &&` gating at every call-site).
    ///
    /// # Click ACK (delivery-click-ack seam)
    ///
    /// On an accepted (non-dup) tap with a non-blank `messageId`, the
    /// click-ack hook is invoked AFTER the payload + deep-link
    /// emissions have run. The hook ordering matches RN's
    /// `emitNotificationOpened(...); sendNotificationAck(messageId,
    /// 'clicked')` sequence (src/index.tsx:3699-3704).
    func emitOpened(_ payload: NotificationOpenedPayload, messageId: String? = nil) {
        // Dedup gate. Blank / nil id → emit unconditionally (RN parity).
        let id: String? = {
            guard let raw = messageId else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : raw
        }()
        if let id = id, !processedClicks.markProcessed(id) {
            // Drop the duplicate emission AND the duplicate ACK in one
            // place. No state mutation — preserves whatever the first
            // emission left in the buffer / listener fan-out.
            return
        }

        // Snapshot listener state under the lock; dispatch outside.
        lock.lock()
        let openedSnapshot = openedListeners
        if openedSnapshot.isEmpty {
            bufferedOpened = payload
        } else {
            bufferedOpened = nil
        }
        let deepLink = DeepLinkOpenedPayload(
            route: payload.route,
            source: .push,
            keyValuePairs: payload.keyValuePairs,
            extras: payload.extras
        )
        let deepLinkSnapshot = deepLinkListeners
        if deepLinkSnapshot.isEmpty {
            bufferedDeepLink = deepLink
        } else {
            bufferedDeepLink = nil
        }
        let hook = clickAckHook
        lock.unlock()

        for entry in openedSnapshot {
            invokeOpened(entry.fn, payload: payload, label: "NOTIFICATION_OPENED")
        }
        for entry in deepLinkSnapshot {
            invokeDeepLink(entry.fn, payload: deepLink, label: "DEEP_LINK_OPENED")
        }

        // Click-ack seam. Fire AFTER the user-facing emissions so a hook
        // that throws can't prevent the host app from receiving the
        // event.
        if let id = id, let hook = hook {
            // Swift closures don't throw by default; a hook implemented
            // with `try`-throwing code surfaces an Error only via the
            // host's wrapping. We still defensively guard for crashes by
            // letting NSException-style fatal errors bubble — listeners
            // that genuinely crash will already have crashed the SDK
            // task; no recovery is meaningful.
            hook(id)
        }
    }

    /// Emit a standalone deep-link event — fires only the deep-link
    /// listeners, NOT the notification-opened listeners. Used by the
    /// public ``Swan/handleDeepLink(_:)`` surface for external URLs
    /// (Universal Links / custom URL schemes / OneLink callbacks) that
    /// did NOT originate from a push tap.
    ///
    /// Mirrors Android's `handleDeepLink(url)` semantic: fires
    /// `DEEP_LINK_OPENED` with `source = .deepLink` and no associated
    /// notification context. Buffers if no listener has subscribed yet —
    /// host apps that handle a cold-start universal link before SDK
    /// init see the event on the next subscribe.
    func emitStandaloneDeepLink(_ payload: DeepLinkOpenedPayload) {
        lock.lock()
        let snapshot = deepLinkListeners
        if snapshot.isEmpty {
            bufferedDeepLink = payload
        } else {
            bufferedDeepLink = nil
        }
        lock.unlock()
        for entry in snapshot {
            invokeDeepLink(entry.fn, payload: payload, label: "DEEP_LINK_OPENED")
        }
    }

    /// Install (or remove, via `nil`) the click-ACK seam.
    ///
    /// Owned by the `delivery-click-ack` capability; the router stays
    /// transport-agnostic. Idempotent — late installation does NOT replay
    /// past clicks (those clicked ACKs are gone; only the next accepted
    /// tap will fire the hook).
    func setClickAckHook(_ hook: ClickAckHook?) {
        lock.lock()
        clickAckHook = hook
        lock.unlock()
    }

    // MARK: - Test seams

    /// Test seam — drains any pending buffer state.
    func clearForTests() {
        lock.lock()
        openedListeners.removeAll()
        deepLinkListeners.removeAll()
        bufferedOpened = nil
        bufferedDeepLink = nil
        clickAckHook = nil
        lock.unlock()
        processedClicks.clear()
    }

    /// Test seam — exposes the dedup store for direct assertions.
    func processedClicksForTests() -> ProcessedClickStore { processedClicks }

    /// Test seam — exposes whether a payload is currently buffered.
    func bufferedOpenedForTests() -> NotificationOpenedPayload? {
        lock.lock(); defer { lock.unlock() }
        return bufferedOpened
    }

    /// Test seam — exposes whether a deep-link payload is currently buffered.
    func bufferedDeepLinkForTests() -> DeepLinkOpenedPayload? {
        lock.lock(); defer { lock.unlock() }
        return bufferedDeepLink
    }

    // MARK: - Internals

    private func invokeOpened(
        _ listener: OpenedListener,
        payload: NotificationOpenedPayload,
        label: String
    ) {
        // Swift closures can't throw without `rethrows` plumbing; we don't
        // expose `throws` listener types. Fatal errors from listeners
        // would crash anyway — host apps absorb their own exceptions in
        // the closure body if they need isolation. This matches RN's
        // `[...eventListeners].forEach` posture (src/index.tsx:822).
        listener(payload)
        _ = label
    }

    private func invokeDeepLink(
        _ listener: DeepLinkListener,
        payload: DeepLinkOpenedPayload,
        label: String
    ) {
        listener(payload)
        _ = label
    }

    /// Remove a listener by its UUID identity. Stable across every
    /// Swift optimizer setting — unlike `unsafeBitCast`-based closure
    /// equality, which is implementation-defined for value closures.
    private func removeListener(id: UUID) {
        lock.lock(); defer { lock.unlock() }
        openedListeners.removeAll { $0.id == id }
    }

    private func removeDeepLinkListener(id: UUID) {
        lock.lock(); defer { lock.unlock() }
        deepLinkListeners.removeAll { $0.id == id }
    }
}
