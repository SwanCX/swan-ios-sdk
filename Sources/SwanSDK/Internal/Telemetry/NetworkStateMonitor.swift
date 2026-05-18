import Foundation
#if canImport(Network)
import Network
#endif

/// Bridges Apple's `NWPathMonitor` into typed
/// ``TelemetryEvent/networkStateChanged(_:)`` emissions on the
/// ``TelemetryEmitter``.
///
/// **Capability:** `self-telemetry` (Phase 1.14 iOS port).
///
/// Spec: `conformance/scenarios/self-telemetry.feature` — scenario "SDK
/// emits networkStateChanged on connectivity transitions".
///
/// # Why this exists (RN bug catch)
///
/// RN's `NetworkMonitor` (src/core/NetworkMonitor.ts) maintains its own
/// internal `Set<(isOnline: boolean) => void>` listeners — but never
/// bridges those into the `SwanSDK.emit('networkStateChanged', ...)`
/// map at the JS layer. The CLAUDE.md and the conformance feature both
/// promise the lifecycle event, yet RN never fires it on the public
/// surface. Catching this bug here so host apps that subscribe via the
/// documented API actually get the events. Same fix as Android.
///
/// # Edge-triggered emission
///
/// Like RN's internal monitor (NetworkMonitor.ts:30-36
/// `wasOnline !== isOnline`), this class fires ONLY on transitions. The
/// initial state is fetched from the first `pathUpdateHandler` callback
/// after `start()` but no event fires until a real transition happens
/// — host apps that need the snapshot read ``currentIsOnline`` directly.
///
/// # Why `Network` framework, not `SCNetworkReachability`
///
/// `NWPathMonitor` is iOS 12+ (well below our iOS 13 floor), is the
/// Apple-recommended API since 2018, and works without entitlements.
/// `SCNetworkReachability` is the legacy CFNetwork-era API; it works
/// but Apple's documentation explicitly steers new code to `Network`.
/// No third-party dep, no entitlement gating, no Info.plist hits.
///
/// # Threading
///
/// `NWPathMonitor.pathUpdateHandler` runs on a `DispatchQueue` of our
/// choosing — we use a dedicated serial queue so transitions are
/// ordered consistently. Listeners attached via ``TelemetryEmitter``
/// run synchronously on that queue; host apps that touch UI in their
/// listeners must marshal to main themselves.
///
/// # Test seam
///
/// Production code calls ``start()`` on an instance built with a real
/// `NWPathMonitor`. Tests construct the monitor with the
/// ``simulateTransition(isOnline:)`` seam directly without an OS
/// callback, sidestepping the `Network` framework entirely.
internal final class NetworkStateMonitor: @unchecked Sendable {

    private let emitter: TelemetryEmitter
    private let lock = NSLock()
    private var currentlyOnline: Bool = false
    private var started: Bool = false

    #if canImport(Network)
    private var monitor: NWPathMonitor?
    private let queue = DispatchQueue(label: "cx.swan.sdk.netmonitor", qos: .utility)
    #endif

    init(emitter: TelemetryEmitter) {
        self.emitter = emitter
    }

    /// Snapshot of the most-recent known connectivity state.
    var currentIsOnline: Bool {
        lock.lock(); defer { lock.unlock() }
        return currentlyOnline
    }

    /// Wire the monitor to the OS `NWPathMonitor`. Idempotent — calling
    /// twice is a no-op.
    ///
    /// Production-only; tests use ``simulateTransition(isOnline:)``.
    func start() {
        #if canImport(Network)
        lock.lock()
        if started {
            lock.unlock()
            return
        }
        started = true
        let monitor = NWPathMonitor()
        self.monitor = monitor
        lock.unlock()

        // The first pathUpdateHandler callback SEEDS the current state
        // without emitting (matching RN's wasOnline gate). Subsequent
        // callbacks compare against the seed and fire on transitions.
        let isFirstCallback = ThreadSafeBool(value: true)
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            let online = path.status == .satisfied
            if isFirstCallback.getAndSet(false) {
                // First callback: seed, do not emit.
                self.lock.lock()
                self.currentlyOnline = online
                self.lock.unlock()
                return
            }
            self.emitTransition(isOnline: online)
        }
        monitor.start(queue: queue)
        #else
        // Non-Apple platforms: no-op. Tests still drive
        // simulateTransition() directly so coverage holds.
        lock.lock()
        started = true
        lock.unlock()
        #endif
    }

    /// Stop the underlying `NWPathMonitor`. Safe to call multiple times.
    /// Re-`start()`-able after `stop()` on iOS 13+ (we construct a new
    /// `NWPathMonitor` each time `start()` runs).
    func stop() {
        #if canImport(Network)
        lock.lock()
        let m = self.monitor
        self.monitor = nil
        self.started = false
        lock.unlock()
        m?.cancel()
        #else
        lock.lock(); started = false; lock.unlock()
        #endif
    }

    /// Test seam — simulate a connectivity transition without an OS
    /// callback. Fires through the same edge-trigger gate so tests
    /// exercise the real dedup behavior.
    func simulateTransition(isOnline: Bool) {
        emitTransition(isOnline: isOnline)
    }

    /// Test seam — seeds initial state without a real `NWPathMonitor` probe.
    func seedInitialStateForTests(isOnline: Bool) {
        lock.lock()
        currentlyOnline = isOnline
        lock.unlock()
    }

    private func emitTransition(isOnline: Bool) {
        lock.lock()
        let prior = currentlyOnline
        currentlyOnline = isOnline
        lock.unlock()
        if prior == isOnline { return }
        emitter.emit(TelemetryEvent.NetworkStateChangedPayload(isOnline: isOnline))
    }
}

/// Tiny lock-protected `Bool` used to gate the "first pathUpdate"
/// callback. Plain `Bool` isn't `Sendable` for cross-actor capture; an
/// `NSLock`-backed wrapper is the minimum cost.
private final class ThreadSafeBool: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    init(value: Bool) { self.value = value }
    func getAndSet(_ newValue: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let old = value
        value = newValue
        return old
    }
}
