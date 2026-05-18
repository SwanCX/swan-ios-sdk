import Foundation

/// Objective-C compatibility surface for ``Swan``.
///
/// Pure-Swift host apps should use ``Swan`` directly. Mixed-language
/// host apps that need to invoke the SDK from Obj-C call sites use
/// this class — it mirrors the most-used operations through a
/// `@objcMembers` `NSObject` surface so they're visible to the Obj-C
/// runtime.
///
/// **Coverage:** initialization, identity, event tracking, super-
/// properties. Listener subscription, async / await methods (push
/// permission, async login), structured config types (`SwanConfig`),
/// and the typed `SwanEvents` helpers are Swift-only — call those
/// from a small Swift bridging file in your Obj-C host app.
///
/// **Usage from Objective-C:**
/// ```objc
/// #import <SwanSDK/SwanSDK-Swift.h>
///
/// [[SwanObjC shared] initializeWithAppId:@"your-app-id"];
/// [[SwanObjC shared] identifyWithIdentifier:@"user-123"
///                                  attributes:@{ @"email": @"jane@example.com" }];
/// [[SwanObjC shared] trackWithName:@"clickedHero"
///                       attributes:@{ @"variant": @"A" }];
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

    // MARK: - Identity

    /// Identify the current user. Empty / nil attributes are accepted.
    public func identify(identifier: String, attributes: [String: Any]?) {
        Swan.shared.identify(identifier: identifier, attributes: attributes ?? [:])
    }

    /// Convenience overload — identify without attributes.
    public func identify(identifier: String) {
        Swan.shared.identify(identifier: identifier, attributes: [String: Any]())
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

    // MARK: - Push

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

    /// Returns true when an APNs token is registered with the Swan
    /// backend.
    public func isPushReady() -> Bool {
        return Swan.shared.isPushReady()
    }

    /// Enable / disable internal SDK debug logs at runtime.
    public func enableLogs(_ enabled: Bool) {
        Swan.shared.enableLogs(enabled)
    }
}
