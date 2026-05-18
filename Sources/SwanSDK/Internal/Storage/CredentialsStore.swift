import Foundation

/// In-memory representation of Swan device credentials.
///
/// Mirrors RN's `DeviceCredentials` (state/DeviceStateMachine.ts) with
/// one deliberate omission:
///   - `first_seen_at` — fabricated by RN client-side, not on the wire.
///     Per spec, native ports OMIT this.
///
/// ## `pushNotificationToken` + `ackUrl`
///
/// Owned by the `push-fcm-ios` + `delivery-click-ack` capabilities.
/// - `pushNotificationToken`: the hex-encoded APNs device token the SDK
///   last successfully POSTed to `/device/push-subscription`. Persisted so
///   a re-subscribe with the same token short-circuits the wire call.
///   Mirrors Android's `CredentialsStore.pushNotificationToken`.
/// - `ackUrl`: the env-resolved `/mobile-push-tracking` URL. Persisted so
///   `Swan.shared.ackPushDeliveredColdStart(_:)` can POST without
///   re-resolving env from `SwanConfig`. Mirrors Android `ackUrl`.
struct SwanCredentials: Equatable {
    let appId: String
    let deviceId: String
    let generatedCDID: String
    let currentCDID: String?
    /// External identifier the host app passed to `Swan.shared.identify(...)`.
    /// `nil` until the first successful identify call. Used for the
    /// identify-login idempotent fast-path. NOT on the wire — local-only.
    let identifier: String?
    /// Hex-encoded APNs device token last synced with backend. `nil` until
    /// `Swan.shared.registerAPNsToken(_:)` has resolved a successful POST.
    /// Owned by `push-fcm-ios`. NOT on the wire as part of device-register
    /// — Swan's push pipeline reads it from `/device/push-subscription`.
    let pushNotificationToken: String?
    /// Env-resolved webhook URL for `/mobile-push-tracking`. Owned by
    /// `delivery-click-ack`. Persisted so the cold-start sender can read it
    /// straight out of UserDefaults without an SDK bootstrap.
    let ackUrl: String?

    init(
        appId: String,
        deviceId: String,
        generatedCDID: String,
        currentCDID: String? = nil,
        identifier: String? = nil,
        pushNotificationToken: String? = nil,
        ackUrl: String? = nil
    ) {
        self.appId = appId
        self.deviceId = deviceId
        self.generatedCDID = generatedCDID
        self.currentCDID = currentCDID
        self.identifier = identifier
        self.pushNotificationToken = pushNotificationToken
        self.ackUrl = ackUrl
    }

    /// Functional-style "with" mutator — Swift lacks Kotlin's data-class
    /// `copy`. Each parameter is a double-optional: `.none` (the default)
    /// means "keep the existing value"; `.some(nil)` means "clear it";
    /// `.some("x")` means "set it to x". Slightly more verbose than
    /// Kotlin's `copy(...)` but unambiguous.
    func withFields(
        currentCDID: String?? = .none,
        identifier: String?? = .none,
        pushNotificationToken: String?? = .none,
        ackUrl: String?? = .none
    ) -> SwanCredentials {
        // `if case let` unwraps the outer Optional; the inner String? is
        // the actual replacement (either Some(value) or None=clear).
        let nextCurrent: String?
        if case let .some(v) = currentCDID { nextCurrent = v } else { nextCurrent = self.currentCDID }
        let nextIdentifier: String?
        if case let .some(v) = identifier { nextIdentifier = v } else { nextIdentifier = self.identifier }
        let nextPushToken: String?
        if case let .some(v) = pushNotificationToken { nextPushToken = v } else { nextPushToken = self.pushNotificationToken }
        let nextAckUrl: String?
        if case let .some(v) = ackUrl { nextAckUrl = v } else { nextAckUrl = self.ackUrl }
        return SwanCredentials(
            appId: appId,
            deviceId: deviceId,
            generatedCDID: generatedCDID,
            currentCDID: nextCurrent,
            identifier: nextIdentifier,
            pushNotificationToken: nextPushToken,
            ackUrl: nextAckUrl
        )
    }
}

/// Persists Swan device credentials.
///
/// Spec: `spec/behavior/device-registration.yaml` storage_key
/// "swanCredentials".
///
/// v1 uses UserDefaults via [KeyValueStore]. Persistence schema is
/// internal — RN's wire format is the contract, NOT its persistence
/// (`spec/wire/RN-PARITY.md`). RN base64-wraps the JSON in AsyncStorage;
/// we don't. Native ports get to use native idioms.
final class CredentialsStore {

    private let store: KeyValueStore

    init(store: KeyValueStore) {
        self.store = store
    }

    /// Returns nil until `save(_:)` has been called at least once with a
    /// fully-populated tuple. If any required field is missing
    /// (tampered prefs, corrupt suite), treats it as "no credentials"
    /// rather than partial-state.
    func read() -> SwanCredentials? {
        guard
            let deviceId = store.getString(Keys.deviceId),
            let generatedCDID = store.getString(Keys.generatedCDID),
            let appId = store.getString(Keys.appId)
        else {
            return nil
        }
        return SwanCredentials(
            appId: appId,
            deviceId: deviceId,
            generatedCDID: generatedCDID,
            currentCDID: store.getString(Keys.currentCDID),
            identifier: store.getString(Keys.identifier),
            pushNotificationToken: store.getString(Keys.pushNotificationToken),
            ackUrl: store.getString(Keys.ackUrl)
        )
    }

    func save(_ credentials: SwanCredentials) {
        store.putString(Keys.appId, credentials.appId)
        store.putString(Keys.deviceId, credentials.deviceId)
        store.putString(Keys.generatedCDID, credentials.generatedCDID)
        store.putString(Keys.currentCDID, credentials.currentCDID)
        store.putString(Keys.identifier, credentials.identifier)
        store.putString(Keys.pushNotificationToken, credentials.pushNotificationToken)
        store.putString(Keys.ackUrl, credentials.ackUrl)
    }

    func clear() {
        store.clear()
    }

    enum Keys {
        // The suite-name itself (the UserDefaults suite) carries the
        // RN parity key "swanCredentials"; these are per-field
        // sub-keys. (RN keeps everything under one JSON string in
        // AsyncStorage; native ports break it apart.)
        static let appId = "appId"
        static let deviceId = "deviceId"
        static let generatedCDID = "generatedCDID"
        static let currentCDID = "currentCDID"
        static let identifier = "identifier"
        /// `push-fcm-ios`: persisted last-synced APNs hex token.
        static let pushNotificationToken = "pushNotificationToken"
        /// `delivery-click-ack`: persisted env-resolved webhook URL.
        static let ackUrl = "ackUrl"
    }

    /// Default per-process UserDefaults suite name. Used when no App
    /// Group is configured. NSE process cannot read this — set
    /// ``SwanConfig/appGroup`` to enable cross-process credential
    /// sharing for killed-state delivery ACK.
    static let suiteName = "swanCredentials"

    /// Pick the right suite name for a given `SwanConfig.appGroup`.
    /// When `appGroup` is set, use it directly so the suite is shared
    /// with the Notification Service Extension process. Otherwise fall
    /// back to the per-process suite.
    static func suiteName(forAppGroup appGroup: String?) -> String {
        if let group = appGroup, !group.isEmpty {
            return group
        }
        return suiteName
    }

    /// One-time migration: when a host app upgrades and starts setting
    /// `SwanConfig.appGroup`, copy any existing credentials from the
    /// per-process suite into the App Group suite so the host doesn't
    /// have to re-register the device.
    ///
    /// Idempotent: if the App Group suite already has credentials,
    /// this is a no-op. If the per-process suite has none, this is a
    /// no-op. Otherwise it copies and clears the per-process suite.
    static func migrateIfNeeded(appGroup: String?) {
        guard let appGroup = appGroup, !appGroup.isEmpty else { return }
        let appGroupStore = CredentialsStore(
            store: UserDefaultsKeyValueStore(suiteName: appGroup)
        )
        if appGroupStore.read() != nil {
            return
        }
        let perProcessStore = CredentialsStore(
            store: UserDefaultsKeyValueStore(suiteName: suiteName)
        )
        guard let existing = perProcessStore.read() else { return }
        appGroupStore.save(existing)
        perProcessStore.clear()
        SwanLogger.debug(
            "CredentialsStore.migrateIfNeeded: copied credentials to App Group \"\(appGroup)\""
        )
    }
}
