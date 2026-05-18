import Foundation

/// Swan SDK — iOS, v1.
///
/// Wire-format byte-equivalent with `swan-react-native-sdk@2.7.x`.
///
/// Capabilities ported:
///   - `anonymous-identity` (Phase 1.0) — auto-registers a device on
///     first launch, issues an anonymous `generatedCDID`, and persists
///     it across restarts.
///   - `init-config` (Phase 1.10) — host-app facing initialization
///     config (``SwanConfig``), `initialized` lifecycle listener, and
///     runtime ``enableLogs(_:)`` toggle.
///   - `custom-events` (Phase 1.2) — track arbitrary named events with
///     enriched data, batched + flushed to `/v2/trackEvent`.
///   - `semantic-ecommerce-events` (Phase 1.2) — 33 typed helpers on
///     ``SwanEvents`` (productViewed, cartViewed, checkoutStarted,
///     orderCompleted, etc.) with the canonical RN typo wire names
///     preserved verbatim.
///   - `session-tracking` (Phase 1.6) — foreground/background detection
///     via UIApplication notifications, 20-min inactivity sessionId
///     rollover, `appLaunched` auto-emission on foreground, force-flush on
///     background. No install/update detection (v1 RN parity).
///   - `screen-tracking` (Phase 1.7) — manual ``screen(_:attributes:)``
///     event + ``setCurrentScreenName(_:)`` super-property
///     auto-enriched onto subsequent events. No auto-tracking in v1.
///   - `offline-queue` (Phase 1.8) — SQLite-backed durable queue;
///     events survive process death. Pre-registration buffer for events
///     enqueued before device registration completes.
///   - `network-resilience` (Phase 1.8) — exponential-backoff retry on
///     5xx + transport failures, stale-`sending` recovery on startup.
///   - `force-flush` (Phase 1.8) — ``flush()`` synchronous drain of
///     pending rows; ``getQueueSize()`` returns pending count only.
///   - `super-properties` (Phase 1.2) — country / currency / businessUnit
///     setters with absent-when-unset wire enrichment behavior.
///   - `notification-permission` (Phase 1.11) — explicit
///     ``requestNotificationPermission()`` /
///     ``hasNotificationPermission()`` against
///     `UNUserNotificationCenter`; emits `permissionGranted` /
///     `permissionDenied` lifecycle events via
///     ``addPushPermissionListener(_:)``.
///   - `deeplink-url` (Phase 1.12) — ``addNotificationOpenedListener(_:)``
///     and ``addDeepLinkOpenedListener(_:)`` deliver tap payloads.
///     ``handleNotificationUserInfo(_:messageId:)`` parses APNs userInfo;
///     ``handleNotificationTap(_:messageId:)`` parses FCM-style data
///     maps. Single-slot pre-listener buffering handles cold-start race.
///   - `cold-start-routing` (Phase 1.13) — `messageId`-keyed dedup
///     (30s TTL, lazy eviction) inside ``NotificationRouter`` plus a
///     ``setClickAckHook(_:)`` seam awaiting the `delivery-click-ack`
///     port (A20).
///   - `deeplink-key-value` (Phase 1.17) — `keyValuePairs` parsing +
///     `oneLinkParams` / `oneLinkConfig` pass-through preserved
///     verbatim through ``NotificationOpenedPayload/extras``.
///   - `self-telemetry` (Phase 1.14) — typed lifecycle events
///     (``addDeviceRegisteredListener(_:)``,
///     ``addDeviceRegistrationFailedListener(_:)``,
///     ``addNetworkStateChangedListener(_:)``) emitted from device
///     registration + an `NWPathMonitor`-backed network monitor.
///   - `push-fcm-ios` (Phase 1.15) — accepts raw APNs device tokens
///     from the host's `UIApplicationDelegate` callback, POSTs them to
///     `/device/push-subscription` (Swan backend handles the FCM v1
///     `apns` sub-object wrap). Public surface:
///     ``registerAPNsToken(_:)``, ``getPushToken()``, ``isPushReady()``,
///     ``unsubscribePush()``, ``handlePushNotificationUserInfo(_:)``.
///     No FirebaseMessaging dependency.
///   - `delivery-click-ack` (Phase 1.16) — three-transport ACK
///     pipeline. Warm-start direct, queued retry on transient failure,
///     and a cold-start static path (``ackPushDeliveredColdStart(_:)``)
///     that does NOT require ``initialize(appId:baseUrl:config:)``.
///     Public surface: ``ackPushDelivered(_:)``,
///     ``ackPushDeliveredColdStart(_:)``.
///   - `notification-channels` (Phase 1.18) — cross-platform parity
///     hook for Android `NotificationChannel`. On iOS the SDK registers
///     5 predefined `UNNotificationCategory` ids
///     (`swan_transactional`, `swan_alerts`, `swan_promotional`,
///     `swan_general`, `swan_notifications`) at init. Public surface:
///     ``getNotificationChannelId()``,
///     ``createNotificationChannel(id:name:importance:soundName:)``,
///     ``deleteNotificationChannel(id:)``. iOS-specific: `importance`
///     and `soundName` are IGNORED — iOS sets those per-notification,
///     not per-category. RN bug #13 fix:
///     ``getNotificationChannelId()`` returns the documented constant
///     `"swan_notifications"` (RN returns `appId`).
///   - `custom-notification-sound` (Phase 1.18) — internal-only
///     resolver for the `data.sound` wire field. iOS appends `.wav` if
///     no extension; `"default"` → `UNNotificationSound.default`;
///     `"silent"`/`"none"` → no sound. Consumed by A22's rendering
///     layer when building `UNMutableNotificationContent`.
///   - `badge-count` (Phase 1.18) — read/write app-icon badge.
///     iOS 16+: `UNUserNotificationCenter.setBadgeCount`. iOS 13–15:
///     `UIApplication.applicationIconBadgeNumber`. Public surface:
///     ``getBadgeCount()``, ``setBadgeCount(_:)``. Persisted across
///     restarts. Silent push does NOT change the badge (routing layer
///     never invokes `setBadgeCount` on the silent path).
///   - `push-template-basic` (Phase 1.19) — title / body / sound / badge
///     / image rendering applied to `UNMutableNotificationContent` from
///     within the host app's Notification Service Extension. Public
///     surface: ``Templates``. Host-app NSE integration:
///     `platforms/ios/EXTENSIONS.md`.
///   - `push-carousel-manual` (Phase 1.19) — user-swipeable carousel
///     payload parsing + first-image rendering in the NSE. v1 ships
///     single-image-from-first-item preview; full swipeable carousel UX
///     requires a host Notification Content Extension (EXTENSIONS.md).
///     Per-image deep-link routing works end-to-end via the existing
///     ``handleNotificationTap(_:messageId:)`` surface plus
///     ``Templates``-provided per-item route resolution.
///   - `push-carousel-auto` (Phase 1.19) — auto-rotating carousel. v1
///     ships same single-image preview as manual mode; native iOS does
///     not support timer-driven attachment swaps inside an NSE, so
///     true auto-rotation requires a host Notification Content
///     Extension that drives a timer over the SDK-parsed payload.
///
/// Per `spec/api/identity.yaml` and `spec/behavior/device-registration.yaml`,
/// `initialize(...)` returns synchronously in ~100 ms. Device
/// registration runs in a background `Task`; observe
/// [registrationStateStream] (or read [registrationState]) to wait for
/// completion.
///
/// Idempotent on re-init — if credentials are persisted, no network
/// call fires.
///
/// Public-API shape: `Swan.shared.initialize(...)`. Singleton class
/// rather than `enum` so we can hold mutable state behind an internal
/// serial queue without leaking @MainActor on every call. The class
/// is `final` so subclassing is prevented.
public final class Swan: @unchecked Sendable {
    // `@unchecked Sendable`: the class manages its own thread safety via
    // the `lock: DispatchQueue` serial queue — every mutable property
    // access (`internals`, `stateValue`, `continuations`, `lastLocation`,
    // `locationConfig`, listener registries) goes through `lock.sync`.
    // Manual synchronization is not what Swift's strict-concurrency model
    // can reason about, so `@unchecked` is the appropriate escape hatch:
    // we promise the compiler this type is safe to share across actor
    // boundaries; the runtime invariant is enforced by the serial queue.

    // MARK: - Singleton

    /// Shared instance. Mirrors Android's `Swan` Kotlin object.
    public static let shared = Swan()

    private init() {}

    // MARK: - State

    /// SDK version string emitted on the wire (`common.sdkVersion`)
    /// when the events capability lands. Anonymous-identity does not
    /// stamp this on the device-register call.
    static let sdkVersion = "2.7.3"

    /// Serial queue that protects all mutable state (`internals`,
    /// `state`). Using a serial DispatchQueue rather than an actor so
    /// the public API can stay non-async — host apps that just want
    /// `Swan.shared.swanIdentifier` shouldn't have to await.
    private let lock = DispatchQueue(label: "cx.swan.sdk.state")

    private var internals: Internals?
    private var stateValue: RegistrationState = .uninitialized
    private var continuations: [UUID: AsyncStream<RegistrationState>.Continuation] = [:]

    /// Last host-supplied location, if any. Set by
    /// ``updateLocation(latitude:longitude:accuracy:)``; read by
    /// ``getDeviceInfo()``. In-memory only — does not survive process
    /// termination (mirrors Android v1 which persists location in the
    /// device blob; an iOS persistence pass can follow if needed).
    private var lastLocation: SwanLocation?

    /// Current resolved ``LocationConfig`` — captured from
    /// ``SwanConfig`` on init. Drives ``isLocationEnabled()``.
    private var locationConfig: LocationConfig = .default

    // MARK: - init-config — listener registry
    //
    // RN exposes `sdk.addListener('initialized', cb)` plus an internal
    // `this.emit('initialized', { success: true })` (src/index.tsx:456,
    // fired IMMEDIATELY after registration kickoff — i.e. before phase 2
    // resolves). iOS exposes the same lifecycle hook via
    // [addInitializedListener] with a tightened contract: the callback
    // fires exactly once when background device registration resolves to
    // either `.registered` or `.failed`. Late registrations (after the
    // resolution has already happened) fire SYNCHRONOUSLY on subscribe
    // — strictly more useful than RN's miss-the-event behavior, while
    // preserving the "exactly one emission per registration" contract.
    //
    // Mirrors Android Phase 1.10. Mutated under [lock] alongside
    // `internals` / `stateValue`. `initEmitted` is a plain Bool — the
    // lock-acquire on every read/write is sufficient memory-barrier.
    private var initListeners: [() -> Void] = []
    private var initEmitted: Bool = false

    // The shared TelemetryEmitter is held by Swan itself (not by
    // Internals) so that every public `add<X>Listener(...)` can be
    // subscribed BEFORE `initialize(...)` runs. The pre-init
    // subscription lands in the emitter's listener list immediately;
    // `makeInternalsIfNeeded` passes this same instance into every
    // service that fires telemetry events, so the late `emit(...)`
    // calls reach the pre-init subscribers without any drain logic.
    //
    // `resetForTests` replaces this with a fresh instance. Services
    // wired from a previous test still hold the OLD reference (passed
    // at construction time) — that's intentional: any late emission
    // from a lingering detached task lands in the discarded emitter,
    // not the one the next test's subscribers are watching.
    private var _sharedTelemetryEmitter: TelemetryEmitter = TelemetryEmitter()
    var sharedTelemetryEmitter: TelemetryEmitter {
        return lock.sync { _sharedTelemetryEmitter }
    }

    // Pre-init buffers for the router-backed listener APIs.
    // `addNotificationOpenedListener` / `addDeepLinkOpenedListener`
    // historically returned a no-op when called before `initialize(...)`
    // because the underlying `NotificationRouter` only lives inside
    // `Internals`. That meant any host that wired listeners in
    // `application(_:didFinishLaunchingWithOptions:)` BEFORE the
    // initialize call lost them silently. These buffers hold pre-init
    // subscriptions until `internals.router` is alive; the bootstrap
    // path drains them.
    //
    // Entries are UUID-keyed so the pre-init unsubscribe closure can
    // identify "its" listener under lock — removing from the pending
    // buffer if still buffered, or calling the router's drained
    // unsubscribe closure if already promoted. Drain captures each
    // promotion in `drained*Unsubscribes` so a late unsubscribe still
    // works.
    private struct PendingOpenedEntry: Sendable {
        let id: UUID
        let listener: @Sendable (NotificationOpenedPayload) -> Void
    }
    private struct PendingDeepLinkEntry: Sendable {
        let id: UUID
        let listener: @Sendable (DeepLinkOpenedPayload) -> Void
    }
    private var pendingNotificationOpenedListeners: [PendingOpenedEntry] = []
    private var pendingDeepLinkOpenedListeners: [PendingDeepLinkEntry] = []
    private var drainedNotificationOpenedUnsubscribes: [UUID: () -> Void] = [:]
    private var drainedDeepLinkOpenedUnsubscribes: [UUID: () -> Void] = [:]

    /// Snapshot of the current registration state. Thread-safe.
    public var registrationState: RegistrationState {
        return lock.sync { stateValue }
    }

    /// Live stream of registration-state updates. New subscribers get
    /// the current value immediately, then every subsequent change.
    /// Idiomatic Swift Concurrency — no Combine import required (keeps
    /// the SDK Foundation-only).
    public var registrationStateStream: AsyncStream<RegistrationState> {
        AsyncStream { continuation in
            let id = UUID()
            self.lock.sync {
                self.continuations[id] = continuation
                continuation.yield(self.stateValue)
            }
            continuation.onTermination = { @Sendable _ in
                self.lock.sync { _ = self.continuations.removeValue(forKey: id) }
            }
        }
    }

    // MARK: - Public API

    /// Initialize the SDK with the default ``SwanConfig``.
    ///
    /// Spec: `spec/api/identity.yaml` `getInstance`.
    ///
    /// - Parameters:
    ///   - appId: Tenant identifier (becomes `?appId=` on every wire call).
    ///   - baseUrl: Swan API base URL (e.g.
    ///     `https://click.swan.cx/api`).
    ///
    /// Returns synchronously. Device registration runs in a background
    /// `Task`; observe [registrationStateStream] to wait for
    /// completion. Repeat calls with the same arguments are no-ops.
    ///
    /// Equivalent to calling
    /// ``initialize(appId:baseUrl:config:)`` with `config = SwanConfig()`.
    /// Preserved as a distinct method (instead of folding into the
    /// 3-arg form with a default) so binary compatibility with Phase
    /// 1.0 callers is explicit — host apps linking against the 1.0
    /// public surface keep working unchanged.
    public func initialize(appId: String, baseUrl: String) {
        initialize(appId: appId, baseUrl: baseUrl, config: SwanConfig())
    }

    /// Customer-facing entry point — initialize with just an `appId`.
    /// The wire endpoint is resolved internally from `SwanConfig.default`
    /// (i.e. production). For dev/staging integration use the
    /// ``initialize(appId:config:)`` overload with `production: false`.
    ///
    /// This is the primary signature host apps should use — same shape
    /// as the Android `Swan.init(context, appId)` form. The
    /// ``initialize(appId:baseUrl:)`` overload is retained for
    /// advanced / test-rig integrations that need to point at a custom
    /// endpoint.
    public func initialize(appId: String) {
        initialize(appId: appId, config: SwanConfig())
    }

    /// Customer-facing entry point — initialize with an `appId` and a
    /// host-supplied `SwanConfig`. The wire endpoint is resolved from
    /// `config.production` (defaults `true`).
    ///
    /// - Parameters:
    ///   - appId: Tenant identifier issued during onboarding.
    ///   - config: Host configuration (debug logs, production flag,
    ///     push opt-in, location opt-in).
    public func initialize(appId: String, config: SwanConfig) {
        initialize(
            appId: appId,
            baseUrl: Self.resolveBaseUrl(production: config.production),
            config: config
        )
    }

    /// Resolves the wire base-URL from the production flag. Internal —
    /// the customer-facing init signatures (``initialize(appId:)`` and
    /// ``initialize(appId:config:)``) derive this so host apps never
    /// have to know Swan's infrastructure URLs.
    ///
    /// Matches Android's `SwanConfig.PROD_BASE_URL` / `DEV_BASE_URL`
    /// constants. Update both sides together if Swan's edge moves.
    internal static func resolveBaseUrl(production: Bool) -> String {
        return production ? "https://click.swan.cx/api" : "https://click-dev.swan.cx/api"
    }

    // MARK: - init-config

    /// Initialize the SDK with a host-app-supplied ``SwanConfig``.
    ///
    /// **Capability:** `init-config` (Phase 1.10).
    ///
    /// Spec:
    ///   - `spec/api/identity.yaml` `getInstance`
    ///   - `spec/behavior/device-registration.yaml`
    ///   - `conformance/scenarios/init-config.feature`
    ///
    /// Mirrors RN's `SwanSDK.getInstance(appId, config)`
    /// (src/index.tsx:364) — returns within ~100 ms regardless of
    /// network state, kicks off device registration on a background
    /// `Task`, and exposes the same singleton on subsequent calls.
    ///
    /// - Parameters:
    ///   - appId: Tenant identifier (becomes `?appId=` on every wire call).
    ///   - baseUrl: Swan API base URL (e.g.
    ///     `https://click.swan.cx/api`).
    ///   - config: Optional host-app configuration. Defaults to
    ///     ``SwanConfig`` defaults (logging off, isProduction false).
    ///
    /// Returns synchronously. Device registration runs in a background
    /// `Task`; observe [registrationStateStream] OR register an
    /// ``addInitializedListener(_:)`` to wait for completion. Repeat
    /// calls with the same arguments are no-ops (with the lone caveat
    /// that ``SwanConfig/logging`` is re-applied to ``SwanLogger`` on
    /// every call — useful for hosts that flip the flag from a
    /// settings screen).
    ///
    /// ## Validation
    ///
    /// `appId` and `baseUrl` are not empty-checked here — that matches
    /// RN's posture (RN's `getInstance` accepts anything). An empty
    /// `appId` will surface on the wire as `?appId=`, which the
    /// backend rejects; surfacing the error there gives the host app
    /// a clearer diagnostic than silently swallowing it.
    public func initialize(appId: String, baseUrl: String, config: SwanConfig) {
        // Apply logging flag BEFORE anything else so any early debug
        // traces in this method respect the caller's preference.
        SwanLogger.setEnabled(config.debug)

        SwanLogger.info("[SwanSDK] Starting SDK initialization...")

        // Capture the location-config snapshot so `isLocationEnabled()`
        // and `updateLocation(...)` can read it without going through
        // the full Internals object. Cheap; gated by the same lock as
        // everything else.
        lock.sync { self.locationConfig = config.location }

        let bootstrap = makeInternalsIfNeeded(appId: appId, baseUrl: baseUrl, config: config)
        guard let internals = bootstrap.installed else { return }
        if bootstrap.alreadyInitialized {
            // Re-init is a no-op for transport state, but the logging
            // flag still flips above. Mirrors Android Phase 1.10.
            SwanLogger.debug(
                "Swan.initialize(): re-init with appId=\(appId); transport unchanged, debug=\(config.debug)"
            )
            return
        }
        SwanLogger.debug(
            "Swan.initialize(): starting appId=\(appId), debug=\(config.debug), production=\(config.production)"
        )

        // Cached path: if credentials already exist, transition straight
        // to `.registered` without a network call. Mirrors RN's
        // `DeviceRegistrationService.registerDevice()` short-circuit.
        if let cached = internals.store.read() {
            // delivery-click-ack: backfill ackUrl on credentials persisted
            // before the delivery-click-ack port shipped. Older creds
            // blobs don't have the field; cold-start sender silently
            // no-ops on them. Re-save once on warm path so future cold
            // starts succeed.
            if cached.ackUrl == nil {
                let ackUrl = Self.resolveAckUrl(isProduction: config.production)
                internals.store.save(cached.withFields(ackUrl: .some(ackUrl)))
            }
            SwanLogger.info("[SwanSDK] Device registered successfully: \(cached.deviceId)")
            updateState(.registered(
                deviceId: cached.deviceId,
                generatedCDID: cached.generatedCDID
            ))
            // offline-queue: drain any pre-reg rows accumulated by track()
            // calls that landed before credentials were loaded. Survives
            // process death — pre_reg rows from a prior crashed run get
            // picked up here too.
            Task.detached(priority: .utility) { [weak tracker = internals.tracker] in
                tracker?.onCredentialsAvailable()
            }
            // delivery-click-ack: drain the retry queue on cached warm
            // path. Best-effort; runs off the registration task so
            // initialize() stays non-blocking. Mirror Android.
            Task.detached(priority: .utility) { [weak self] in
                guard let self = self else { return }
                guard let ackService = self.lock.sync(execute: { self.internals?.ackService }) else { return }
                await ackService.flushPending()
            }
            // init-config: cached path resolves phase 2 immediately.
            fireInitializedOnce()
            return
        }

        updateState(.registering)
        Task.detached(priority: .utility) { [weak self] in
            guard let self = self else { return }
            let result = await internals.service.registerDevice()
            switch result {
            case .success(let creds):
                SwanLogger.info("[SwanSDK] Device registered successfully: \(creds.deviceId)")
                self.updateState(.registered(
                    deviceId: creds.deviceId,
                    generatedCDID: creds.generatedCDID
                ))
                // offline-queue: promote pre-reg rows now that credentials
                // are live. Lives on the same task so the post-register
                // flush observes the promoted rows.
                internals.tracker.onCredentialsAvailable()
                // delivery-click-ack: drain queued ACKs on fresh register
                // too. Host may have queued ACKs from a prior install /
                // a cold-start path that ran before init() — unlikely but
                // cheap. Mirror Android.
                await internals.ackService.flushPending()
            case .failure(let error):
                self.updateState(.failed(error: error))
            }
            // init-config: emit 'initialized' once, regardless of
            // outcome. Mirrors RN's `emit('initialized')` but tightened
            // to fire AFTER phase 2 resolves rather than immediately on
            // method return — the phase-2 resolution IS the most useful
            // gate for the host app (RN's "immediate" fire is racy and
            // misleading; host apps generally want to know when
            // credentials are usable).
            self.fireInitializedOnce()
        }
    }

    /// Register a one-shot callback fired when the SDK's background
    /// device-registration phase resolves (either ``RegistrationState/registered(deviceId:generatedCDID:)``
    /// or ``RegistrationState/failed(error:)``).
    ///
    /// **Capability:** `init-config` (Phase 1.10).
    ///
    /// Spec:
    ///   - `spec/api/identity.yaml` `getInstance`
    ///   - `conformance/scenarios/init-config.feature`
    ///     (scenario "SDK emits initialized lifecycle event when phase 2 completes")
    ///
    /// Mirrors RN's `sdk.addListener('initialized', cb)` lifecycle event
    /// (src/index.tsx:456 `this.emit('initialized', { success: true })`).
    ///
    /// ## Semantics
    ///
    /// - Each callback fires AT MOST ONCE, even if ``initialize(appId:baseUrl:config:)``
    ///   is re-entered.
    /// - If phase 2 has ALREADY resolved by the time you register, the
    ///   callback fires SYNCHRONOUSLY on this call. RN drops late
    ///   registrations on the floor; we surface them so host apps that
    ///   register listeners after `initialize(...)` (e.g. inside a
    ///   `Task`, after a config screen) still observe the event. This
    ///   is a strict superset of RN behavior — no listener registered
    ///   before the emission gets two callbacks.
    /// - If ``initialize(appId:baseUrl:config:)`` has NOT been called
    ///   yet, the callback is queued and fires when phase 2 resolves.
    /// - Exceptions thrown by the callback are caught and logged; they
    ///   do NOT propagate to the SDK's `Task`.
    ///
    /// ## Threading
    ///
    /// - Callbacks fired post-registration run on the SDK's
    ///   `Task.detached` context (utility QoS). If you need to touch UI
    ///   state, marshal back to the main actor inside your callback.
    /// - Callbacks fired synchronously on subscribe (late registration)
    ///   run on the caller's thread.
    public func addInitializedListener(_ callback: @escaping () -> Void) {
        let fireNow: Bool = lock.sync {
            if self.initEmitted {
                return true
            }
            self.initListeners.append(callback)
            return false
        }
        if fireNow {
            callback()
        }
    }

    /// Toggle the SDK's internal debug-log gate at runtime.
    ///
    /// **Capability:** `init-config` (Phase 1.10).
    ///
    /// Mirrors RN's `sdk.enableLogs(enabled)` (src/index.tsx:4194).
    ///
    /// The gate controls SDK-internal debug/info traces. Warnings and
    /// errors are NEVER suppressed — diagnostic signal stays visible
    /// to crash reporters regardless of this flag. This deliberately
    /// diverges from RN, which gates all levels under the same flag;
    /// see ``SwanLogger`` doc.
    ///
    /// Equivalent to setting ``SwanConfig/logging`` at `initialize`
    /// time; this variant is for host apps that want to flip the flag
    /// at runtime (e.g. from a hidden debug screen).
    public func enableLogs(_ enabled: Bool) {
        SwanLogger.setEnabled(enabled)
    }

    /// Fire every registered ``addInitializedListener(_:)`` callback
    /// exactly once, on the calling context. Mirrors Android's
    /// `fireInitializedOnce()` (Swan.kt). Idempotent: subsequent calls
    /// are no-ops. Late ``addInitializedListener(_:)`` registrations
    /// (after this method has run) fire synchronously on subscribe.
    private func fireInitializedOnce() {
        // `firstFlip` is true only on the very first call to this
        // method — `initEmitted` flips false → true here. Re-init or
        // late-subscribe paths skip the lifecycle log marker so we
        // don't spam the host console.
        let (firstFlip, snapshot): (Bool, [() -> Void]) = lock.sync {
            if self.initEmitted { return (false, []) }
            self.initEmitted = true
            let copy = self.initListeners
            self.initListeners.removeAll()
            return (true, copy)
        }
        if firstFlip {
            SwanLogger.info("[SwanSDK] SDK initialization completed successfully")
        }
        for listener in snapshot {
            listener()
        }
    }

    /// Returns the current Swan identifier — the logged-in CDID if
    /// present, else the anonymous `generatedCDID`, else `nil` if
    /// registration hasn't completed yet.
    ///
    /// Spec: `spec/api/identity.yaml` `getSwanIdentifier`.
    /// Source-of-truth: `swan-react-native-sdk/src/index.tsx:1854`
    /// `currentCDID || generatedCDID`.
    public var swanIdentifier: String? {
        return lock.sync {
            guard let internals = self.internals else { return nil }
            guard let creds = internals.store.read() else { return nil }
            return creds.currentCDID ?? creds.generatedCDID
        }
    }

    /// Snapshot of the SDK's view of the host device — device fingerprint
    /// (`platform` / `osModal` / `deviceModal` / `deviceBrand`), persisted
    /// registration identifiers (`deviceId` / `generatedCDID` /
    /// `currentCDID` / `identifier`), and the last
    /// ``updateLocation(latitude:longitude:accuracy:)`` payload if any.
    ///
    /// Returned `SwanDeviceInfo.platform` is always `"ios"`. The CDID
    /// fields are `nil` until the first device-register round-trip
    /// completes; ``swanIdentifier`` returns the same string the
    /// listener-event surface exposes at the moment of the call.
    ///
    /// Synchronous snapshot — safe to call from any thread. Repeated
    /// reads may return different `currentCDID` values if an
    /// identify/logout call races; use
    /// ``addSwanIdentifierChangedListener(_:)`` for change notifications.
    public func getDeviceInfo() -> SwanDeviceInfo {
        let device = EventEnrichment.DeviceInfo.current()
        let (creds, location) = lock.sync { (internals?.store.read(), lastLocation) }
        return SwanDeviceInfo(
            platform: device.platform,
            osModal: device.osModal,
            deviceModal: device.deviceModal,
            deviceBrand: device.deviceBrand,
            deviceId: creds?.deviceId,
            generatedCDID: creds?.generatedCDID,
            currentCDID: creds?.currentCDID,
            identifier: creds?.identifier,
            location: location
        )
    }

    /// Push host-supplied coordinates into the SDK's view of the device.
    ///
    /// The SDK does NOT acquire location itself — host apps that want
    /// location-tagged events fetch coordinates via their preferred
    /// framework (CoreLocation, etc.) and forward the result here.
    ///
    /// Coordinates are WGS-84 decimal degrees. Accuracy is in meters at
    /// 68% confidence (matches `CLLocation.horizontalAccuracy`). Pass
    /// `accuracy: nil` if the host doesn't have it.
    ///
    /// Timestamp is captured from the SDK clock at call time. Stored
    /// in-memory and surfaced via ``getDeviceInfo()``.``SwanDeviceInfo/location``.
    ///
    /// No-op when ``SwanConfig/location``.enabled is `false` (the SDK
    /// stays out of location-related state unless the host explicitly
    /// opts in). Mirrors Android's `updateLocation(lat, lng, accuracy?)`
    /// semantics.
    public func updateLocation(
        latitude: Double,
        longitude: Double,
        accuracy: Double? = nil
    ) {
        let enabled = lock.sync { locationConfig.enabled }
        guard enabled else {
            SwanLogger.warn(
                "Swan.updateLocation: location disabled in SwanConfig; coordinates dropped"
            )
            return
        }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let location = SwanLocation(
            latitude: latitude,
            longitude: longitude,
            accuracy: accuracy,
            timestamp: now
        )
        lock.sync { lastLocation = location }
    }

    /// Returns the current ``SwanConfig/location`` `enabled` flag — `true`
    /// when the host app has opted into location tagging.
    ///
    /// Host apps gate their own coordinate-acquisition logic on this
    /// flag so they don't burn battery / trigger OS permission prompts
    /// for an SDK that won't use the data.
    public func isLocationEnabled() -> Bool {
        return lock.sync { locationConfig.enabled }
    }

    // MARK: - custom-events / semantic-ecommerce-events

    /// Track a custom event.
    ///
    /// **Capability:** `custom-events`.
    ///
    /// Spec:
    ///   - `spec/api/events.yaml` `customEvent`
    ///   - `spec/wire/event-ingest.yaml`
    ///   - `spec/wire/golden/event-ingest-batch.json`
    ///   - `spec/behavior/queue.yaml`
    ///   - `conformance/scenarios/custom-events.feature`
    ///
    /// Mirrors RN's `customEvent(name, data)` (src/index.tsx:2226) and
    /// `trackEvent(name, data)` (src/index.tsx:2121). The event is enqueued
    /// on an in-memory FIFO queue and flushed to `/v2/trackEvent` when
    /// either the batch threshold (10 events) or the periodic timer (30 s)
    /// fires, or when ``flush()`` is called.
    ///
    /// Auto-enriches the `data` payload with `platform`, `osModal`,
    /// `deviceModal`, `deviceBrand`, `deviceId`, `sessionId`, plus the
    /// host-app-supplied super-properties (``setCountry(_:)``,
    /// ``setCurrency(_:)``, ``setBusinessUnit(_:)``) when set. Super-
    /// properties OMIT-when-empty on the wire — see ``EventEnrichment`` for
    /// the omit-when-empty rationale (RN bug #2 fix).
    ///
    /// Returns IMMEDIATELY (fire-and-forget).
    ///
    /// - Parameter name: wire event name (e.g. `"productViewed"`,
    ///   `"watchedVideo"`). MUST be non-empty and MUST NOT be one of the
    ///   reserved internal names (`SWAN_NOTIFICATION_ACK`, `PUSH_SUBSCRIBE`,
    ///   etc.) — use the dedicated capability API for those instead.
    /// - Parameter attributes: caller-provided payload. SDK-managed keys
    ///   (`platform`, `deviceId`, `sessionId`, ...) override any caller
    ///   key with the same name (matches RN's spread behavior).
    ///
    /// No-op if ``initialize(appId:baseUrl:config:)`` hasn't been called,
    /// or if credentials are not yet loaded (pre-registration). The
    /// offline-queue port (later) will replace the pre-reg drop with a
    /// buffer that promotes on credential availability.
    public func track(_ name: String, attributes: [String: JSONValue] = [:]) {
        guard let tracker = lock.sync(execute: { internals?.tracker }) else {
            SwanLogger.warn("Swan.track(): called before initialize(); event '\(name)' dropped.")
            return
        }
        tracker.track(name: name, attributes: attributes)
    }

    /// Track a custom event with a `[String: Any]` payload — convenience
    /// for callers building dictionaries from foreign data. Values are
    /// coerced to ``JSONValue`` via ``JSONValue/fromAny(_:)``; see that
    /// docc for the coercion rules.
    ///
    /// Prefer the ``track(_:attributes:)-9xv7s`` overload (``JSONValue``
    /// keyed) for compile-time correctness — this overload is the iOS
    /// equivalent of Android's `Map<String, Any?>` ergonomic.
    public func track(_ name: String, attributes: [String: Any]) {
        let typed = JSONValue.fromAnyDictionary(attributes)
        track(name, attributes: typed)
    }

    /// Force a flush of the pending event queue AND the enrich-profile
    /// queue.
    ///
    /// **Capabilities:** `custom-events` (force-flush hook on the public
    /// surface; the dedicated `force-flush` capability builds on this) +
    /// `user-attributes` (drains queued enrichments).
    ///
    /// Spec: `spec/api/offline.yaml flushEvents`,
    /// `conformance/scenarios/force-flush.feature`,
    /// `conformance/scenarios/user-attributes.feature`.
    ///
    /// Returns IMMEDIATELY. The flush runs on the SDK's internal `Task`
    /// scope. No-op if ``initialize(appId:baseUrl:config:)`` hasn't been
    /// called.
    public func flush() {
        let snapshot: (EventTracker, EnrichProfileService?)? = lock.sync {
            guard let i = internals else { return nil }
            return (i.tracker, i.enrichService)
        }
        guard let (tracker, enrichService) = snapshot else { return }
        Task.detached(priority: .utility) {
            _ = await tracker.flush()
            // user-attributes: drain queued enrichments in the SAME flush
            // call. Mirrors Android Phase 1.5 — public flush() drains BOTH
            // surfaces so host apps don't need to know about the split.
            await enrichService?.flush()
        }
    }

    /// Number of pending events in the in-memory queue (excludes the
    /// currently-in-flight batch during a flush).
    ///
    /// **Capability:** `custom-events`.
    ///
    /// Spec: `spec/api/offline.yaml getQueueSize`,
    /// `conformance/scenarios/force-flush.feature` Tier-2 scenario.
    ///
    /// Returns 0 if the SDK hasn't been initialized.
    public func getQueueSize() -> Int {
        return lock.sync { internals?.tracker.queueSize() ?? 0 }
    }

    /// Set the country super-property. Auto-enriched onto every subsequent
    /// event's `data.country`. Empty string means "not set" — the field is
    /// OMITTED from the wire payload entirely (RN bug #2 fix; see
    /// ``EventEnrichment``).
    ///
    /// Spec: `spec/api/events.yaml`, RN `setCountry()` (src/index.tsx:1470).
    public func setCountry(_ country: String) {
        guard let tracker = lock.sync(execute: { internals?.tracker }) else { return }
        tracker.updateConfig { var c = $0; c.country = country; return c }
    }

    /// Set the currency super-property. Auto-enriched onto every subsequent
    /// event's `data.currency`. Empty string means "not set" — OMITTED from
    /// the wire payload.
    public func setCurrency(_ currency: String) {
        guard let tracker = lock.sync(execute: { internals?.tracker }) else { return }
        tracker.updateConfig { var c = $0; c.currency = currency; return c }
    }

    /// Set the businessUnit super-property. Auto-enriched onto every
    /// subsequent event's `data.businessUnit`. Empty string means "not set"
    /// — OMITTED from the wire payload.
    public func setBusinessUnit(_ businessUnit: String) {
        guard let tracker = lock.sync(execute: { internals?.tracker }) else { return }
        tracker.updateConfig { var c = $0; c.businessUnit = businessUnit; return c }
    }

    // MARK: - super-properties
    //
    // The three setters above (``setCountry(_:)``, ``setCurrency(_:)``,
    // ``setBusinessUnit(_:)``) plus the absent-when-unset enrichment in
    // ``EventEnrichment`` are the full surface of the `super-properties`
    // capability. Empty default ⇒ field absent on the wire (RN bug #2 fix —
    // RN ships these as empty strings; the conformance scenario forbids
    // that). Backend tolerates the absent case verbatim.
    //
    // `screen-tracking` adds a fourth super-property (`currentScreenName`)
    // with the same omit-when-empty semantics — see ``setCurrentScreenName(_:)``
    // below.

    // MARK: - screen-tracking

    /// Track a manual screen-view event.
    ///
    /// **Capability:** `screen-tracking` (Phase 1.7 iOS port).
    ///
    /// Spec:
    ///   - `spec/api/events.yaml` `/sdk/screen`
    ///   - `spec/wire/event-ingest.yaml`
    ///   - `conformance/scenarios/screen-tracking.feature`
    ///
    /// Mirrors RN's `screen(data)` (src/index.tsx:2513) which routes through
    /// the same `trackEvent` path as any other custom event with wire
    /// `name = "screen"`. v1 is RN-parity: MANUAL only — there is NO
    /// auto-tracking on UIKit / SwiftUI navigation events. Hosts wire it up
    /// themselves via their nav router if they want it.
    ///
    /// Convenience: callers passing only a screen name get
    /// `data = { screenName: <name> }` on the wire. Additional caller
    /// attributes can be supplied via `attributes`; the resolved
    /// `screenName` always wins.
    ///
    /// No-op if ``initialize(appId:baseUrl:config:)`` hasn't been called.
    ///
    /// - Parameter name: the screen identifier (e.g. `"ProductDetails"`).
    ///   Becomes wire `data.screenName`.
    /// - Parameter attributes: optional caller-supplied extras spread under
    ///   `data` alongside the SDK-managed enrichment.
    public func screen(_ name: String, attributes: [String: JSONValue] = [:]) {
        // Caller-supplied `screenName` loses to the explicit argument — the
        // method-signature value is the canonical source of truth (matches
        // Android `Swan.screen(name, attributes)`).
        var merged = attributes
        merged["screenName"] = .string(name)
        track(EventNames.screen, attributes: merged)
    }

    /// `[String: Any]` convenience overload — coerces caller values via
    /// ``JSONValue/fromAny(_:)``.
    public func screen(_ name: String, attributes: [String: Any]) {
        let typed = JSONValue.fromAnyDictionary(attributes)
        screen(name, attributes: typed)
    }

    /// Set the current screen name as a super-property.
    ///
    /// **Capability:** `screen-tracking` (Phase 1.7 iOS port).
    ///
    /// Spec:
    ///   - `spec/api/events.yaml` `/sdk/setCurrentScreenName`
    ///   - `conformance/scenarios/screen-tracking.feature`
    ///     (scenario "setCurrentScreenName updates the super-property")
    ///
    /// Stores the value in-memory; subsequent custom events emitted via
    /// ``track(_:attributes:)-9xv7s`` (or any ``SwanEvents`` helper)
    /// auto-enrich their `data` payload with `currentScreenName`. Passing
    /// an empty string clears the property — subsequent events omit the
    /// key on the wire.
    ///
    /// **iOS-vs-Android note:** RN's `setCurrentScreenName` (src/index.tsx:1466)
    /// only stores the value for in-app notification gating (`displayIn`),
    /// NOT for event enrichment. v1 native ports treat it as a true
    /// super-property because the conformance scenario explicitly requires
    /// "subsequent custom events include the super-property in their `data`
    /// payload". Backend tolerates unknown keys per
    /// `spec/wire/RN-PARITY.md` field-stability rules.
    public func setCurrentScreenName(_ name: String) {
        guard let tracker = lock.sync(execute: { internals?.tracker }) else { return }
        tracker.updateConfig { var c = $0; c.currentScreenName = name; return c }
    }

    // MARK: - session-tracking

    /// Returns the current session id — the UUID that rolls over after 20
    /// minutes of inactivity. Mirrors RN's `getSessionId()` (src/index.tsx:2083)
    /// but the call is synchronous (RN's is async because of AsyncStorage).
    ///
    /// **Capability:** `session-tracking` (Phase 1.6 iOS port).
    ///
    /// Spec:
    ///   - `spec/api/session.yaml`
    ///   - `spec/behavior/session.yaml`
    ///   - `conformance/scenarios/session-tracking.feature`
    ///
    /// Returns `nil` if the SDK hasn't been initialized yet.
    public func getCurrentSessionId() -> String? {
        return lock.sync { internals?.sessionManager.getId() }
    }

    // MARK: - offline-queue / network-resilience / force-flush
    //
    // The public surface for these three capabilities lives on the same
    // ``track(_:attributes:)`` / ``flush()`` / ``getQueueSize()`` methods
    // declared above — see those docs for the contract. This section
    // exists so a grep for the capability id surfaces a hit.
    //
    // - `offline-queue`: ``track(_:attributes:)`` now lands rows in the
    //   SQLite-backed ``DurableEventQueue``. Pre-registration is handled
    //   transparently — events tracked before device registration land as
    //   `pre_reg` and promote when credentials arrive.
    // - `network-resilience`: 5xx + transport errors increment retryCount
    //   and re-schedule with exponential backoff (2s/4s/8s); rows hitting
    //   `maxRetries` move to terminal `failed`. Stale-`sending` rows from
    //   a crash are recovered on startup.
    // - `force-flush`: ``flush()`` is the synchronous-drain hook (returns
    //   immediately; flush runs on a background `Task`). ``getQueueSize()``
    //   returns the count of `pending` rows ONLY — `pre_reg`, `sending`,
    //   and `failed` are excluded.

    // MARK: - identify-login

    /// Promote the anonymous SDK identity to an identified user.
    ///
    /// **Capability:** `identify-login` (Phase 1.3 iOS port).
    ///
    /// Spec:
    ///   - `spec/api/identity.yaml` `/sdk/identify`
    ///   - `spec/wire/event-ingest.yaml` (skipEmission honored ONLY on userLogin)
    ///   - `spec/wire/golden/event-ingest-identify-skipemission.json`
    ///   - `conformance/scenarios/identify-login.feature`
    ///
    /// Mirrors RN's `identify(identifier, data)` (src/index.tsx:2557).
    /// Sends a `userLogin` event with `skipEmission: true` via
    /// `/v2/trackEvent` so the backend runs the profile-switching path
    /// WITHOUT emitting downstream (Kafka/RMQ/cart/journey) side-effects.
    ///
    /// ## Semantics
    ///
    /// - **Fire-and-forget.** Returns immediately. The HTTP call runs in a
    ///   background `Task`. Use ``identifyForTests(identifier:attributes:)``
    ///   from tests when you need to await the result.
    /// - **Idempotent.** Calling identify() with the SAME identifier the
    ///   SDK already knows is a no-op (no network call). RN parity
    ///   (src/index.tsx:2585).
    /// - **Best-effort.** A network or 5xx failure does NOT propagate — the
    ///   SDK identity stays unchanged and the next identify() call retries.
    /// - **Pre-registration.** Calls before device registration completes
    ///   are dropped with a warn log (mirrors Android Phase 1.3 — identify
    ///   is NOT buffered, unlike `track()`).
    ///
    /// - Parameters:
    ///   - identifier: external user identifier (email, phone, loyalty
    ///     ID). MUST be non-empty.
    ///   - attributes: optional profile-data blob to forward to the
    ///     backend in the userLogin event payload. Backend strips it
    ///     before downstream forwarding.
    public func identify(identifier: String, attributes: [String: JSONValue] = [:]) {
        guard let service = lock.sync(execute: { internals?.identifyService }) else {
            SwanLogger.warn(
                "Swan.identify(): called before initialize(); identifier='\(identifier)' dropped."
            )
            return
        }
        let profileData = attributes.isEmpty ? nil : attributes
        Task.detached(priority: .utility) {
            _ = await service.identify(identifier: identifier, profileData: profileData)
        }
    }

    /// `[String: Any]` convenience overload — coerces caller values via
    /// ``JSONValue/fromAny(_:)``.
    public func identify(identifier: String, attributes: [String: Any]) {
        let typed = JSONValue.fromAnyDictionary(attributes)
        identify(identifier: identifier, attributes: typed)
    }

    /// Test seam — awaitable variant of ``identify(identifier:attributes:)``
    /// returning the underlying ``Result``. Tests use this to assert wire
    /// shape + persistence without poking the background `Task` scheduler.
    @discardableResult
    func identifyForTests(
        identifier: String,
        attributes: [String: JSONValue] = [:]
    ) async -> Result<IdentifyResult, Error> {
        guard let service = lock.sync(execute: { internals?.identifyService }) else {
            return .failure(IdentifyError.credentialsNotFound)
        }
        let profileData = attributes.isEmpty ? nil : attributes
        return await service.identify(identifier: identifier, profileData: profileData)
    }

    /// Async login — typed-result counterpart to ``identify(identifier:attributes:)``.
    ///
    /// Use this when you want a typed ``LoginResult`` and explicit
    /// profile-switch handling (typically at the moment the user
    /// submits the sign-in form). For every other identify call —
    /// every cold-start, every profile refresh, every repeat-identify
    /// — ``identify(identifier:attributes:)`` (fire-and-forget) is the
    /// right tool.
    ///
    /// Mirrors Android's `Swan.login(identifier, attributes)` suspend
    /// function. Returns ``LoginResult/cdid`` (the resolved CDID; `nil`
    /// only on transient backend failures) and ``LoginResult/profileSwitched``
    /// (true when the backend reported a server-side profile switch).
    ///
    /// Note on queue ordering: this iOS surface delegates to the same
    /// `IdentifyService` flow as ``identify(identifier:attributes:)``,
    /// which already serializes through an async mutex. Pre-flush of
    /// the event queue is implicit on the server side via the
    /// `flushPendingEvents` closure injected into ``LogoutService``
    /// (and on a future iOS-A iteration we can extend this surface
    /// to call ``flush()`` ahead of the identify too, matching the
    /// Android `login` posture verbatim).
    @discardableResult
    public func login(
        identifier: String,
        attributes: [String: JSONValue] = [:]
    ) async -> LoginResult {
        guard let service = lock.sync(execute: { internals?.identifyService }) else {
            SwanLogger.warn(
                "Swan.login(): called before initialize(); identifier='\(identifier)' dropped."
            )
            return LoginResult(cdid: nil, profileSwitched: false)
        }
        let profileData = attributes.isEmpty ? nil : attributes
        let result = await service.identify(identifier: identifier, profileData: profileData)
        switch result {
        case let .success(identify):
            return LoginResult(cdid: identify.CDID, profileSwitched: identify.profileSwitched)
        case let .failure(error):
            SwanLogger.warn(
                "Swan.login(): identify failed — \(error.localizedDescription); returning LoginResult(cdid: nil, profileSwitched: false)."
            )
            return LoginResult(cdid: nil, profileSwitched: false)
        }
    }

    /// `[String: Any]` convenience overload of ``login(identifier:attributes:)``
    /// — coerces caller values via ``JSONValue/fromAny(_:)``.
    @discardableResult
    public func login(
        identifier: String,
        attributes: [String: Any]
    ) async -> LoginResult {
        let typed = JSONValue.fromAnyDictionary(attributes)
        return await login(identifier: identifier, attributes: typed)
    }

    // MARK: - logout-profile-reset

    /// Log out the current user, revert to anonymous identity, and clear
    /// the cached identifier locally.
    ///
    /// **Capability:** `logout-profile-reset` (Phase 1.4 iOS port).
    ///
    /// Spec:
    ///   - `spec/api/identity.yaml` `/sdk/logout`
    ///   - `spec/wire/event-ingest.yaml`
    ///   - `spec/behavior/queue.yaml` (flush-before-swap invariant)
    ///   - `conformance/scenarios/logout-profile-reset.feature`
    ///
    /// Mirrors RN's `logout()` (src/index.tsx:2759). Sends a `userLogout`
    /// event via `/v2/trackEvent` (no `skipEmission` — backend only honors
    /// the flag on userLogin).
    ///
    /// ## Semantics
    ///
    /// - **Fire-and-forget.** Returns immediately. The HTTP call runs in a
    ///   background `Task`.
    /// - **Flush-before-swap invariant.** The event queue is flushed
    ///   BEFORE the CDID swap so pending events reach the backend stamped
    ///   with the logged-in CDID, not the anonymous one we're reverting to.
    ///   The enrich-profile queue drains in the same step.
    /// - **Best-effort.** A network or 5xx failure does NOT block local
    ///   logout — `currentCDID` + `identifier` are cleared regardless of
    ///   wire outcome.
    /// - **Already anonymous.** Calling logout() when the SDK is already
    ///   anonymous is a no-op (no HTTP call, no listener fire).
    /// - **Pre-registration.** Calls before device registration completes
    ///   are dropped with a warn log.
    public func logout() {
        guard let service = lock.sync(execute: { internals?.logoutService }) else {
            SwanLogger.warn("Swan.logout(): called before initialize(); ignored.")
            return
        }
        Task.detached(priority: .utility) {
            _ = await service.logout()
        }
    }

    /// Test seam — awaitable variant of ``logout()``.
    @discardableResult
    func logoutForTests() async -> Result<LogoutResult, Error> {
        guard let service = lock.sync(execute: { internals?.logoutService }) else {
            return .failure(LogoutError.credentialsNotFound)
        }
        return await service.logout()
    }

    // MARK: - user-attributes

    /// Enrich the user profile with arbitrary key-value attributes.
    ///
    /// **Capability:** `user-attributes` (Phase 1.5 iOS port).
    ///
    /// Spec:
    ///   - `spec/api/identity.yaml` `/sdk/enrichProfile`
    ///   - `spec/wire/enrich-profile.yaml`
    ///   - `spec/wire/golden/enrich-profile.json`
    ///   - `conformance/scenarios/user-attributes.feature`
    ///
    /// Mirrors RN's `enrichProfile(profileData)` (src/index.tsx:2010) +
    /// `sendEventBatch` PROFILE_ENRICH branch (src/index.tsx:1786). The
    /// blob is queued in-memory and POSTed (one HTTP request per blob) to
    /// `/v2/customer/enrich-profile` on the next ``flush()`` call.
    ///
    /// ## Semantics
    ///
    /// - **Fire-and-forget.** Returns immediately after enqueue. The
    ///   actual HTTP roundtrip happens on the next flush — no callback,
    ///   no surfaced server response (RN documented this as a v2 BREAKING
    ///   CHANGE).
    /// - **CDID resolved at flush time.** A host app that calls
    ///   `enrichProfile()` before login, then logs in before the flush
    ///   fires, sees the POST-LOGIN CDID on the wire — RN parity
    ///   (src/index.tsx:1792).
    /// - **Per-event POST.** Each queued blob becomes one HTTP request —
    ///   NOT a batch. Failures re-queue the event at the FRONT for retry
    ///   on the next flush.
    /// - **Pre-registration.** Calls before device registration completes
    ///   are dropped with a warn log (mirrors identify/logout posture —
    ///   enrich is NOT buffered, unlike `track()`).
    public func enrichProfile(_ attributes: [String: JSONValue]) {
        guard let service = lock.sync(execute: { internals?.enrichService }) else {
            SwanLogger.warn("Swan.enrichProfile(): called before initialize(); ignored.")
            return
        }
        _ = service.enrichProfile(attributes)
    }

    /// `[String: Any]` convenience overload — coerces caller values via
    /// ``JSONValue/fromAny(_:)``.
    public func enrichProfile(_ attributes: [String: Any]) {
        let typed = JSONValue.fromAnyDictionary(attributes)
        enrichProfile(typed)
    }

    /// Test seam — exposes the live ``EnrichProfileService`` so tests can
    /// inspect the queue + await flush directly.
    func enrichProfileServiceForTests() -> EnrichProfileService? {
        return lock.sync { internals?.enrichService }
    }

    /// Test seam — exposes the live ``IdentifyService`` for direct calls.
    func identifyServiceForTests() -> IdentifyService? {
        return lock.sync { internals?.identifyService }
    }

    /// Test seam — exposes the live ``LogoutService`` for direct calls.
    func logoutServiceForTests() -> LogoutService? {
        return lock.sync { internals?.logoutService }
    }

    // MARK: - push-fcm-ios

    /// Register an APNs device token with Swan.
    ///
    /// **Capability:** `push-fcm-ios` (Phase 1.15 port).
    ///
    /// Spec:
    ///   - `spec/api/push.yaml` `/sdk/getPushToken`
    ///   - `spec/wire/push-subscription.yaml`
    ///   - `spec/behavior/push.yaml`
    ///   - `conformance/scenarios/push-fcm-android.feature`
    ///     (the iOS port satisfies the same wire contract via the
    ///      backend's FCM v1 `apns` sub-object path)
    ///
    /// # Wiring
    ///
    /// Host apps call this from
    /// `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`:
    ///
    /// ```swift
    /// func application(
    ///     _ application: UIApplication,
    ///     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    /// ) {
    ///     Swan.shared.registerAPNsToken(deviceToken)
    /// }
    /// ```
    ///
    /// The SDK hex-encodes the `Data` token, POSTs it to
    /// `/device/push-subscription`, and persists it. Idempotent — a
    /// repeat call with the same token after a successful sync is a
    /// no-op (saves a wire round-trip vs RN, which always POSTs).
    ///
    /// Fire-and-forget. No-op if ``initialize(appId:baseUrl:config:)``
    /// hasn't been called or the token is empty.
    ///
    /// # iOS-vs-Android divergence
    ///
    /// Android pulls the FCM token from FirebaseMessaging; iOS receives
    /// the APNs token from the OS via `UIApplicationDelegate`. Both
    /// reach the same backend endpoint with the same payload shape —
    /// the backend's PUSH-HTTP pipeline maps APNs tokens through FCM v1
    /// with the `apns` sub-object. There is no FirebaseMessaging
    /// dependency on the iOS path.
    public func registerAPNsToken(_ token: Data) {
        let hex = APNsTokenEncoder.hexString(from: token)
        registerAPNsTokenHex(hex)
    }

    /// String-overload — for hosts that already hold a hex-encoded token
    /// (e.g. from a custom URLSession credential cache). Same semantics
    /// as ``registerAPNsToken(_:)``.
    public func registerAPNsTokenHex(_ hexToken: String) {
        guard let service = lock.sync(execute: { internals?.apnsTokenService }) else {
            SwanLogger.warn("Swan.registerAPNsToken: called before initialize(); ignored.")
            return
        }
        if hexToken.isEmpty {
            SwanLogger.warn("Swan.registerAPNsToken: empty token; ignored.")
            return
        }
        Task.detached(priority: .utility) {
            _ = await service.registerToken(hexToken)
        }
    }

    /// Returns the current APNs token (hex-encoded), or `nil` if push
    /// hasn't been registered yet.
    ///
    /// **Capability:** `push-fcm-ios` (Phase 1.15 port).
    ///
    /// Spec: `spec/api/push.yaml /sdk/getPushToken`.
    ///
    /// Returns the value the SDK last synced with the backend
    /// (from ``CredentialsStore``) — NOT an ad-hoc OS call. Returns
    /// `nil` before init or after a successful ``unsubscribePush()``.
    public func getPushToken() -> String? {
        return lock.sync { internals?.apnsTokenService.currentToken() }
    }

    /// `true` when the SDK has an APNs token registered with the
    /// backend. Returns `false` when push hasn't been registered, is
    /// pending, in error, or ``initialize(appId:baseUrl:config:)``
    /// hasn't been called.
    ///
    /// **Capability:** `push-fcm-ios` (Phase 1.15 port).
    public func isPushReady() -> Bool {
        return lock.sync { internals?.apnsTokenService.isReady() ?? false }
    }

    /// Handle an external deep-link URL — Universal Link, custom URL
    /// scheme, AppsFlyer OneLink callback, anything not originating
    /// from a Swan push tap.
    ///
    /// Fires the ``addDeepLinkOpenedListener(_:)`` listeners with
    /// `source = .deepLink` and the URL parsed into the `route` field.
    /// `keyValuePairs` carries any query-string parameters on the URL.
    /// `extras` is empty (only push payloads populate extras).
    ///
    /// Returns `true` when the SDK accepted the URL for emission
    /// (currently any non-empty URL). The host app should still route
    /// the URL into its own navigation graph regardless — the SDK's
    /// emission is for campaign-attribution + listener notification, not
    /// for replacing the host's routing.
    ///
    /// Mirrors Android's `Swan.handleDeepLink(url)` (returns Boolean).
    @discardableResult
    public func handleDeepLink(_ url: String) -> Bool {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard let router = lock.sync(execute: { internals?.router }) else {
            SwanLogger.warn(
                "Swan.handleDeepLink(): called before initialize(); url='\(trimmed)' dropped."
            )
            return false
        }
        let keyValuePairs = Self.parseQueryParams(from: trimmed)
        let payload = DeepLinkOpenedPayload(
            route: trimmed,
            source: .deepLink,
            keyValuePairs: keyValuePairs,
            extras: [:]
        )
        router.emitStandaloneDeepLink(payload)
        return true
    }

    /// Parse the query-string of a URL into a `[String: JSONValue]` map.
    /// Returns `[:]` when the URL has no query string or fails to parse.
    /// Non-public — used only by ``handleDeepLink(_:)``.
    private static func parseQueryParams(from url: String) -> [String: JSONValue] {
        guard let components = URLComponents(string: url),
              let items = components.queryItems else {
            return [:]
        }
        var result: [String: JSONValue] = [:]
        for item in items {
            if let value = item.value {
                result[item.name] = .string(value)
            }
        }
        return result
    }

    /// Returns `true` only when push is fully wired and the user can
    /// receive Swan notifications: an APNs token is registered AND the
    /// OS has granted notification permission.
    ///
    /// Combined gate read — equivalent to
    /// `await hasNotificationPermission() && getPushToken() != nil`.
    /// Use this when you need a single yes/no for "should I display
    /// push-related UI / opt-in flow" instead of branching on the two
    /// underlying reads separately.
    ///
    /// Asynchronous because the underlying
    /// ``hasNotificationPermission()`` reads from
    /// `UNUserNotificationCenter.getNotificationSettings`, which is
    /// itself async.
    public func isPushEnabled() async -> Bool {
        let permission = await hasNotificationPermission()
        let tokenRegistered = getPushToken() != nil
        return permission && tokenRegistered
    }

    /// Revoke the push subscription with the Swan backend.
    ///
    /// **Capability:** `push-fcm-ios` (Phase 1.15 port).
    ///
    /// Spec: `spec/api/push.yaml /sdk/unsubscribePush`,
    /// `spec/wire/golden/push-subscription-unsubscribe.json`.
    ///
    /// Mirrors RN's `unsubscribePush()` (src/index.tsx:3881). POSTs
    /// `subscription: null, status: "revoked"`, clears the persisted
    /// token, and transitions state to ``APNsPushState/unsubscribed``.
    /// Best-effort — the local state clears regardless of network
    /// outcome (RN parity).
    ///
    /// Fire-and-forget. No-op if ``initialize(appId:baseUrl:config:)``
    /// hasn't been called.
    public func unsubscribePush() {
        guard let service = lock.sync(execute: { internals?.apnsTokenService }) else { return }
        Task.detached(priority: .utility) {
            _ = await service.unsubscribe()
        }
    }

    /// Process a remote-notification `userInfo` dictionary.
    ///
    /// **Capability:** `push-fcm-ios` (Phase 1.15 port).
    ///
    /// Hosts wire this from
    /// `application(_:didReceiveRemoteNotification:fetchCompletionHandler:)`
    /// or the equivalent `UNUserNotificationCenterDelegate` callback.
    ///
    /// v1: thin pass-through into the orchestrator for telemetry hooks
    /// + state observation. Per-notification rendering + click routing
    /// flows through A19's `NotificationRouter` (post-merge). The
    /// public entry-point is on the SDK facade today so host apps can
    /// wire `UIApplicationDelegate` without waiting for the router PR.
    public func handlePushNotificationUserInfo(_ userInfo: [AnyHashable: Any]) {
        guard let service = lock.sync(execute: { internals?.apnsTokenService }) else { return }
        service.handleIncoming(userInfo: userInfo)
    }

    // MARK: - delivery-click-ack

    /// Manually POST a delivery ACK for a push.
    ///
    /// **Capability:** `delivery-click-ack` (Phase 1.16 port).
    ///
    /// Spec:
    ///   - `spec/api/push.yaml#sendNotificationAck`
    ///   - `spec/wire/notification-ack.yaml`
    ///   - `spec/behavior/notification-ack.yaml`
    ///   - `conformance/scenarios/delivery-click-ack.feature`
    ///
    /// Mirrors RN's `sendNotificationAck(messageId, 'delivered')`
    /// (src/index.tsx:2838). Use the FCM/APNs `messageId` as `commId`.
    ///
    /// # Behavior
    ///
    /// - Fire-and-forget. Returns immediately. The actual HTTP POST
    ///   happens on a background Task.
    /// - If the direct POST fails (network / 5xx), the entry is
    ///   persisted to the retry queue and drained on the next call to
    ///   ``initialize(appId:baseUrl:config:)`` (or via
    ///   ``flushPendingAcks()`` if a host wants to drain on demand).
    /// - If the SDK is not yet initialized, use
    ///   ``ackPushDeliveredColdStart(_:)`` from your NSE / cold-start
    ///   handler instead — that path reads credentials straight from
    ///   UserDefaults and POSTs without an SDK bootstrap.
    public func ackPushDelivered(_ messageId: String) {
        guard let service = lock.sync(execute: { internals?.ackService }) else {
            SwanLogger.debug(
                "Swan.ackPushDelivered: called before initialize(); ignored. Use ackPushDeliveredColdStart instead."
            )
            return
        }
        _ = service.sendDelivered(messageId)
    }

    /// Manually POST a click ACK for a push.
    ///
    /// **Capability:** `delivery-click-ack` (Phase 1.16 port).
    ///
    /// Mirrors RN's `sendNotificationAck(messageId, 'clicked')`
    /// (src/index.tsx:2838). Fire-and-forget. Failed POSTs persist to
    /// the retry queue.
    ///
    /// Optional `type` + `linkId` carry deep-link metadata for backend
    /// telemetry (backend ignores them today; reserved for v2 routing).
    public func ackPushClicked(
        _ messageId: String,
        type: String? = nil,
        linkId: String? = nil
    ) {
        guard let service = lock.sync(execute: { internals?.ackService }) else {
            SwanLogger.debug("Swan.ackPushClicked: called before initialize(); ignored.")
            return
        }
        _ = service.sendClicked(messageId, type: type, linkId: linkId)
    }

    /// Cold-start variant — POST a delivered ACK without requiring
    /// ``initialize(appId:baseUrl:config:)`` to have run.
    ///
    /// **Capability:** `delivery-click-ack` (Phase 1.16 port).
    ///
    /// Spec: `spec/behavior/notification-ack.yaml#direct_ack_path`.
    ///
    /// # When to use
    ///
    /// Inside your Notification Service Extension (NSE)'s
    /// `didReceive(_:withContentHandler:)` callback when:
    ///   - The SDK may not be initialized in the NSE process.
    ///   - You want the delivery ACK to fire regardless.
    ///
    /// Mirrors RN's `sendDirectNotificationAck` (src/index.tsx:5109)
    /// and the existing RN iOS NSE path
    /// (`NotificationService.swift:97`).
    ///
    /// # Behavior
    ///
    /// - Asynchronous URLSession POST. Returns the result on the
    ///   continuation. The NSE has ~30s budget to complete its work;
    ///   `await` this before calling `contentHandler(...)`.
    /// - If no credentials have been persisted yet (first-ever launch),
    ///   this is a no-op — RN parity (src/index.tsx:5124-5127).
    /// - If `ackUrl` is missing (creds saved before delivery-click-ack
    ///   shipped), the call no-ops. The next warm-start init() will
    ///   backfill `ackUrl` for subsequent cold starts.
    /// - Errors are swallowed — fire-and-forget. Returns `false` on
    ///   any failure path (missing creds, network error, non-2xx).
    @discardableResult
    public static func ackPushDeliveredColdStart(
        _ messageId: String,
        appGroup: String? = nil
    ) async -> Bool {
        return await ColdStartAckSender.send(
            messageId: messageId,
            event: .delivered,
            appGroup: appGroup
        )
    }

    /// Cold-start variant of ``ackPushClicked(_:type:linkId:)`` — for
    /// hosts that want to fire click ACKs from a cold-start deep-link
    /// path before the SDK is initialized. Same constraints as
    /// ``ackPushDeliveredColdStart(_:appGroup:)``.
    @discardableResult
    public static func ackPushClickedColdStart(
        _ messageId: String,
        appGroup: String? = nil
    ) async -> Bool {
        return await ColdStartAckSender.send(
            messageId: messageId,
            event: .clicked,
            appGroup: appGroup
        )
    }

    /// Force-drain the ACK retry queue. Host apps generally don't need
    /// to call this — the SDK drains automatically on every successful
    /// init. Exposed for hosts that want to retry after a known
    /// connectivity restore.
    ///
    /// **Capability:** `delivery-click-ack` (Phase 1.16 port).
    public func flushPendingAcks() {
        guard let service = lock.sync(execute: { internals?.ackService }) else { return }
        Task.detached(priority: .utility) {
            await service.flushPending()
        }
    }

    // MARK: - Test seams (push-fcm-ios + delivery-click-ack)

    /// Test seam — exposes the live ``APNsTokenService`` so tests can
    /// `await registerToken(...)` and assert state directly.
    func apnsTokenServiceForTests() -> APNsTokenService? {
        return lock.sync { internals?.apnsTokenService }
    }

    /// Test seam — exposes the live ``NotificationAckService``.
    func notificationAckServiceForTests() -> NotificationAckService? {
        return lock.sync { internals?.ackService }
    }

    /// Test seam — exposes the live ``PushSubscriptionService``.
    func pushSubscriptionServiceForTests() -> PushSubscriptionService? {
        return lock.sync { internals?.pushSubscriptionService }
    }

    // MARK: - Test seam

    /// Test-only — resets state so a subsequent `initialize(...)` can
    /// fire from scratch. Not part of the public API surface.
    func resetForTests() {
        let snapshot: (
            tracker: EventTracker?,
            sessionTracker: SessionTracker?,
            router: NotificationRouter?,
            emitter: TelemetryEmitter?,
            netMon: NetworkStateMonitor?,
            previousSharedEmitter: TelemetryEmitter
        ) = lock.sync {
            let t = self.internals?.tracker
            let st = self.internals?.sessionTracker
            let r = self.internals?.router
            let e = self.internals?.telemetryEmitter
            let n = self.internals?.networkMonitor
            // delivery-click-ack: drop any persisted retry entries so a
            // per-test enqueue doesn't bleed across tests. Mirror Android.
            self.internals?.ackService.clear()
            // push-fcm-ios: reset push state machine so a subsequent
            // initialize doesn't see a stale `.ready` / `.failed`.
            self.internals?.apnsTokenService.resetForTests()
            self.internals = nil
            self.stateValue = .uninitialized
            for (_, c) in self.continuations { c.yield(.uninitialized) }
            // init-config: clear listener registry + emitted flag so
            // per-test subscriptions are isolated. SwanLogger.enabled
            // is also reset — keeps tests deterministic.
            self.initListeners.removeAll()
            self.initEmitted = false
            // Location: clear in-memory state so per-test isolation holds.
            self.lastLocation = nil
            self.locationConfig = .default
            // Swap in a fresh shared TelemetryEmitter. Any lingering
            // detached task captured the OLD instance and will emit
            // into the discarded emitter — so the next test's
            // subscribers (which land on the new instance) cannot
            // receive stale callbacks or buffered events.
            let old = self._sharedTelemetryEmitter
            self._sharedTelemetryEmitter = TelemetryEmitter()
            return (t, st, r, e, n, old)
        }
        // Stop tracker outside the lock to avoid task cancellation
        // re-entering. EventTracker.stop() takes its own lock — calling
        // it inside our serial queue would NOT deadlock (different lock)
        // but the principle of "no I/O inside our lock" is cheap to keep.
        snapshot.tracker?.stop()
        // session-tracking: detach UIApplication observers so the next
        // test run gets a fresh notification subscription. No-op if the
        // test bootstrap didn't install observers.
        snapshot.sessionTracker?.unbind()
        // notification-permission / routing — clear listener registries
        // + buffered state so per-test fixtures are isolated.
        snapshot.router?.clearForTests()
        // Defensively clear the old shared emitter's listener registry
        // so any stale closures captured by lingering tasks fan out
        // into an empty list. Not strictly required (the test that
        // owned those closures has finished), but cheap insurance.
        snapshot.previousSharedEmitter.clearForTests()
        snapshot.netMon?.stop()
        SwanLogger.setEnabled(false)
    }

    /// Test-only accessor — exposes the live SessionTracker so tests can
    /// drive `onForeground()` / `onBackground()` without a UIKit runtime.
    /// Returns `nil` if the test bootstrap didn't install one.
    func sessionTrackerForTests() -> SessionTracker? {
        return lock.sync { internals?.sessionTracker }
    }

    /// Test-only accessor — exposes the live SessionManager so tests can
    /// assert sessionId rollover semantics.
    func sessionManagerForTests() -> SessionManager? {
        return lock.sync { internals?.sessionManager }
    }

    /// Test-only accessor — exposes the live EventTracker so tests can
    /// `await flush()` (the public ``flush()`` is fire-and-forget).
    func eventTrackerForTests() -> EventTracker? {
        return lock.sync { internals?.tracker }
    }

    /// Test-only — injects internals from the test harness so tests can
    /// supply a fake transport without round-tripping through
    /// production-only paths.
    func initializeForTests(
        appId: String,
        baseUrl: String,
        store: CredentialsStore,
        client: HttpTransport,
        appGroup: String? = nil
    ) {
        let bootstrap = makeInternalsForTests(
            appId: appId, baseUrl: baseUrl, store: store, client: client,
            appGroup: appGroup
        )
        guard let internals = bootstrap.installed else { return }
        if bootstrap.alreadyInitialized { return }

        if let cached = internals.store.read() {
            updateState(.registered(
                deviceId: cached.deviceId,
                generatedCDID: cached.generatedCDID
            ))
            fireInitializedOnce()
            return
        }

        updateState(.registering)
        Task.detached(priority: .utility) { [weak self] in
            guard let self = self else { return }
            let result = await internals.service.registerDevice()
            switch result {
            case .success(let creds):
                SwanLogger.info("[SwanSDK] Device registered successfully: \(creds.deviceId)")
                self.updateState(.registered(
                    deviceId: creds.deviceId,
                    generatedCDID: creds.generatedCDID
                ))
            case .failure(let error):
                self.updateState(.failed(error: error))
            }
            self.fireInitializedOnce()
        }
    }

    // MARK: - Internals

    private struct Internals {
        let appId: String
        let baseUrl: String
        // Captured at bootstrap so post-init handlers (e.g. the carousel
        // per-item click-data reader in `handleNotificationUserInfo`)
        // can locate the configured App Group without re-reading
        // `SwanConfig`. `nil` when the host hasn't configured one.
        let appGroup: String?
        let store: CredentialsStore
        let service: DeviceRegistrationService
        let sessionManager: SessionManager
        let tracker: EventTracker
        let identifyService: IdentifyService
        let logoutService: LogoutService
        let enrichService: EnrichProfileService
        /// session-tracking — owns UIApplication notification observers
        /// and the paused flag the periodic flush task consults. Optional
        /// because the test bootstrap may opt out.
        let sessionTracker: SessionTracker?
        // notification-permission / deeplink-url / cold-start-routing /
        // deeplink-key-value / self-telemetry — Phase 1.11-1.17 wiring.
        let permissionService: NotificationPermissionService
        let router: NotificationRouter
        let telemetryEmitter: TelemetryEmitter
        let networkMonitor: NetworkStateMonitor
        // push-fcm-ios
        let pushSubscriptionService: PushSubscriptionService
        let apnsTokenService: APNsTokenService
        // delivery-click-ack
        let ackService: NotificationAckService
        // notification-channels (iOS UNNotificationCategory grouping —
        // see [NotificationCategoryManager] for the iOS-vs-Android
        // semantic divergence) + custom-notification-sound.
        let categoryManager: NotificationCategoryManager
        // badge-count
        let badgeService: BadgeService
    }

    // MARK: - delivery-click-ack — env-to-URL mapping
    //
    // Matches Android's `Swan.WEBHOOK_PROD_URL` / `Swan.WEBHOOK_STAGE_URL`
    // + RN's `WEBHOOK_BASE_URL` (src/constants/ApiUrls.ts:6-9). Hard-coded
    // — the webhook is a Swan-operated endpoint, not customer-pluggable.
    // v1 never exposes this as a config knob.
    private static let webhookProdUrl = "https://webhook.swan.cx/api/mobile-push-tracking"
    private static let webhookStageUrl = "https://webhook-dev.swan.cx/api/mobile-push-tracking"

    /// Resolve the env-specific webhook URL from
    /// ``SwanConfig/isProduction``. Mirrors Android `resolveAckUrl`.
    internal static func resolveAckUrl(isProduction: Bool) -> String {
        return isProduction ? Self.webhookProdUrl : Self.webhookStageUrl
    }

    private struct BootstrapResult {
        let installed: Internals?
        let alreadyInitialized: Bool
    }

    private func makeInternalsIfNeeded(appId: String, baseUrl: String, config: SwanConfig) -> BootstrapResult {
        return lock.sync {
            if let existing = self.internals {
                if existing.appId != appId || existing.baseUrl != baseUrl {
                    // Idempotent: same appId+baseUrl is a no-op. Different
                    // args is a host-app bug; we keep the original config
                    // and the host learns via console logging in v2.
                }
                return BootstrapResult(installed: existing, alreadyInitialized: true)
            }
            // App Group migration: if the host is enabling cross-process
            // credential sharing for the first time, copy any existing
            // per-process credentials into the App Group suite so the
            // device doesn't need to re-register.
            CredentialsStore.migrateIfNeeded(appGroup: config.appGroup)
            let credentialsSuite = CredentialsStore.suiteName(forAppGroup: config.appGroup)
            let store = CredentialsStore(
                store: UserDefaultsKeyValueStore(suiteName: credentialsSuite)
            )
            let client = SwanHttpClient(
                deviceIdProvider: { [store] in store.read()?.deviceId }
            )
            // delivery-click-ack: resolve env-specific webhook URL from
            // SwanConfig.isProduction. The URL is persisted alongside
            // credentials so [ColdStartAckSender] can read it without
            // re-resolving env from SwanConfig in the cold-start path.
            // Mirrors Android's [Swan.resolveAckUrl].
            let ackUrl = Self.resolveAckUrl(isProduction: config.production)
            let service = DeviceRegistrationService(
                appId: appId, baseUrl: baseUrl, client: client, store: store,
                ackUrl: ackUrl
            )
            // custom-events / semantic-ecommerce-events wiring. Reuses the
            // CredentialsStore's underlying KV suite for session persistence
            // — same UserDefaults suite, namespaced sub-keys (`swanSessionId`,
            // `swanSessionLastActiveTime`).
            let sessionKV = UserDefaultsKeyValueStore(suiteName: credentialsSuite)
            let sessionManager = SessionManager(store: sessionKV)
            let tracker = EventTracker(
                appId: appId,
                baseUrl: baseUrl,
                sdkVersion: Swan.sdkVersion,
                client: client,
                credentialsStore: store,
                sessionManager: sessionManager
            )
            // offline-queue: start() also runs stale-`sending` recovery,
            // critical for crashed-mid-flush scenarios. Idempotent.
            tracker.start()
            let enrichService = EnrichProfileService(
                appId: appId,
                baseUrl: baseUrl,
                client: client,
                credentialsStore: store
            )
            // The TelemetryEmitter is held by Swan itself (see
            // `sharedTelemetryEmitter` declaration) so pre-init
            // subscriptions land in a real emitter. We reuse that same
            // instance here so every service fires events into the
            // same emitter the pre-init subscribers are watching.
            // Direct ivar read — already inside `lock.sync`.
            let telemetryEmitter = _sharedTelemetryEmitter
            let identifyService = IdentifyService(
                appId: appId,
                baseUrl: baseUrl,
                sdkVersion: Swan.sdkVersion,
                client: client,
                credentialsStore: store,
                sessionManager: sessionManager,
                configProvider: { [weak tracker] in tracker?.currentConfig() ?? EventConfig() },
                identifierChangedListener: { [weak telemetryEmitter] cdid in
                    telemetryEmitter?.emit(SwanIdentifierChangedPayload(
                        swanIdentifier: cdid, source: .identify
                    ))
                }
            )
            let logoutService = LogoutService(
                appId: appId,
                baseUrl: baseUrl,
                sdkVersion: Swan.sdkVersion,
                client: client,
                credentialsStore: store,
                sessionManager: sessionManager,
                configProvider: { [weak tracker] in tracker?.currentConfig() ?? EventConfig() },
                flushPendingEvents: { [weak tracker, weak enrichService] in
                    // Flush BOTH queues before the CDID swap so every
                    // queued event reaches the backend stamped with the
                    // logged-in CDID. Mirror Android Phase 1.5 wiring.
                    _ = await tracker?.flush()
                    await enrichService?.flush()
                },
                identifierChangedListener: { [weak telemetryEmitter] anonCDID in
                    telemetryEmitter?.emit(SwanIdentifierChangedPayload(
                        swanIdentifier: anonCDID, source: .logout
                    ))
                }
            )
            // session-tracking wiring. The tracker emits `appLaunched` via
            // the same `track()` surface as any custom event, and on
            // background calls `tracker.flush()` synchronously through the
            // closure path. The paused flag is consulted by EventTracker's
            // periodic-flush task so we skip ticks while the app is idle.
            let sessionTracker = SessionTracker(
                sessionManager: sessionManager,
                emitAppLaunched: { [weak tracker] name in
                    tracker?.track(name: name, attributes: [:])
                },
                forceFlush: { [weak tracker] in
                    Task.detached(priority: .utility) { _ = await tracker?.flush() }
                }
            )
            tracker.setPausedProvider { [weak sessionTracker] in
                sessionTracker?.isPaused() ?? false
            }
            sessionTracker.bindToApplicationLifecycle()
            // notification-permission / deeplink / telemetry wiring.
            // (telemetryEmitter was constructed above before
            // IdentifyService / LogoutService.)
            let permissionService = NotificationPermissionService()
            let router = NotificationRouter()
            // Drain any pre-init router-listener subscriptions into
            // the freshly-created router. Host apps wiring listeners
            // in didFinishLaunchingWithOptions BEFORE Swan.initialize
            // will now have their listeners attached instead of
            // silently dropped. Capture the router's per-listener
            // unsubscribe closure into the drained-map so a late
            // unsubscribe call from the pre-init API still works.
            for entry in pendingNotificationOpenedListeners {
                let unsub = router.addOpenedListener(entry.listener)
                drainedNotificationOpenedUnsubscribes[entry.id] = unsub
            }
            for entry in pendingDeepLinkOpenedListeners {
                let unsub = router.addDeepLinkOpenedListener(entry.listener)
                drainedDeepLinkOpenedUnsubscribes[entry.id] = unsub
            }
            pendingNotificationOpenedListeners.removeAll()
            pendingDeepLinkOpenedListeners.removeAll()
            let networkMonitor = NetworkStateMonitor(emitter: telemetryEmitter)
            // self-telemetry: start the network monitor under production
            // init only — tests opt into start() via NetworkStateMonitor's
            // own seams to keep `NWPathMonitor` out of unit-test runs.
            networkMonitor.start()
            // push-fcm-ios: subscribe service + orchestrator. The
            // APNsTokenService stays in `.notReady` until the host calls
            // [Swan.registerAPNsToken]. No FirebaseMessaging dependency —
            // the OS hands the host app the token, the host forwards it
            // to us.
            let pushSubscriptionService = PushSubscriptionService(
                appId: appId,
                baseUrl: baseUrl,
                sdkVersion: Swan.sdkVersion,
                client: client,
                credentialsStore: store
            )
            let apnsTokenService = APNsTokenService(
                subscriptionService: pushSubscriptionService,
                credentialsStore: store,
                telemetry: BridgedPushTelemetryEmitter(telemetry: telemetryEmitter)
            )

            // delivery-click-ack: orchestrator + retry store. Uses the
            // same UserDefaults suite as credentials so wipes via
            // [CredentialsStore.clear] do NOT clear the pending queue
            // (each KV is sub-keyed; only credential sub-keys are
            // wiped). Mirrors Android's `ACK_PENDING_PREFS_NAME` —
            // separate suite name keeps the queue scoped.
            let ackPendingStore = PendingAckStore(
                store: UserDefaultsKeyValueStore(suiteName: Self.ackPendingSuiteName)
            )
            let ackService = NotificationAckService(
                appId: appId,
                credentialsStore: store,
                transport: DirectAckTransport(webhookUrl: ackUrl),
                pendingStore: ackPendingStore
            )

            // delivery-click-ack — wire the router's clickAckHook so
            // every accepted tap (post-dedup) fires a `clicked` ACK
            // automatically. The plumbing existed since Phase 1.16 but
            // was never installed at init — customers calling
            // `Swan.shared.handleNotificationUserInfo(...)` from
            // `didReceive(response:)` got the listener emission but
            // no backend ACK. Caught 2026-05-18 — Bug 18 in the
            // post-audit fixes.
            router.setClickAckHook { [weak ackService] messageId in
                _ = ackService?.sendClicked(messageId)
            }

            // notification-channels: register the 5 predefined Swan
            // UNNotificationCategories on init. Mirrors Android Phase
            // 1.18 `ensurePredefinedChannels`. Safe to re-run.
            let categoryManager = NotificationCategoryManager()
            categoryManager.ensurePredefinedCategories()

            // badge-count: persists into the credentials' UserDefaults
            // suite under sub-key "swan_badge_count". A credentials
            // wipe (logout) does NOT clear the badge — that matches
            // RN's posture (RN never auto-clears the badge on logout).
            let badgeService = BadgeService(
                store: UserDefaultsKeyValueStore(suiteName: credentialsSuite)
            )

            let internals = Internals(
                appId: appId,
                baseUrl: baseUrl,
                appGroup: config.appGroup,
                store: store,
                service: service,
                sessionManager: sessionManager,
                tracker: tracker,
                identifyService: identifyService,
                logoutService: logoutService,
                enrichService: enrichService,
                sessionTracker: sessionTracker,
                permissionService: permissionService,
                router: router,
                telemetryEmitter: telemetryEmitter,
                networkMonitor: networkMonitor,
                pushSubscriptionService: pushSubscriptionService,
                apnsTokenService: apnsTokenService,
                ackService: ackService,
                categoryManager: categoryManager,
                badgeService: badgeService
            )
            self.internals = internals
            return BootstrapResult(installed: internals, alreadyInitialized: false)
        }
    }

    /// `push-fcm-ios` retry queue is persisted under its own UserDefaults
    /// suite so a credentials wipe doesn't clear pending ACKs. Mirrors
    /// Android `ACK_PENDING_PREFS_NAME`.
    private static let ackPendingSuiteName = "swanPendingAcks"

    private func makeInternalsForTests(
        appId: String,
        baseUrl: String,
        store: CredentialsStore,
        client: HttpTransport,
        appGroup: String? = nil
    ) -> BootstrapResult {
        return lock.sync {
            if let existing = self.internals {
                return BootstrapResult(installed: existing, alreadyInitialized: true)
            }
            let service = DeviceRegistrationService(
                appId: appId, baseUrl: baseUrl, client: client, store: store
            )
            // Tests get an isolated in-memory KV for the session manager
            // so the suite-backed UserDefaults state doesn't leak between
            // test cases.
            let sessionManager = SessionManager(store: InMemoryKeyValueStore())
            // offline-queue: tests use an InMemoryQueueStore so they don't
            // touch the user's Application Support directory.
            let tracker = EventTracker(
                appId: appId,
                baseUrl: baseUrl,
                sdkVersion: Swan.sdkVersion,
                client: client,
                credentialsStore: store,
                sessionManager: sessionManager,
                queueStore: InMemoryQueueStore()
            )
            // Do NOT start() in tests — periodic timer would race the
            // test's explicit `await flush()`. Tests opt into start()
            // explicitly when needed.
            let enrichService = EnrichProfileService(
                appId: appId,
                baseUrl: baseUrl,
                client: client,
                credentialsStore: store
            )
            // Same wiring order as production: telemetryEmitter early so
            // the identify/logout services can plumb its identifier-
            // changed listener. Reuse the Swan-owned shared instance so
            // that listeners subscribed before `initializeForTests(...)`
            // still receive events — mirrors the production bootstrap.
            // Direct ivar read — already inside `lock.sync`.
            let telemetryEmitter = _sharedTelemetryEmitter
            let identifyService = IdentifyService(
                appId: appId,
                baseUrl: baseUrl,
                sdkVersion: Swan.sdkVersion,
                client: client,
                credentialsStore: store,
                sessionManager: sessionManager,
                configProvider: { [weak tracker] in tracker?.currentConfig() ?? EventConfig() },
                identifierChangedListener: { [weak telemetryEmitter] cdid in
                    telemetryEmitter?.emit(SwanIdentifierChangedPayload(
                        swanIdentifier: cdid, source: .identify
                    ))
                }
            )
            let logoutService = LogoutService(
                appId: appId,
                baseUrl: baseUrl,
                sdkVersion: Swan.sdkVersion,
                client: client,
                credentialsStore: store,
                sessionManager: sessionManager,
                configProvider: { [weak tracker] in tracker?.currentConfig() ?? EventConfig() },
                flushPendingEvents: { [weak tracker, weak enrichService] in
                    _ = await tracker?.flush()
                    await enrichService?.flush()
                },
                identifierChangedListener: { [weak telemetryEmitter] anonCDID in
                    telemetryEmitter?.emit(SwanIdentifierChangedPayload(
                        swanIdentifier: anonCDID, source: .logout
                    ))
                }
            )
            // notification-permission / deeplink / telemetry wiring —
            // test variant. Network monitor is NOT started — tests drive
            // simulateTransition() directly.
            let permissionService = NotificationPermissionService()
            let router = NotificationRouter()
            // Drain pre-init router-listener buffer — identical to the
            // production `makeInternalsIfNeeded` path (line 1814) so
            // listeners subscribed before `initializeForTests(...)`
            // attach to the freshly-created router. The PR #67 pre-init
            // fix originally only patched the production path; carrying
            // it into the test seam closes a parallel gap that would
            // silently drop pre-init subscriptions in any unit test
            // that exercises the listener flow.
            for entry in pendingNotificationOpenedListeners {
                let unsub = router.addOpenedListener(entry.listener)
                drainedNotificationOpenedUnsubscribes[entry.id] = unsub
            }
            for entry in pendingDeepLinkOpenedListeners {
                let unsub = router.addDeepLinkOpenedListener(entry.listener)
                drainedDeepLinkOpenedUnsubscribes[entry.id] = unsub
            }
            pendingNotificationOpenedListeners.removeAll()
            pendingDeepLinkOpenedListeners.removeAll()
            let networkMonitor = NetworkStateMonitor(emitter: telemetryEmitter)
            // push-fcm-ios + delivery-click-ack — same wiring as the
            // production path, but with in-memory KV stores so per-test
            // state stays isolated. Test webhook URL is a stable
            // placeholder; tests inject their own transport when they
            // need to assert wire bytes.
            let pushSubscriptionService = PushSubscriptionService(
                appId: appId,
                baseUrl: baseUrl,
                sdkVersion: Swan.sdkVersion,
                client: client,
                credentialsStore: store
            )
            let apnsTokenService = APNsTokenService(
                subscriptionService: pushSubscriptionService,
                credentialsStore: store
            )
            let ackPendingStore = PendingAckStore(store: InMemoryKeyValueStore())
            let ackService = NotificationAckService(
                appId: appId,
                credentialsStore: store,
                transport: DirectAckTransport(
                    webhookUrl: "https://webhook-dev.swan.cx/api/mobile-push-tracking",
                    underlying: client
                ),
                pendingStore: ackPendingStore
            )
            // delivery-click-ack — same wiring as production. See Bug 18
            // note in `makeInternalsIfNeeded` for rationale.
            router.setClickAckHook { [weak ackService] messageId in
                _ = ackService?.sendClicked(messageId)
            }
            // notification-channels + badge-count: test variant uses
            // in-memory state so per-test runs stay isolated. The
            // category manager uses a no-op host (no UN side effect).
            let categoryManager = NotificationCategoryManager(
                host: TestNotificationCategoryHost()
            )
            let badgeService = BadgeService(
                store: InMemoryKeyValueStore(),
                host: TestBadgeHost()
            )
            let internals = Internals(
                appId: appId,
                baseUrl: baseUrl,
                appGroup: appGroup,
                store: store,
                service: service,
                sessionManager: sessionManager,
                tracker: tracker,
                identifyService: identifyService,
                logoutService: logoutService,
                enrichService: enrichService,
                sessionTracker: nil,
                permissionService: permissionService,
                router: router,
                telemetryEmitter: telemetryEmitter,
                networkMonitor: networkMonitor,
                pushSubscriptionService: pushSubscriptionService,
                apnsTokenService: apnsTokenService,
                ackService: ackService,
                categoryManager: categoryManager,
                badgeService: badgeService
            )
            self.internals = internals
            return BootstrapResult(installed: internals, alreadyInitialized: false)
        }
    }

    /// Test-only ``NotificationCategoryHost`` — no-op. Production path
    /// uses ``SystemNotificationCategoryHost``.
    private final class TestNotificationCategoryHost: NotificationCategoryHost, @unchecked Sendable {
        func setCategories(_ categories: Set<NotificationCategoryDescriptor>) { /* no-op */ }
        func currentCategoryIdentifiers() -> Set<String> { return [] }
    }

    /// Test-only ``BadgeHost`` — no-op. Production path uses
    /// ``SystemBadgeHost``.
    private final class TestBadgeHost: BadgeHost, @unchecked Sendable {
        func setBadge(_ count: Int) { /* no-op */ }
        func currentBadge() -> Int { return 0 }
    }

    private func updateState(_ newValue: RegistrationState) {
        // self-telemetry — emit deviceRegistered / deviceRegistrationFailed
        // out-of-band so the listener fan-out doesn't run under our lock.
        // Snapshot the emitter under the lock; emit outside.
        let snapshot: TelemetryEmitter? = lock.sync {
            self.stateValue = newValue
            for (_, c) in self.continuations {
                c.yield(newValue)
            }
            return self.internals?.telemetryEmitter
        }
        guard let emitter = snapshot else { return }
        switch newValue {
        case .registered(let deviceId, let generatedCDID):
            emitter.emit(TelemetryEvent.DeviceRegisteredPayload(
                deviceId: deviceId,
                generatedCDID: generatedCDID
            ))
        case .failed(let error):
            emitter.emit(TelemetryEvent.DeviceRegistrationFailedPayload(error: error))
        case .uninitialized, .registering:
            break
        }
    }

    // MARK: - notification-permission

    /// Programmatically prompt the user for notification permission.
    ///
    /// **Capability:** `notification-permission` (Phase 1.11).
    ///
    /// Spec:
    ///   - `spec/api/push.yaml` `/sdk/requestNotificationPermission`
    ///   - `conformance/scenarios/notification-permission.feature` —
    ///     scenario "requestNotificationPermission on iOS triggers APNs
    ///     authorization"
    ///
    /// Mirrors RN's `requestNotificationPermission()` (src/index.tsx:3942)
    /// and Android's ``Swan/requestNotificationPermission(activity:)``.
    ///
    /// Returns `true` if the user granted (or had already granted)
    /// authorization, `false` otherwise. Emits exactly one
    /// `permissionGranted` / `permissionDenied` lifecycle event via
    /// ``addPushPermissionListener(_:)`` listeners on every call.
    ///
    /// No-op (returns `false`) if ``initialize(appId:baseUrl:config:)``
    /// hasn't been called — same posture as the other capability APIs.
    @discardableResult
    public func requestNotificationPermission() async -> Bool {
        guard let service = lock.sync(execute: { internals?.permissionService }) else {
            SwanLogger.warn("Swan.requestNotificationPermission(): called before initialize(); returning false.")
            return false
        }
        return await service.requestNotificationPermission()
    }

    /// Read the current OS notification-permission state.
    ///
    /// **Capability:** `notification-permission` (Phase 1.11).
    ///
    /// Returns `true` when `UNAuthorizationStatus` is `.authorized` or
    /// `.provisional`. `.notDetermined`, `.denied`, `.ephemeral` all map
    /// to `false`. Does NOT prompt the user.
    ///
    /// Returns `false` if ``initialize(appId:baseUrl:config:)`` hasn't
    /// been called.
    public func hasNotificationPermission() async -> Bool {
        guard let service = lock.sync(execute: { internals?.permissionService }) else {
            return false
        }
        return await service.hasNotificationPermission()
    }

    /// Subscribe to permission-decision lifecycle events.
    ///
    /// **Capability:** `notification-permission` (Phase 1.11).
    ///
    /// Mirrors RN's `pushService.on('permissionGranted' |
    /// 'permissionDenied')` (src/index.tsx:586).
    ///
    /// The returned closure removes the listener. Listeners receive
    /// ``PushLifecycleEvent/permissionGranted`` or
    /// ``PushLifecycleEvent/permissionDenied`` on every
    /// ``requestNotificationPermission()`` resolution.
    ///
    /// Returns a no-op closure if ``initialize(appId:baseUrl:config:)``
    /// hasn't been called — calls register a queued listener path is
    /// NOT modeled here (mirrors the identify/logout pre-init posture).
    @discardableResult
    public func addPushPermissionListener(
        _ listener: @escaping @Sendable (PushLifecycleEvent) -> Void
    ) -> () -> Void {
        guard let service = lock.sync(execute: { internals?.permissionService }) else {
            return {}
        }
        return service.addListener(listener)
    }

    // MARK: - deeplink-url / cold-start-routing / deeplink-key-value

    /// Subscribe to NOTIFICATION_OPENED events — fired when the user
    /// taps a Swan notification.
    ///
    /// **Capabilities:** `deeplink-url`, `cold-start-routing`,
    /// `deeplink-key-value`.
    ///
    /// Spec:
    ///   - `spec/api/push.yaml#NotificationOpenedPayload`
    ///   - `conformance/scenarios/deeplink-url.feature`
    ///   - `conformance/scenarios/cold-start-routing.feature`
    ///
    /// Mirrors RN's `addListener('NOTIFICATION_OPENED', cb)`
    /// (src/index.tsx:781). The returned closure removes the listener.
    ///
    /// If the SDK has already buffered a tap (cold-start race), the
    /// listener fires SYNCHRONOUSLY on registration with the buffered
    /// payload — see ``NotificationRouter`` doc.
    ///
    /// Returns a no-op closure if ``initialize(appId:baseUrl:config:)``
    /// hasn't been called.
    @discardableResult
    public func addNotificationOpenedListener(
        _ listener: @escaping @Sendable (NotificationOpenedPayload) -> Void
    ) -> () -> Void {
        let id = UUID()
        // Single critical section: decide buffer-vs-direct-add
        // atomically so a concurrent bootstrap drain can't sneak in
        // between "is router nil?" and "append to pending".
        let directRouter: NotificationRouter? = lock.sync {
            if let router = internals?.router {
                return router
            }
            self.pendingNotificationOpenedListeners.append(
                PendingOpenedEntry(id: id, listener: listener)
            )
            return nil
        }
        if let router = directRouter {
            return router.addOpenedListener(listener)
        }
        // Pre-init buffered: return an unsubscribe closure that works
        // in both still-buffered and already-drained states.
        return { [weak self] in
            guard let self = self else { return }
            let drainedUnsub: (() -> Void)? = self.lock.sync {
                self.pendingNotificationOpenedListeners.removeAll { $0.id == id }
                return self.drainedNotificationOpenedUnsubscribes.removeValue(forKey: id)
            }
            drainedUnsub?()
        }
    }

    /// Subscribe to DEEP_LINK_OPENED events — the unified deep-link
    /// surface (push source only in v1; email / sms / direct in v2).
    ///
    /// **Capabilities:** `deeplink-url`, `deeplink-key-value`.
    ///
    /// Spec: `spec/api/push.yaml#DeepLinkOpenedPayload`.
    ///
    /// Every NOTIFICATION_OPENED tap ALSO fires DEEP_LINK_OPENED with
    /// `source=push` (RN parity, src/index.tsx:847-852). Host apps that
    /// want source-agnostic routing subscribe here.
    @discardableResult
    public func addDeepLinkOpenedListener(
        _ listener: @escaping @Sendable (DeepLinkOpenedPayload) -> Void
    ) -> () -> Void {
        let id = UUID()
        let directRouter: NotificationRouter? = lock.sync {
            if let router = internals?.router {
                return router
            }
            self.pendingDeepLinkOpenedListeners.append(
                PendingDeepLinkEntry(id: id, listener: listener)
            )
            return nil
        }
        if let router = directRouter {
            return router.addDeepLinkOpenedListener(listener)
        }
        return { [weak self] in
            guard let self = self else { return }
            let drainedUnsub: (() -> Void)? = self.lock.sync {
                self.pendingDeepLinkOpenedListeners.removeAll { $0.id == id }
                return self.drainedDeepLinkOpenedUnsubscribes.removeValue(forKey: id)
            }
            drainedUnsub?()
        }
    }

    /// Process an APNs `userInfo` dictionary tap and deliver the parsed
    /// payload to host-app listeners.
    ///
    /// **Capabilities:** `deeplink-url`, `cold-start-routing`,
    /// `deeplink-key-value`.
    ///
    /// iOS host apps call this from
    /// `UNUserNotificationCenterDelegate.userNotificationCenter(_:
    /// didReceive:withCompletionHandler:)` with
    /// `response.notification.request.content.userInfo` (the APNs
    /// `userInfo` shape). The SDK adapts it to the canonical
    /// `[String: String]` data map, parses, and emits.
    ///
    /// - Parameters:
    ///   - userInfo: The standard APNs userInfo dictionary.
    ///   - messageId: The FCM / APNs message identifier used for
    ///     30s-TTL dedup. Pass `response.notification.request.identifier`
    ///     or a server-stamped equivalent. `nil` / empty bypasses dedup
    ///     (RN parity — every RN call-site is gated on `messageId &&`).
    public func handleNotificationUserInfo(
        _ userInfo: [AnyHashable: Any],
        messageId: String? = nil
    ) {
        var data = UserInfoAdapter.toDataMap(userInfo)
        // Carousel per-item routing — capability `push-carousel-manual`,
        // `push-carousel-auto`. When the user taps a specific carousel
        // slide inside the host-app-owned `UNNotificationContentExtension`,
        // the extension persists the resolved per-item route into the
        // SDK's App Group (`swanTemplateClickData` key) and triggers
        // `extensionContext.performNotificationDefaultAction()`, which
        // fires `didReceive` on the host's `UNUserNotificationCenterDelegate`.
        // The userInfo we receive here is the OUTER push payload — it
        // carries `defaultRoute` but NOT the tapped item's route.
        // Override `data["route"]` with the per-item route so the
        // listener fires with the right destination. Mirrors RN's
        // `checkPendingCarouselClick` (src/index.tsx:5610-5680).
        // Resolve a fallback messageId from the payload itself when the
        // caller didn't pass one (some hosts only pass `userInfo`, not
        // the explicit identifier). Without this fallback the click-data
        // gate in `consumePendingCarouselClick` collapses to the "no
        // messageId provided — consume unconditionally" branch, which
        // means a stale tap from a previous notification could route the
        // current one. CodeRabbit 2026-05-18.
        let resolvedMessageId = messageId.flatMap { $0.isEmpty ? nil : $0 }
            ?? data["messageId"]
            ?? data["gcm.message_id"]
        if let clickRoute = consumePendingCarouselClick(forMessageId: resolvedMessageId) {
            data["route"] = clickRoute
        }
        handleNotificationTap(data, messageId: resolvedMessageId)
    }

    /// Read + clear the carousel-tap click data the host-app's
    /// Notification Content Extension persisted into the configured
    /// App Group. Returns the resolved per-item route, or `nil` when
    /// there's no pending click data (or it's stale / belongs to a
    /// different messageId).
    ///
    /// Internal — called once per `handleNotificationUserInfo`. Read +
    /// write are atomic via `UserDefaults` snapshot, and the key is
    /// cleared on read so a single tap can't fire two listener
    /// emissions (RN parity — `_lastCarouselClickHandledAt` dedup).
    private func consumePendingCarouselClick(forMessageId messageId: String?) -> String? {
        let appGroup = lock.sync { internals?.appGroup }
        guard let appGroup = appGroup, !appGroup.isEmpty else { return nil }
        guard let defaults = UserDefaults(suiteName: appGroup) else { return nil }
        guard let jsonString = defaults.string(forKey: "swanTemplateClickData") else { return nil }
        // Parse FIRST, validate match SECOND, clear LAST. The pre-fix
        // version cleared on read, but if iOS delivered two taps out of
        // order (notification B's didReceive fires before A's), the
        // mid-check would return nil for B AFTER already wiping A's
        // click data — losing the per-item route for A's eventual tap.
        // Caught 2026-05-18 — Bug 13 in the senior-engineer audit.
        guard let data = jsonString.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Corrupted entry — wipe it so we don't sticky-route every
            // subsequent notification with a parse failure.
            defaults.removeObject(forKey: "swanTemplateClickData")
            return nil
        }
        // Stale-data guard: discard click data older than 60 seconds.
        if let ts = dict["timestamp"] as? TimeInterval,
           Date().timeIntervalSince1970 - ts > 60 {
            // Stale — wipe so future taps don't see it.
            defaults.removeObject(forKey: "swanTemplateClickData")
            return nil
        }
        // If the messageId is set, gate on it. CRUCIAL: do NOT clear
        // the click data when the messageId doesn't match — the legit
        // tap for that messageId might arrive shortly after.
        if let mid = messageId, !mid.isEmpty,
           let clickMid = dict["messageId"] as? String,
           !clickMid.isEmpty,
           clickMid != mid {
            return nil   // leave data in place for its rightful tap
        }
        // Match (or no messageId provided) — consume it.
        let route = (dict["route"] as? String) ?? ""
        defaults.removeObject(forKey: "swanTemplateClickData")
        return route.isEmpty ? nil : route
    }

    /// Process a notification tap from a pre-flattened `[String: String]`
    /// data map. Public for hosts that already extract FCM `data`
    /// upstream (e.g. background message handlers).
    ///
    /// **Capabilities:** `deeplink-url`, `cold-start-routing`,
    /// `deeplink-key-value`.
    ///
    /// - Parameters:
    ///   - data: The flattened `data` payload — same shape FCM enforces
    ///     on the wire.
    ///   - messageId: Optional dedup key (see
    ///     ``handleNotificationUserInfo(_:messageId:)``).
    public func handleNotificationTap(
        _ data: [String: String],
        messageId: String? = nil
    ) {
        guard let router = lock.sync(execute: { internals?.router }) else {
            SwanLogger.warn("Swan.handleNotificationTap(): called before initialize(); tap dropped.")
            return
        }
        // Resolve messageId from the explicit parameter OR the payload —
        // hosts that forward via `handleNotificationUserInfo(_:)` typically
        // don't pass it explicitly, expecting the SDK to extract from
        // `gcm.message_id` / `messageId` on the data map. Without this
        // resolution, cold-start delivery (where launchOptions[.remoteNotification]
        // AND didReceive(response:) both forward the same payload) fires
        // the opened listener TWICE — the dedup gate in
        // `ProcessedClickStore` requires a non-nil messageId to work.
        let resolvedId: String? = {
            if let id = messageId, !id.isEmpty { return id }
            if let id = data["gcm.message_id"] ?? data["messageId"], !id.isEmpty { return id }
            return nil
        }()
        if let id = resolvedId {
            SwanLogger.info("[SwanSDK] Foreground notification received: \(id)")
        }
        let payload = PushPayloadParser.buildPayload(data)
        router.emitOpened(payload, messageId: resolvedId)
    }

    // MARK: - cold-start-routing (delivery-click-ack seam)

    /// Install (or remove, via `nil`) the click-ACK seam used by the
    /// (future) `delivery-click-ack` capability.
    ///
    /// **Capability:** `cold-start-routing`.
    ///
    /// Internal — A20 (`push-fcm` + `delivery-click-ack`) wires this to
    /// the HTTP ACK transport once that port lands. Host apps do NOT
    /// call this directly; left `internal` so a future public surface
    /// can be designed once the ACK transport ships.
    func setClickAckHook(_ hook: (@Sendable (String) -> Void)?) {
        guard let router = lock.sync(execute: { internals?.router }) else {
            return
        }
        router.setClickAckHook(hook)
    }

    // MARK: - notification-channels

    /// Returns the default Swan notification channel id — the
    /// cross-platform constant `"swan_notifications"`.
    ///
    /// **Capability:** `notification-channels` (Phase 1.18 iOS port).
    ///
    /// Spec:
    ///   - `spec/api/push.yaml` `/sdk/getNotificationChannelId`
    ///   - `conformance/scenarios/notification-channels.feature` —
    ///     scenario "Default channel id is the documented constant"
    ///
    /// # RN bug fix (#13)
    ///
    /// RN returns `this.appId` here (src/index.tsx:4043-4045) — the
    /// tenant id, NOT a channel id. The conformance scenario explicitly
    /// asserts the result MUST equal `"swan_notifications"`. The iOS
    /// port returns the documented constant.
    ///
    /// # iOS semantics
    ///
    /// On iOS this is the default `UNNotificationCategory.identifier`
    /// the SDK registers at init. Host apps can stamp this on
    /// `UNMutableNotificationContent.categoryIdentifier` to route a
    /// locally-built notification to the Swan default category. **iOS
    /// does NOT use this for sound or importance** — those are set
    /// per-notification on `UNMutableNotificationContent`. See
    /// ``NotificationCategoryManager`` for the iOS-vs-Android
    /// conceptual divergence.
    ///
    /// Returns `"swan_notifications"` whether or not
    /// ``initialize(appId:baseUrl:config:)`` has been called — the
    /// constant is a stable property of the SDK, not initialization
    /// state.
    public func getNotificationChannelId() -> String {
        return NotificationCategoryManager.defaultCategoryId
    }

    /// Cross-platform parity hook — register a `UNNotificationCategory`
    /// with the given id.
    ///
    /// **Capability:** `notification-channels` (Phase 1.18 iOS port).
    ///
    /// Spec:
    ///   - `spec/api/push.yaml` `/sdk/createNotificationChannel`
    ///   - `conformance/scenarios/notification-channels.feature` —
    ///     scenario "createNotificationChannel is a no-op on iOS"
    ///
    /// # iOS semantics (CRITICAL divergence from Android)
    ///
    /// On Android this creates an OS-level `NotificationChannel` with
    /// importance + sound. **On iOS this is effectively a no-op for the
    /// predefined ids** — the SDK already registers them at init. For a
    /// custom id, the manager registers a `UNNotificationCategory` so
    /// host apps can route locally-built notifications to it. The
    /// `importance` and `soundName` arguments are IGNORED on iOS — iOS
    /// sets those per-notification, not per-category.
    ///
    /// Provided for parity so cross-platform host code compiles
    /// unchanged. Conformance scenario asserts "the call resolves
    /// without throwing and no platform side-effect occurs" for the
    /// predefined case.
    ///
    /// - Parameters:
    ///   - id: Stable category id (e.g. `"swan_transactional"`).
    ///   - name: User-visible name. Not surfaced by the OS on iOS;
    ///           preserved for diagnostics + cross-platform parity.
    ///   - importance: IGNORED on iOS. Provided for parity.
    ///   - soundName: IGNORED on iOS — sound is per-notification.
    /// - Returns: The id on success, `nil` if ``initialize(appId:baseUrl:config:)``
    ///   hasn't been called.
    @discardableResult
    public func createNotificationChannel(
        id: String,
        name: String = "General Notifications",
        importance: Int = 4,
        soundName: String? = nil
    ) -> String? {
        _ = importance
        _ = soundName
        guard let manager = lock.sync(execute: { internals?.categoryManager }) else {
            SwanLogger.warn("Swan.createNotificationChannel(): called before initialize(); returning nil.")
            return nil
        }
        return manager.createCategory(NotificationCategoryDescriptor(id: id, name: name))
    }

    /// Cross-platform parity hook — remove a `UNNotificationCategory`.
    ///
    /// **Capability:** `notification-channels` (Phase 1.18 iOS port).
    ///
    /// Refuses to delete predefined ids (load-bearing for backend
    /// routing — mirrors Android Phase 1.18 protection). Returns
    /// `true` when a custom category was removed, `false` otherwise
    /// (predefined id, unknown id, pre-init).
    @discardableResult
    public func deleteNotificationChannel(id: String) -> Bool {
        guard let manager = lock.sync(execute: { internals?.categoryManager }) else {
            return false
        }
        return manager.deleteCategory(id)
    }

    // MARK: - custom-notification-sound
    //
    // The resolver itself is internal-only. The rendering layer
    // (`Internal/Push/Templates/` package — owned by A22) calls
    // `NotificationSoundResolver.resolveSoundForPayload(...)` when
    // building a `UNMutableNotificationContent` from an inbound payload.
    //
    // There's no public API for it. RN parity: src/index.tsx exposes
    // no public sound-resolution method either — the SDK handles it
    // internally when processing payloads.
    //
    // The conformance scenarios target the resolver directly via
    // `NotificationSoundResolverTests`. Wire-format byte-equivalence is
    // pinned by `test_resolve_custom_name_yields_Custom_verbatim` (v2.7
    // RN regression: name preserved as-is).

    // MARK: - badge-count

    /// Read the current app-icon badge count.
    ///
    /// **Capability:** `badge-count` (Phase 1.18 iOS port).
    ///
    /// Spec:
    ///   - `spec/api/push.yaml` `/sdk/getBadgeCount`
    ///   - `conformance/scenarios/badge-count.feature`
    ///
    /// Mirrors RN's `getBadgeCount()` (src/index.tsx:4050-4067).
    ///
    /// Returns the last value set via ``setBadgeCount(_:)``. Initial
    /// value is 0. Persisted across process restarts.
    ///
    /// Returns 0 if ``initialize(appId:baseUrl:config:)`` hasn't been
    /// called.
    public func getBadgeCount() -> Int {
        guard let badge = lock.sync(execute: { internals?.badgeService }) else {
            return 0
        }
        return badge.getCount()
    }

    /// Write the app-icon badge count.
    ///
    /// **Capability:** `badge-count` (Phase 1.18 iOS port).
    ///
    /// Spec:
    ///   - `spec/api/push.yaml` `/sdk/setBadgeCount`
    ///   - `conformance/scenarios/badge-count.feature` — set / get /
    ///     clear / silent push invariant.
    ///
    /// Mirrors RN's `setBadgeCount(count)` (src/index.tsx:4072-4087).
    ///
    /// Passes the count to:
    ///   - iOS 16+: `UNUserNotificationCenter.current().setBadgeCount(_:)`
    ///   - iOS 13–15: `UIApplication.shared.applicationIconBadgeNumber`
    ///
    /// Negative counts are clamped to 0. Passing `0` clears the badge.
    ///
    /// Returns `true` on success. Returns `false` only if
    /// ``initialize(appId:baseUrl:config:)`` hasn't been called.
    ///
    /// # RN bug catch (#14)
    ///
    /// RN's `messaging().setBadge()` / `getBadge()` are iOS-only on
    /// `@react-native-firebase/messaging`. On iOS the calls work; on
    /// Android they silently no-op. iOS port behavior is unchanged from
    /// RN (uses the native APIs directly so no FirebaseMessaging dep is
    /// required). The Android port FIXES the bug separately.
    @discardableResult
    public func setBadgeCount(_ count: Int) -> Bool {
        guard let badge = lock.sync(execute: { internals?.badgeService }) else {
            SwanLogger.warn("Swan.setBadgeCount(): called before initialize(); returning false.")
            return false
        }
        return badge.setCount(count)
    }

    // MARK: - self-telemetry

    /// Subscribe to ``TelemetryEvent/deviceRegistered(_:)`` lifecycle
    /// events.
    ///
    /// **Capability:** `self-telemetry` (Phase 1.14).
    ///
    /// Spec: `conformance/scenarios/self-telemetry.feature` — scenario
    /// "SDK emits deviceRegistered when registration succeeds".
    ///
    /// Mirrors RN's `addListener('deviceRegistered', cb)`
    /// (src/index.tsx:431). The returned closure removes the listener.
    ///
    /// **Late-subscribe semantics**: If device registration has already
    /// resolved by the time you subscribe, the listener fires
    /// SYNCHRONOUSLY with the buffered payload (one-shot, single-slot).
    /// RN drops late subscribers on the floor; this catches them — see
    /// ``TelemetryEmitter`` doc.
    @discardableResult
    public func addDeviceRegisteredListener(
        _ listener: @escaping @Sendable (TelemetryEvent.DeviceRegisteredPayload) -> Void
    ) -> () -> Void {
        let emitter = sharedTelemetryEmitter
        return emitter.addDeviceRegisteredListener(listener)
    }

    /// Subscribe to ``TelemetryEvent/deviceRegistrationFailed(_:)``
    /// lifecycle events.
    ///
    /// **Capability:** `self-telemetry` (Phase 1.14).
    ///
    /// Same buffering semantics as
    /// ``addDeviceRegisteredListener(_:)``.
    @discardableResult
    public func addDeviceRegistrationFailedListener(
        _ listener: @escaping @Sendable (TelemetryEvent.DeviceRegistrationFailedPayload) -> Void
    ) -> () -> Void {
        let emitter = sharedTelemetryEmitter
        return emitter.addDeviceRegistrationFailedListener(listener)
    }

    /// Subscribe to ``TelemetryEvent/networkStateChanged(_:)`` lifecycle
    /// events.
    ///
    /// **Capability:** `self-telemetry` (Phase 1.14).
    ///
    /// Spec: `conformance/scenarios/self-telemetry.feature` — scenario
    /// "SDK emits networkStateChanged on connectivity transitions".
    ///
    /// Fires on every offline⇄online transition (edge-triggered — no
    /// duplicate emissions for steady-state online callbacks). Catches
    /// an RN bug: RN promises this event but never wires it (see
    /// ``TelemetryEvent`` doc).
    @discardableResult
    public func addNetworkStateChangedListener(
        _ listener: @escaping @Sendable (TelemetryEvent.NetworkStateChangedPayload) -> Void
    ) -> () -> Void {
        let emitter = sharedTelemetryEmitter
        return emitter.addNetworkStateChangedListener(listener)
    }

    /// Subscribe to ``PushTokenRegisteredPayload`` emissions — fires on
    /// every successful APNs-token registration with the Swan backend,
    /// including the initial registration. To observe only token
    /// rotations (not the initial registration), use
    /// ``addPushTokenRefreshListener(_:)``.
    ///
    /// Returns a no-arg closure that unregisters the listener.
    @discardableResult
    public func addPushTokenRegisteredListener(
        _ listener: @escaping @Sendable (PushTokenRegisteredPayload) -> Void
    ) -> () -> Void {
        let emitter = sharedTelemetryEmitter
        return emitter.addPushTokenRegisteredListener(listener)
    }

    /// Subscribe to ``PushTokenRegistrationFailedPayload`` emissions —
    /// fires when the SDK's POST to `/device/push-subscription` fails.
    /// The SDK keeps queueing events locally and retries on the next
    /// ``registerAPNsToken(_:)`` call.
    @discardableResult
    public func addPushTokenRegistrationFailedListener(
        _ listener: @escaping @Sendable (PushTokenRegistrationFailedPayload) -> Void
    ) -> () -> Void {
        let emitter = sharedTelemetryEmitter
        return emitter.addPushTokenRegistrationFailedListener(listener)
    }

    /// Subscribe to ``PushNotificationReceivedPayload`` emissions —
    /// fires when a foreground push arrives, BEFORE the SDK posts the
    /// system notification. Use for in-app banners, analytics
    /// instrumentation, or to override default display.
    ///
    /// Background / killed-state pushes route through the tap path
    /// (``addNotificationOpenedListener(_:)``) without firing this
    /// surface. Stream event — no buffer.
    @discardableResult
    public func addPushNotificationReceivedListener(
        _ listener: @escaping @Sendable (PushNotificationReceivedPayload) -> Void
    ) -> () -> Void {
        let emitter = sharedTelemetryEmitter
        return emitter.addPushNotificationReceivedListener(listener)
    }

    /// Subscribe to ``PushTokenRefreshPayload`` emissions — fires only
    /// when a re-registration replaces a previous token. The initial
    /// registration does NOT fire this surface (use
    /// ``addPushTokenRegisteredListener(_:)`` to observe every
    /// registration, refresh or otherwise).
    @discardableResult
    public func addPushTokenRefreshListener(
        _ listener: @escaping @Sendable (PushTokenRefreshPayload) -> Void
    ) -> () -> Void {
        let emitter = sharedTelemetryEmitter
        return emitter.addPushTokenRefreshListener(listener)
    }

    /// Subscribe to ``SwanIdentifierChangedPayload`` emissions — the Swan
    /// identifier transitioning to a new logged-in CDID (identify), back
    /// to anonymous (logout), or to a different profile (login, planned
    /// for v2).
    ///
    /// Stream event — no buffer. Late subscribers only see future
    /// transitions. To observe the current identifier on subscribe, read
    /// ``swanIdentifier``.
    ///
    /// Returns a no-arg closure that unregisters the listener — capture
    /// and call it when the subscriber goes out of scope.
    @discardableResult
    public func addSwanIdentifierChangedListener(
        _ listener: @escaping @Sendable (SwanIdentifierChangedPayload) -> Void
    ) -> () -> Void {
        let emitter = sharedTelemetryEmitter
        return emitter.addIdentifierChangedListener(listener)
    }

    // MARK: - push-template-basic

    // The basic-template renderer lives on the standalone public
    // Templates enum rather than the Swan singleton because
    // Notification Service Extensions run in a separate process from
    // the host app and cannot share the singleton's state. See
    // Templates.renderContent(...) for the NSE entrypoint;
    // platforms/ios/EXTENSIONS.md for the host integration walkthrough.

    // MARK: - push-carousel-manual

    // Carousel payload parsing + first-image-from-first-item NSE
    // rendering. Host-app Notification Content Extensions consume the
    // typed Templates.CarouselPayloadPublic via Templates.parseCarousel(_:)
    // for full swipeable UX. Per-image deep linking flows through the
    // existing handleNotificationTap(_:messageId:) surface with the
    // route overridden per-tap.

    // MARK: - push-carousel-auto

    // v1 ships identical NSE behavior to push-carousel-manual (first
    // image only). True auto-rotation requires a Notification Content
    // Extension; the desired interval is surfaced via
    // Templates.CarouselPayloadPublic.intervalMs.

    // MARK: - Test seams (notification-permission / routing / telemetry)

    /// Test-only — exposes the live ``NotificationRouter`` so unit
    /// tests can drive `emitOpened` directly without round-tripping
    /// through `UserInfoAdapter`.
    func notificationRouterForTests() -> NotificationRouter? {
        return lock.sync { internals?.router }
    }

    /// Test-only — exposes the live ``TelemetryEmitter`` for direct
    /// emission assertions.
    func telemetryEmitterForTests() -> TelemetryEmitter? {
        return lock.sync { internals?.telemetryEmitter }
    }

    /// Test-only — exposes the live ``NetworkStateMonitor`` so tests
    /// can drive `simulateTransition(...)` without an `NWPathMonitor`.
    func networkStateMonitorForTests() -> NetworkStateMonitor? {
        return lock.sync { internals?.networkMonitor }
    }

    /// Test-only — exposes the live
    /// ``NotificationPermissionService`` so tests can inject a fake
    /// gate. The factory variants of ``initializeForTests(...)`` don't
    /// thread a gate through, so unit tests for the permission service
    /// itself construct the service stand-alone instead of routing
    /// through this seam.
    func permissionServiceForTests() -> NotificationPermissionService? {
        return lock.sync { internals?.permissionService }
    }

    /// Test-only — exposes the live ``NotificationCategoryManager`` so
    /// integration tests can assert that the predefined-five-categories
    /// set was registered on init.
    func categoryManagerForTests() -> NotificationCategoryManager? {
        return lock.sync { internals?.categoryManager }
    }

    /// Test-only — exposes the live ``BadgeService`` so integration
    /// tests can assert badge-count read/write through the public API.
    func badgeServiceForTests() -> BadgeService? {
        return lock.sync { internals?.badgeService }
    }
}
