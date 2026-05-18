import Foundation

/// Thin abstraction over a string→string KV store, so the credentials
/// layer can be unit-tested at pure-Swift level (no UserDefaults host
/// app required) while the production path uses `UserDefaults`.
///
/// Marked `internal` — the public SDK surface knows nothing about this.
protocol KeyValueStore: AnyObject {
    func getString(_ key: String) -> String?
    func putString(_ key: String, _ value: String?)
    func clear()
}

/// UserDefaults-backed production store.
///
/// Why UserDefaults (not Keychain): the credentials we persist
/// (`deviceId`, `generatedCDID`, `currentCDID`, `identifier`) are
/// anonymous identifiers already in the clear over the wire on every
/// request — moving them to Keychain offers no security gain. When the
/// host app configures an App Group via ``SwanConfig/appGroup``, the
/// same identifiers are shared cross-process with the Notification
/// Service Extension so it can fire killed-state delivery ACKs.
final class UserDefaultsKeyValueStore: KeyValueStore {
    private let defaults: UserDefaults
    private let keyPrefix: String

    /// `suiteName` is either:
    ///   - a host-app-supplied App Group identifier
    ///     (e.g. `"group.com.example.app"`), in which case the suite
    ///     is shared cross-process with any Notification Service
    ///     Extension that opens the same suite, or
    ///   - an in-app namespace string like `"swanCredentials"`, in
    ///     which case the suite lives inside the app sandbox and the
    ///     NSE process cannot see it.
    ///
    /// `UserDefaults(suiteName:)` returns nil for invalid names
    /// (e.g. the bundle id of the current app). When that happens we
    /// fall back to `.standard` with a prefix so the SDK still works,
    /// but emit a warning if the suite name looks like an App Group
    /// identifier — almost always a missing-entitlement misconfig.
    init(suiteName: String) {
        if let suite = UserDefaults(suiteName: suiteName) {
            self.defaults = suite
            self.keyPrefix = ""
        } else {
            if suiteName.hasPrefix("group.") {
                SwanLogger.warn(
                    "UserDefaultsKeyValueStore: UserDefaults(suiteName: \"\(suiteName)\") " +
                    "returned nil. The App Groups entitlement is missing or doesn't include " +
                    "this identifier. Falling back to .standard — NSE cross-process credential " +
                    "sharing will not work."
                )
            }
            self.defaults = .standard
            self.keyPrefix = suiteName + "."
        }
    }

    func getString(_ key: String) -> String? {
        return defaults.string(forKey: keyPrefix + key)
    }

    func putString(_ key: String, _ value: String?) {
        if let value = value {
            defaults.set(value, forKey: keyPrefix + key)
        } else {
            defaults.removeObject(forKey: keyPrefix + key)
        }
    }

    func clear() {
        // We only know which keys belong to us if they share the
        // prefix. In suite mode (production), `dictionaryRepresentation`
        // returns the suite's keys PLUS the registration domain and
        // NSGlobalDomain — wiping all of those would clobber other
        // SDKs / extensions that share the App Group suite (e.g. badge
        // count, pendingAcks, the carousel click data, plus iOS-owned
        // keys like AppleLanguages). Use an explicit allowlist of
        // Swan-owned key names instead. Caught 2026-05-18 — Bug 10 in
        // the senior-engineer audit.
        let swanOwnedKeys: [String] = keyPrefix.isEmpty ? UserDefaultsKeyValueStore.knownSwanKeys
            : UserDefaultsKeyValueStore.knownSwanKeys.map { keyPrefix + $0 }
        for key in swanOwnedKeys {
            defaults.removeObject(forKey: key)
        }
        // Prefix mode still catches dynamically-named keys (e.g. queued
        // events keyed by uuid) that we own by construction.
        if !keyPrefix.isEmpty {
            for (key, _) in defaults.dictionaryRepresentation() where key.hasPrefix(keyPrefix) {
                defaults.removeObject(forKey: key)
            }
        }
    }

    /// Allowlist of Swan-owned key NAMES (without the optional `keyPrefix`).
    /// MUST be kept in sync with the actual `Keys` enums across the SDK.
    /// If a new SDK persisted key is introduced and missed here, `clear()`
    /// will leak that value across resets — preferable failure mode to
    /// the pre-Bug-10 behavior of wiping unrelated suite content.
    /// Verified against CredentialsStore.Keys, SessionManager.Keys,
    /// BadgeService.keyBadgeCount, PendingAckStore.Keys, and the
    /// content-extension click-data key. Caught 2026-05-18 — Bug 19
    /// regression from the initial Bug 10 fix that used `swan_*`-prefixed
    /// names that don't match the actual on-disk keys.
    internal static let knownSwanKeys: [String] = [
        // CredentialsStore — bare names, see CredentialsStore.Keys
        "appId",
        "deviceId",
        "generatedCDID",
        "currentCDID",
        "identifier",
        "pushNotificationToken",
        "ackUrl",
        // SessionManager — see SessionManager.Keys
        "swanSessionId",
        "swanSessionLastActiveTime",
        // BadgeService — see BadgeService.keyBadgeCount
        "swan_badge_count",
        // Carousel CE → host click data (consumePendingCarouselClick)
        "swanTemplateClickData",
        // PendingAckStore — see PendingAckStore.Keys
        "pendingAcks",
    ]
}

/// Test fake — pure in-memory, no UserDefaults dep. Used by unit tests.
final class InMemoryKeyValueStore: KeyValueStore {
    private var map: [String: String] = [:]
    private let lock = NSLock()

    init() {}

    func getString(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return map[key]
    }

    func putString(_ key: String, _ value: String?) {
        lock.lock(); defer { lock.unlock() }
        if let value = value {
            map[key] = value
        } else {
            map.removeValue(forKey: key)
        }
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        map.removeAll()
    }
}
