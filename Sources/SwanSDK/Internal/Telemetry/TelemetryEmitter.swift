import Foundation

/// Dispatches SDK self-telemetry lifecycle events to host-app listeners.
///
/// **Capability:** `self-telemetry` (Phase 1.14 iOS port).
///
/// Spec: `conformance/scenarios/self-telemetry.feature`.
///
/// # RN parity
///
/// Mirrors RN's `this.listeners: Record<string, EventCallback[]>` +
/// `this.emit()` surface (src/index.tsx:211, :821), and the Android
/// ``TelemetryEmitter``. Each event surface has its own list because
/// public APIs are typed on Swift (associated-value enums) — a single
/// `[String: [(Any) -> Void]]` map would erase the type info and force
/// `Any` casts on the listener side.
///
/// # Buffering semantics (DIVERGES from RN, intentionally)
///
/// - `deviceRegistered` and `deviceRegistrationFailed` are ONE-SHOT events:
///   exactly one of the two fires per init cycle. If no listener is
///   registered when the event resolves, the payload is buffered in a
///   single slot and delivered synchronously on the next subscribe.
///   This catches a class of RN bug where host apps that subscribe
///   after a fast cached-credentials path miss the event entirely (RN
///   drops late subscribers — src/index.tsx:431). Same pattern as
///   ``NotificationRouter`` for deeplink-url.
///
/// - `networkStateChanged` is a STREAM event: no buffer, late
///   subscribers only see future transitions. Consistent with
///   `NWPathMonitor` semantics — host apps that need the current
///   state on subscribe can read it via
///   ``NetworkStateMonitor/currentIsOnline`` (not buffered here because
///   it would be a stale read, not a real transition).
///
/// # Threading
///
/// Listeners are dispatched synchronously on the thread that called
/// `emit`. The production wire (in ``Swan``) emits from the SDK's
/// `Task.detached` scope for registration events and from a
/// `NWPathMonitor` queue for network events. Host apps that touch UI in
/// their listeners must marshal themselves.
///
/// Buffer drain order: listener exceptions cannot be caught in Swift
/// without `do/try` plumbing (closures aren't `throws`); a fatal error
/// in a listener will crash the SDK task, same posture as RN's
/// `[...eventListeners].forEach`.
internal final class TelemetryEmitter: @unchecked Sendable {

    typealias DeviceRegisteredListener = @Sendable (TelemetryEvent.DeviceRegisteredPayload) -> Void
    typealias DeviceRegistrationFailedListener = @Sendable (TelemetryEvent.DeviceRegistrationFailedPayload) -> Void
    typealias NetworkStateChangedListener = @Sendable (TelemetryEvent.NetworkStateChangedPayload) -> Void
    typealias IdentifierChangedListener = @Sendable (SwanIdentifierChangedPayload) -> Void
    typealias PushTokenRegisteredListener = @Sendable (PushTokenRegisteredPayload) -> Void
    typealias PushTokenRegistrationFailedListener = @Sendable (PushTokenRegistrationFailedPayload) -> Void
    typealias PushTokenRefreshListener = @Sendable (PushTokenRefreshPayload) -> Void
    typealias PushNotificationReceivedListener = @Sendable (PushNotificationReceivedPayload) -> Void

    private let lock = NSLock()

    private var deviceRegisteredListeners: [DeviceRegisteredListener] = []
    private var deviceRegistrationFailedListeners: [DeviceRegistrationFailedListener] = []
    private var networkStateChangedListeners: [NetworkStateChangedListener] = []
    private var identifierChangedListeners: [IdentifierChangedListener] = []
    private var pushTokenRegisteredListeners: [PushTokenRegisteredListener] = []
    private var pushTokenRegistrationFailedListeners: [PushTokenRegistrationFailedListener] = []
    private var pushTokenRefreshListeners: [PushTokenRefreshListener] = []
    private var pushNotificationReceivedListeners: [PushNotificationReceivedListener] = []

    // Single-slot buffers for the one-shot events.
    private var bufferedDeviceRegistered: TelemetryEvent.DeviceRegisteredPayload?
    private var bufferedDeviceRegistrationFailed: TelemetryEvent.DeviceRegistrationFailedPayload?

    // MARK: - deviceRegistered

    @discardableResult
    func addDeviceRegisteredListener(
        _ listener: @escaping DeviceRegisteredListener
    ) -> () -> Void {
        // Drain the buffer BEFORE adding so a concurrent emit() can't
        // double-fire. Same pattern as Android `TelemetryEmitter`.
        lock.lock()
        let buffered = bufferedDeviceRegistered
        bufferedDeviceRegistered = nil
        deviceRegisteredListeners.append(listener)
        lock.unlock()
        if let buffered = buffered {
            listener(buffered)
        }
        return { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            let target = unsafeBitCast(listener as AnyObject, to: Int.self)
            if let idx = self.deviceRegisteredListeners.firstIndex(where: {
                unsafeBitCast($0 as AnyObject, to: Int.self) == target
            }) {
                self.deviceRegisteredListeners.remove(at: idx)
            }
            self.lock.unlock()
        }
    }

    func emit(_ event: TelemetryEvent.DeviceRegisteredPayload) {
        lock.lock()
        let snapshot = deviceRegisteredListeners
        if snapshot.isEmpty {
            bufferedDeviceRegistered = event
            lock.unlock()
            return
        }
        bufferedDeviceRegistered = nil
        lock.unlock()
        for listener in snapshot {
            listener(event)
        }
    }

    // MARK: - deviceRegistrationFailed

    @discardableResult
    func addDeviceRegistrationFailedListener(
        _ listener: @escaping DeviceRegistrationFailedListener
    ) -> () -> Void {
        lock.lock()
        let buffered = bufferedDeviceRegistrationFailed
        bufferedDeviceRegistrationFailed = nil
        deviceRegistrationFailedListeners.append(listener)
        lock.unlock()
        if let buffered = buffered {
            listener(buffered)
        }
        return { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            let target = unsafeBitCast(listener as AnyObject, to: Int.self)
            if let idx = self.deviceRegistrationFailedListeners.firstIndex(where: {
                unsafeBitCast($0 as AnyObject, to: Int.self) == target
            }) {
                self.deviceRegistrationFailedListeners.remove(at: idx)
            }
            self.lock.unlock()
        }
    }

    func emit(_ event: TelemetryEvent.DeviceRegistrationFailedPayload) {
        lock.lock()
        let snapshot = deviceRegistrationFailedListeners
        if snapshot.isEmpty {
            bufferedDeviceRegistrationFailed = event
            lock.unlock()
            return
        }
        bufferedDeviceRegistrationFailed = nil
        lock.unlock()
        for listener in snapshot {
            listener(event)
        }
    }

    // MARK: - networkStateChanged

    @discardableResult
    func addNetworkStateChangedListener(
        _ listener: @escaping NetworkStateChangedListener
    ) -> () -> Void {
        lock.lock()
        networkStateChangedListeners.append(listener)
        lock.unlock()
        return { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            let target = unsafeBitCast(listener as AnyObject, to: Int.self)
            if let idx = self.networkStateChangedListeners.firstIndex(where: {
                unsafeBitCast($0 as AnyObject, to: Int.self) == target
            }) {
                self.networkStateChangedListeners.remove(at: idx)
            }
            self.lock.unlock()
        }
    }

    func emit(_ event: TelemetryEvent.NetworkStateChangedPayload) {
        // No buffer — see class doc. Late subscribers see future transitions.
        lock.lock()
        let snapshot = networkStateChangedListeners
        lock.unlock()
        for listener in snapshot {
            listener(event)
        }
    }

    // MARK: - identifierChanged

    /// Subscribe to ``SwanIdentifierChangedPayload`` emissions. Stream
    /// event (no buffer) — late subscribers only see future identify /
    /// logout / profile-switch transitions. Mirrors
    /// `networkStateChanged` posture: a stale "previous identifier"
    /// replay would mislead a navigation reset into firing for an
    /// already-completed transition.
    @discardableResult
    func addIdentifierChangedListener(
        _ listener: @escaping IdentifierChangedListener
    ) -> () -> Void {
        lock.lock()
        identifierChangedListeners.append(listener)
        lock.unlock()
        return { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            let target = unsafeBitCast(listener as AnyObject, to: Int.self)
            if let idx = self.identifierChangedListeners.firstIndex(where: {
                unsafeBitCast($0 as AnyObject, to: Int.self) == target
            }) {
                self.identifierChangedListeners.remove(at: idx)
            }
            self.lock.unlock()
        }
    }

    func emit(_ event: SwanIdentifierChangedPayload) {
        lock.lock()
        let snapshot = identifierChangedListeners
        lock.unlock()
        for listener in snapshot {
            listener(event)
        }
    }

    // MARK: - pushTokenRegistered / pushTokenRegistrationFailed / pushTokenRefresh

    @discardableResult
    func addPushTokenRegisteredListener(
        _ listener: @escaping PushTokenRegisteredListener
    ) -> () -> Void {
        lock.lock()
        pushTokenRegisteredListeners.append(listener)
        lock.unlock()
        return { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            let target = unsafeBitCast(listener as AnyObject, to: Int.self)
            if let idx = self.pushTokenRegisteredListeners.firstIndex(where: {
                unsafeBitCast($0 as AnyObject, to: Int.self) == target
            }) {
                self.pushTokenRegisteredListeners.remove(at: idx)
            }
            self.lock.unlock()
        }
    }

    func emit(_ event: PushTokenRegisteredPayload) {
        lock.lock()
        let snapshot = pushTokenRegisteredListeners
        lock.unlock()
        for listener in snapshot { listener(event) }
    }

    @discardableResult
    func addPushTokenRegistrationFailedListener(
        _ listener: @escaping PushTokenRegistrationFailedListener
    ) -> () -> Void {
        lock.lock()
        pushTokenRegistrationFailedListeners.append(listener)
        lock.unlock()
        return { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            let target = unsafeBitCast(listener as AnyObject, to: Int.self)
            if let idx = self.pushTokenRegistrationFailedListeners.firstIndex(where: {
                unsafeBitCast($0 as AnyObject, to: Int.self) == target
            }) {
                self.pushTokenRegistrationFailedListeners.remove(at: idx)
            }
            self.lock.unlock()
        }
    }

    func emit(_ event: PushTokenRegistrationFailedPayload) {
        lock.lock()
        let snapshot = pushTokenRegistrationFailedListeners
        lock.unlock()
        for listener in snapshot { listener(event) }
    }

    @discardableResult
    func addPushTokenRefreshListener(
        _ listener: @escaping PushTokenRefreshListener
    ) -> () -> Void {
        lock.lock()
        pushTokenRefreshListeners.append(listener)
        lock.unlock()
        return { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            let target = unsafeBitCast(listener as AnyObject, to: Int.self)
            if let idx = self.pushTokenRefreshListeners.firstIndex(where: {
                unsafeBitCast($0 as AnyObject, to: Int.self) == target
            }) {
                self.pushTokenRefreshListeners.remove(at: idx)
            }
            self.lock.unlock()
        }
    }

    func emit(_ event: PushTokenRefreshPayload) {
        lock.lock()
        let snapshot = pushTokenRefreshListeners
        lock.unlock()
        for listener in snapshot { listener(event) }
    }

    // MARK: - pushNotificationReceived

    @discardableResult
    func addPushNotificationReceivedListener(
        _ listener: @escaping PushNotificationReceivedListener
    ) -> () -> Void {
        lock.lock()
        pushNotificationReceivedListeners.append(listener)
        lock.unlock()
        return { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            let target = unsafeBitCast(listener as AnyObject, to: Int.self)
            if let idx = self.pushNotificationReceivedListeners.firstIndex(where: {
                unsafeBitCast($0 as AnyObject, to: Int.self) == target
            }) {
                self.pushNotificationReceivedListeners.remove(at: idx)
            }
            self.lock.unlock()
        }
    }

    func emit(_ event: PushNotificationReceivedPayload) {
        lock.lock()
        let snapshot = pushNotificationReceivedListeners
        lock.unlock()
        for listener in snapshot { listener(event) }
    }

    // MARK: - Test seams

    func clearForTests() {
        lock.lock()
        deviceRegisteredListeners.removeAll()
        deviceRegistrationFailedListeners.removeAll()
        networkStateChangedListeners.removeAll()
        identifierChangedListeners.removeAll()
        pushTokenRegisteredListeners.removeAll()
        pushTokenRegistrationFailedListeners.removeAll()
        pushTokenRefreshListeners.removeAll()
        pushNotificationReceivedListeners.removeAll()
        bufferedDeviceRegistered = nil
        bufferedDeviceRegistrationFailed = nil
        lock.unlock()
    }

    func bufferedDeviceRegisteredForTests() -> TelemetryEvent.DeviceRegisteredPayload? {
        lock.lock(); defer { lock.unlock() }
        return bufferedDeviceRegistered
    }

    func bufferedDeviceRegistrationFailedForTests() -> TelemetryEvent.DeviceRegistrationFailedPayload? {
        lock.lock(); defer { lock.unlock() }
        return bufferedDeviceRegistrationFailed
    }
}
