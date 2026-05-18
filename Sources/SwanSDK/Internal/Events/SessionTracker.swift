import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Implements the `session-tracking` capability — foreground/background
/// detection plus the inactivity-rolling session id.
///
/// **Capability:** `session-tracking` (Phase 1.6 iOS port).
///
/// Spec:
///   - `spec/api/session.yaml`                              (public surface — no public methods; this is plumbing)
///   - `spec/behavior/session.yaml`                          (state machine)
///   - `conformance/scenarios/session-tracking.feature`
///   - `spec/scope-v1.md`                                    (`partial` parity: foreground only, no install/update)
///
/// # RN parity (foreground-only, no install/update — `@v1`)
///
/// Mirrors:
///   - RN `setupAppStateListener()` (src/index.tsx:1236) — on AppState→`active`
///     fires `appLaunched`.
///   - RN `FlushManager.start()` (src/core/FlushManager.ts:53-61) — on
///     AppState→`background` or `inactive` force-flushes the queue.
///   - RN `getSessionId()` (src/index.tsx:2083) — 20-minute inactivity
///     rollover. (Already implemented by ``SessionManager``; this class
///     extends that surface rather than replacing it.)
///
/// Wire format on the network is identical to RN: `appLaunched` is emitted
/// via the same `/v2/trackEvent` path as any other event, with the same
/// enriched `data` shape (`platform`, `deviceId`, `sessionId`, etc.).
///
/// # iOS-vs-Android divergence — flagged
///
/// **Android uses `ProcessLifecycleOwner`** (process-level `ON_START` /
/// `ON_STOP` with a ~700ms debounce across activity transitions). **iOS
/// uses `UIApplication` notifications** — `didBecomeActiveNotification` /
/// `willResignActiveNotification`. There's no per-process lifecycle on
/// iOS; the application IS the process for foreground purposes. The
/// notification pair is the canonical signal documented in Apple's UIKit
/// concurrency / lifecycle guides.
///
/// `willResignActive` (NOT `didEnterBackground`) is the right hook because
/// RN's `'inactive'` AppState corresponds to "user about to leave the
/// foreground" — RN's FlushManager treats `'inactive'` + `'background'`
/// identically (FlushManager.ts:53-61), and `willResignActive` fires
/// earlier than `didEnterBackground`, giving the SDK strictly more time to
/// drain the queue.
///
/// The lifecycle source is decoupled from the tracker's behavior via the
/// ``onForeground()`` / ``onBackground()`` callbacks — production calls
/// ``bindToApplicationLifecycle()`` which subscribes to UIApplication
/// notifications; unit tests drive the same two methods directly without
/// a UIKit runtime.
///
/// # v1 scope (do NOT add in v1)
///
/// - No install / appInstalled auto-emission (`@v2 @skipped` in the
///   conformance scenario).
/// - No appUpdated auto-emission. Host apps that want it call
///   `SwanEvents.appUpdated()` themselves.
/// - No public session-start / session-end APIs — `data.sessionId` on every
///   event is the only externally-observable session boundary.
///
/// # Queue-pause semantics
///
/// On background we set ``isPaused()`` = true so the periodic flush task
/// in ``EventTracker`` skips its tick. The force-flush invoked on
/// background already drained the queue; subsequent periodic ticks would
/// be wasted while the app is idle. Foreground clears the flag and
/// unblocks the periodic flush.
internal final class SessionTracker: @unchecked Sendable {

    private let sessionManager: SessionManager
    private let emitAppLaunched: @Sendable (String) -> Void
    private let forceFlush: @Sendable () -> Void

    /// `true` while the app is backgrounded. The ``EventTracker`` periodic-
    /// flush task consults this to skip ticks; the size-threshold flush
    /// path is NOT gated.
    private let pausedLock = NSLock()
    private var paused: Bool = false

    /// Observer tokens kept so ``unbind()`` can detach. Nil before
    /// ``bindToApplicationLifecycle()`` runs.
    #if canImport(UIKit)
    private var didBecomeActiveObserver: NSObjectProtocol?
    private var didEnterBackgroundObserver: NSObjectProtocol?
    #endif

    init(
        sessionManager: SessionManager,
        emitAppLaunched: @escaping @Sendable (String) -> Void,
        forceFlush: @escaping @Sendable () -> Void
    ) {
        self.sessionManager = sessionManager
        self.emitAppLaunched = emitAppLaunched
        self.forceFlush = forceFlush
    }

    deinit {
        unbind()
    }

    // MARK: - Test-/EventTracker-visible

    func isPaused() -> Bool {
        pausedLock.lock(); defer { pausedLock.unlock() }
        return paused
    }

    // MARK: - Lifecycle callbacks

    /// Called when the app comes to the foreground.
    ///
    /// Mirrors RN's `setupAppStateListener` `'active'` branch + the initial
    /// `appLaunched()` fired at the end of init. Both call sites end up at
    /// `this.appLaunched()` which routes through `trackEvent`.
    ///
    /// Touches the session manager (refreshing `lastActiveTime`) BEFORE
    /// firing `appLaunched` so the emitted event carries the (possibly-
    /// rolled-over) sessionId.
    func onForeground() {
        setPaused(false)
        _ = sessionManager.getId()
        emitAppLaunched(EventNames.appLaunched)
    }

    /// Called when the app moves to the background.
    ///
    /// Mirrors RN's `FlushManager.start()` AppState branch:
    /// `nextAppState === 'background' || nextAppState === 'inactive'` →
    /// `flush(true)`. Sets the paused flag so the periodic-flush task stops
    /// ticking until the next foreground.
    func onBackground() {
        setPaused(true)
        forceFlush()
    }

    // MARK: - Production wiring

    /// Wire this tracker to UIApplication's lifecycle notifications.
    ///
    /// Production callers MUST invoke this from the main thread (UIKit
    /// requirement). The handler closures capture `self` weakly so a
    /// deinitialized tracker doesn't leak.
    func bindToApplicationLifecycle() {
        #if canImport(UIKit)
        let center = NotificationCenter.default
        didBecomeActiveObserver = center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.onForeground()
        }
        // Use `didEnterBackground` (NOT `willResignActive`). The
        // `willResignActive` notification fires for every transient
        // interruption — control-center pull, incoming-call banner,
        // Face ID prompt, screenshot taken, app-switcher peek. Each
        // would have triggered `forceFlush()` + `setPaused(true)`,
        // generating spurious network churn AND leaving the periodic
        // flush stuck paused after a user dismisses control center
        // (no `didBecomeActive` fires for that transition either —
        // the user goes inactive → active with no didBecomeActive
        // hop in between, but our paused flag stays true).
        //
        // `didEnterBackgroundNotification` only fires when the app
        // is truly backgrounded (home screen, app switcher), which
        // is the semantic that matches the RN reference's "real
        // backgrounding" behavior. Caught 2026-05-18 — Bug 17 in
        // the senior-engineer audit.
        didEnterBackgroundObserver = center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.onBackground()
        }
        #endif
    }

    /// Test-only — detach previously-registered observers.
    func unbind() {
        #if canImport(UIKit)
        let center = NotificationCenter.default
        if let observer = didBecomeActiveObserver {
            center.removeObserver(observer)
            didBecomeActiveObserver = nil
        }
        if let observer = didEnterBackgroundObserver {
            center.removeObserver(observer)
            didEnterBackgroundObserver = nil
        }
        #endif
    }

    private func setPaused(_ value: Bool) {
        pausedLock.lock(); defer { pausedLock.unlock() }
        paused = value
    }
}
