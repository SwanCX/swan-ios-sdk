import Foundation

/// Objective-C compatibility surface for ``Swan``.
///
/// Pure-Swift host apps should use ``Swan`` directly. Mixed-language
/// host apps that need to invoke the SDK from Obj-C call sites use
/// this class — it mirrors the customer-facing operations through a
/// `@objcMembers` `NSObject` surface so they're visible to the Obj-C
/// runtime.
///
/// **Coverage:** initialization, identity (sync + async `login`), event
/// tracking, super-properties, device info, location, push setup
/// (APNs token registration, deep-link + notification user-info
/// handling, click + delivery ACKs, notification channels, badge
/// count), permission requests (`requestNotificationPermission`,
/// `hasNotificationPermission`, `isPushEnabled` — all via completion
/// handlers), `addInitializedListener`.
///
/// **Swift-only:** listeners that emit typed Swift-struct payloads
/// (`addNotificationOpenedListener`, `addDeepLinkOpenedListener`,
/// `addPushNotificationReceivedListener`, `addSwanIdentifierChangedListener`,
/// `addDeviceRegisteredListener` and the rest of the telemetry-payload
/// listeners), `SwanConfig` struct, `AsyncStream`-typed properties
/// (`registrationStateStream`), the typed `SwanEvents` helpers. To
/// consume any of these from Obj-C, write a thin Swift bridging file
/// that adapts the payload type into NSObjects you can hand to your
/// Obj-C call site.
///
/// **Async methods:** Obj-C cannot call Swift `async` methods directly.
/// Each async method on ``Swan`` is exposed here as a
/// `*WithCompletion:` variant that internally awaits and then invokes
/// the completion handler on the main actor.
///
/// **Usage from Objective-C:**
/// ```objc
/// #import <SwanSDK/SwanSDK-Swift.h>
///
/// [[SwanObjC shared] initializeWithAppId:@"your-app-id"];
/// [[SwanObjC shared] identifyWithIdentifier:@"user-123"
///                                attributes:@{ @"email": @"jane@example.com" }];
/// [[SwanObjC shared] trackWithName:@"clickedHero"
///                       attributes:@{ @"variant": @"A" }];
/// [[SwanObjC shared] requestNotificationPermissionWithCompletion:^(BOOL granted) {
///     NSLog(@"granted=%d", granted);
/// }];
/// [[SwanObjC shared] logout];
/// ```
@objcMembers public final class SwanObjC: NSObject {

    /// Shared singleton. Same backing instance as ``Swan/shared``.
    public static let shared: SwanObjC = SwanObjC()

    private override init() { super.init() }

    // MARK: - Initialization

    /// Initialize the SDK with default config (production endpoint,
    /// debug logs off, push opt-in, location opt-out).
    public func initialize(appId: String) {
        Swan.shared.initialize(appId: appId)
    }

    /// Initialize with explicit production / debug flags. Pass `false`
    /// for `production` to target the dev/staging endpoint.
    public func initialize(
        appId: String,
        debug: Bool,
        production: Bool
    ) {
        let config = SwanConfig(debug: debug, production: production)
        Swan.shared.initialize(appId: appId, config: config)
    }

    /// Register a callback that fires once ``Swan/initialize(appId:)``
    /// has resolved. Fires immediately if init already completed.
    public func addInitializedListener(_ callback: @escaping () -> Void) {
        Swan.shared.addInitializedListener(callback)
    }

    // MARK: - Identity

    /// Identify the current user. Empty / nil attributes are accepted.
    public func identify(identifier: String, attributes: [String: Any]?) {
        Swan.shared.identify(identifier: identifier, attributes: attributes ?? [:])
    }

    /// Convenience overload — identify without attributes.
    public func identify(identifier: String) {
        Swan.shared.identify(identifier: identifier, attributes: [String: Any]())
    }

    /// Async login with completion handler. Flushes the anonymous queue
    /// before the profile switch so prior events aren't attributed to
    /// the new identity. Completion is invoked on the main thread.
    ///
    /// The result dictionary contains `cdid` (NSString, may be `NSNull`)
    /// and `profileSwitched` (NSNumber bool). Pass `nil` for
    /// `attributes` if you have none.
    public func loginWithCompletion(
        identifier: String,
        attributes: [String: Any]?,
        completion: @escaping ([String: Any]) -> Void
    ) {
        Task {
            let result = await Swan.shared.login(
                identifier: identifier,
                attributes: attributes ?? [:]
            )
            let dict: [String: Any] = [
                "cdid": result.cdid as Any,
                "profileSwitched": result.profileSwitched
            ]
            await MainActor.run { completion(dict) }
        }
    }

    /// Log out the current user — reverts to anonymous identity.
    public func logout() {
        Swan.shared.logout()
    }

    /// Update profile attributes on the currently-active identity
    /// (anonymous or identified). Pass an NSDictionary of caller
    /// values.
    public func enrichProfile(_ attributes: [String: Any]) {
        Swan.shared.enrichProfile(attributes)
    }

    /// Current Swan identifier, or nil if registration hasn't
    /// completed. Read-only.
    public var swanIdentifier: String? {
        return Swan.shared.swanIdentifier
    }

    /// Current session id (a stable id for one foreground session,
    /// rolling over after 20 minutes of inactivity). `nil` before
    /// the first event of the current session.
    public func getCurrentSessionId() -> String? {
        return Swan.shared.getCurrentSessionId()
    }

    // MARK: - Device info

    /// Snapshot of the SDK's view of the host device, plus the persisted
    /// device-registration identifiers, plus the last
    /// ``Swan/updateLocation(latitude:longitude:accuracy:)`` payload if any.
    /// Returned as `NSDictionary` so Obj-C callers don't need to bridge
    /// the ``SwanDeviceInfo`` Swift struct.
    ///
    /// Keys: `platform` (NSString, always `"ios"`), `osModal`,
    /// `deviceModal`, `deviceBrand` (NSString), and optionally
    /// `deviceId`, `generatedCDID`, `currentCDID`, `identifier` (NSString),
    /// `location` (nested NSDictionary with `latitude`, `longitude`,
    /// `timestamp` and optionally `accuracy`).
    public func getDeviceInfo() -> [String: Any] {
        let info = Swan.shared.getDeviceInfo()
        var dict: [String: Any] = [
            "platform": info.platform,
            "osModal": info.osModal,
            "deviceModal": info.deviceModal,
            "deviceBrand": info.deviceBrand
        ]
        if let deviceId = info.deviceId { dict["deviceId"] = deviceId }
        if let generatedCDID = info.generatedCDID { dict["generatedCDID"] = generatedCDID }
        if let currentCDID = info.currentCDID { dict["currentCDID"] = currentCDID }
        if let identifier = info.identifier { dict["identifier"] = identifier }
        if let location = info.location {
            var locDict: [String: Any] = [
                "latitude": location.latitude,
                "longitude": location.longitude,
                "timestamp": location.timestamp
            ]
            if let accuracy = location.accuracy { locDict["accuracy"] = accuracy }
            dict["location"] = locDict
        }
        return dict
    }

    // MARK: - Location

    /// Host-app-supplied device location. The SDK does not acquire
    /// location itself — pass coordinates obtained via Core Location
    /// or any other source. `accuracy` is in meters (pass a negative
    /// number to omit).
    public func updateLocation(
        latitude: Double,
        longitude: Double,
        accuracy: Double
    ) {
        let acc: Double? = accuracy >= 0 ? accuracy : nil
        Swan.shared.updateLocation(latitude: latitude, longitude: longitude, accuracy: acc)
    }

    /// `YES` when the SDK's location-enrichment slot is configured. iOS
    /// SDK gates location auto-enrichment on the customer explicitly
    /// opting in; until then events ingest without a `location` field.
    public func isLocationEnabled() -> Bool {
        return Swan.shared.isLocationEnabled()
    }

    // MARK: - Event tracking

    /// Track a custom event with optional attributes.
    public func track(name: String, attributes: [String: Any]?) {
        Swan.shared.track(name, attributes: attributes ?? [:])
    }

    /// Track a custom event with no attributes.
    public func track(name: String) {
        Swan.shared.track(name, attributes: [String: Any]())
    }

    /// Track a screen view.
    public func screen(name: String, attributes: [String: Any]?) {
        Swan.shared.screen(name, attributes: attributes ?? [:])
    }

    /// Force-flush the event queue. Normally the SDK flushes on a
    /// schedule — use this for tests or controlled exits.
    public func flush() {
        Swan.shared.flush()
    }

    /// Current depth of the offline event queue. Useful for diagnostics
    /// and pre-shutdown drains.
    public func getQueueSize() -> Int {
        return Swan.shared.getQueueSize()
    }

    // MARK: - Super-properties

    public func setCountry(_ country: String) {
        Swan.shared.setCountry(country)
    }

    public func setCurrency(_ currency: String) {
        Swan.shared.setCurrency(currency)
    }

    public func setBusinessUnit(_ businessUnit: String) {
        Swan.shared.setBusinessUnit(businessUnit)
    }

    public func setCurrentScreenName(_ name: String) {
        Swan.shared.setCurrentScreenName(name)
    }

    // MARK: - Push: APNs token

    /// Register an APNs device token. Pass the raw `Data` from the
    /// `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`
    /// callback.
    public func registerAPNsToken(_ token: Data) {
        Swan.shared.registerAPNsToken(token)
    }

    /// Hex-encoded APNs token (alternative input form — most host apps
    /// already convert the Data to hex for logging).
    public func registerAPNsTokenHex(_ hexToken: String) {
        Swan.shared.registerAPNsTokenHex(hexToken)
    }

    /// Returns the current Swan-tracked push token, or nil if none
    /// has been registered.
    public func getPushToken() -> String? {
        return Swan.shared.getPushToken()
    }

    /// Returns `YES` when an APNs token is registered with the Swan
    /// backend.
    public func isPushReady() -> Bool {
        return Swan.shared.isPushReady()
    }

    /// Async check that both notification permission is granted AND an
    /// APNs token is registered. Completion is invoked on the main
    /// thread.
    public func isPushEnabledWithCompletion(_ completion: @escaping (Bool) -> Void) {
        Task {
            let enabled = await Swan.shared.isPushEnabled()
            await MainActor.run { completion(enabled) }
        }
    }

    /// Opt the device out of further push notifications. Removes the
    /// APNs token from the Swan backend so subsequent campaigns skip
    /// this device until ``registerAPNsToken(_:)`` is called again.
    public func unsubscribePush() {
        Swan.shared.unsubscribePush()
    }

    // MARK: - Push: handling

    /// Pass through APNs `userInfo` dictionaries the host app receives
    /// from `application(_:didReceiveRemoteNotification:)` or the
    /// background callback — used for silent / data-only pushes that
    /// don't surface a UI. Returns immediately.
    public func handlePushNotificationUserInfo(_ userInfo: [AnyHashable: Any]) {
        Swan.shared.handlePushNotificationUserInfo(userInfo)
    }

    /// Pass through the `userInfo` dictionary the host app received
    /// from `UNUserNotificationCenter` when the user taps a Swan-
    /// originated push. The SDK extracts the deep link, queues a click
    /// ACK, and dispatches to any registered notification-opened
    /// listeners.
    public func handleNotificationUserInfo(
        _ userInfo: [AnyHashable: Any],
        messageId: String?
    ) {
        Swan.shared.handleNotificationUserInfo(userInfo, messageId: messageId)
    }

    /// Convenience overload — handle the user-info without an explicit
    /// message-id override.
    public func handleNotificationUserInfo(_ userInfo: [AnyHashable: Any]) {
        Swan.shared.handleNotificationUserInfo(userInfo)
    }

    /// Pass through a pre-extracted notification data dictionary (string
    /// keys + values). Use this when your host app already parsed the
    /// userInfo on its own.
    public func handleNotificationTap(
        _ data: [String: String],
        messageId: String?
    ) {
        Swan.shared.handleNotificationTap(data, messageId: messageId)
    }

    /// Convenience overload — handle the notification tap without an
    /// explicit message-id override.
    public func handleNotificationTap(_ data: [String: String]) {
        Swan.shared.handleNotificationTap(data)
    }

    /// Handle a deep-link URL (custom-scheme or universal-link). The
    /// SDK routes the URL to any registered deep-link-opened listeners
    /// and tracks the routing event. Returns `YES` if the SDK
    /// recognised and routed the URL, `NO` otherwise (host app should
    /// fall back to its own handling).
    public func handleDeepLink(_ url: String) -> Bool {
        return Swan.shared.handleDeepLink(url)
    }

    // MARK: - Push: ACKs

    /// Acknowledge a push notification as delivered to the device.
    /// Normally the SDK does this automatically — call this only from
    /// a notification-service extension that needs to ACK before the
    /// host app gets a chance to run.
    public func ackPushDelivered(_ messageId: String) {
        Swan.shared.ackPushDelivered(messageId)
    }

    /// Acknowledge a push notification as clicked. Normally
    /// ``handleNotificationUserInfo(_:messageId:)`` ACKs automatically;
    /// call this directly if you've parsed the userInfo yourself.
    /// `type` and `linkId` are optional click metadata.
    public func ackPushClicked(
        _ messageId: String,
        type: String?,
        linkId: String?
    ) {
        Swan.shared.ackPushClicked(messageId, type: type, linkId: linkId)
    }

    /// Force-flush queued ACK events. Normally the SDK auto-flushes on
    /// app foreground.
    public func flushPendingAcks() {
        Swan.shared.flushPendingAcks()
    }

    // MARK: - Push: permissions

    /// Request notification permission from the OS. The completion
    /// handler is invoked on the main thread with the user's decision
    /// (`YES` = granted, `NO` = denied or already determined).
    public func requestNotificationPermissionWithCompletion(_ completion: @escaping (Bool) -> Void) {
        Task {
            let granted = await Swan.shared.requestNotificationPermission()
            await MainActor.run { completion(granted) }
        }
    }

    /// Check the OS-reported notification-permission state. Completion
    /// is invoked on the main thread.
    public func hasNotificationPermissionWithCompletion(_ completion: @escaping (Bool) -> Void) {
        Task {
            let granted = await Swan.shared.hasNotificationPermission()
            await MainActor.run { completion(granted) }
        }
    }

    // MARK: - Push: notification categories (cross-platform parity)

    /// Default Swan notification-category id. iOS notification
    /// categories are the per-platform equivalent of Android channels —
    /// host apps that need a custom action or sound register a
    /// category via ``createNotificationChannel(id:name:importance:soundName:)``.
    public func getNotificationChannelId() -> String {
        return Swan.shared.getNotificationChannelId()
    }

    /// Register a `UNNotificationCategory` so a Swan campaign can
    /// reference it by id. `importance` is accepted for cross-platform
    /// parity but is ignored on iOS (the OS handles importance). Pass
    /// an empty string for `soundName` to use the default sound.
    public func createNotificationChannel(
        id: String,
        name: String,
        importance: Int,
        soundName: String
    ) {
        let sound: String? = soundName.isEmpty ? nil : soundName
        Swan.shared.createNotificationChannel(
            id: id,
            name: name,
            importance: importance,
            soundName: sound
        )
    }

    /// Unregister a previously-created notification category.
    /// Returns `YES` if a category with that id was removed.
    @discardableResult
    public func deleteNotificationChannel(id: String) -> Bool {
        return Swan.shared.deleteNotificationChannel(id: id)
    }

    // MARK: - Push: badge

    /// Current app icon badge count, as last set via Swan or read from
    /// the OS.
    public func getBadgeCount() -> Int {
        return Swan.shared.getBadgeCount()
    }

    /// Set the app icon badge count. Returns `YES` if the OS accepted
    /// the change.
    @discardableResult
    public func setBadgeCount(_ count: Int) -> Bool {
        return Swan.shared.setBadgeCount(count)
    }

    // MARK: - Debug

    /// Enable / disable internal SDK debug logs at runtime.
    public func enableLogs(_ enabled: Bool) {
        Swan.shared.enableLogs(enabled)
    }
}
