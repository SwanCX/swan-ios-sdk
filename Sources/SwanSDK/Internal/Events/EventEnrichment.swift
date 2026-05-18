import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Builds the auto-enriched `data` object for each event.
///
/// **Capabilities:** `custom-events`, `semantic-ecommerce-events`.
///
/// Source-of-truth: RN `trackEvent` (src/index.tsx:2166–2177) — the
/// `enrichedEventData` spread.
///
/// Spec:
///   - `spec/api/events.yaml` `EventEnvelope.data` description
///   - `spec/wire/event-ingest.yaml` `BatchEvent.data` description
///   - `conformance/scenarios/custom-events.feature` (Tier-2 enrichment scenario)
///
/// Enrichment fields (always present, in this insertion order so JSON keys
/// land deterministically for golden-byte comparisons):
///   - **caller-supplied attributes** spread first; SDK fields below CANNOT
///     be overridden — matches RN's spread order `{ ...eventData, platform, ... }`
///     where the named props win.
///   - `platform`     = `"ios"`
///   - `osModal`      = `UIDevice.systemVersion` (string, e.g. `"17.0"`).
///     iOS-specific: Android emits an integer API level here; RN on iOS
///     emits a STRING via `Platform.Version` (`spec/wire/event-ingest.yaml`
///     `BatchEvent.data.osModal` description allows either shape — per
///     platform).
///   - `deviceModal`  = `UIDevice.model`-like (e.g. `"iPhone15,2"`)
///   - `deviceBrand`  = `"Apple"`  (iOS has no per-vendor brand — RN's
///     `DeviceInfo.getBrand()` returns `"Apple"`)
///   - `country`      = config-supplied; OMITTED when empty.
///   - `currency`     = config-supplied; OMITTED when empty.
///   - `businessUnit` = config-supplied; OMITTED when empty.
///   - `deviceId`     = registered device id
///   - `sessionId`    = current session uuid (from ``SessionManager``)
///
/// ## RN parity divergence — omit-when-empty for super-properties
///
/// `country`/`currency`/`businessUnit` are OMITTED when their config value
/// is the empty string default. This matches `conformance/scenarios/
/// super-properties.feature` ("Super-properties unset are absent (not empty
/// string) in payload") and the second event in `spec/wire/golden/
/// event-ingest-batch.json`, which carries no country/currency/businessUnit
/// keys.
///
/// RN itself emits them as empty strings — that's a backportable RN bug
/// (RN bug tracker entry #2). The native port is the canonical fix; the RN
/// entry stays open until RN ships matching omit-when-empty semantics.
internal enum EventEnrichment {

    /// Captured device fingerprint. Pulled from `UIDevice` in production;
    /// tests inject a fake.
    ///
    /// `osModal` is a `String` on iOS — `UIDevice.systemVersion` returns
    /// `"17.0"` (matches RN's iOS `Platform.Version`). On Android the
    /// equivalent is an `Int` (API level). Per-platform: each native port
    /// uses its idiomatic shape (`spec/wire/event-ingest.yaml` allows either).
    struct DeviceInfo: Equatable, Sendable {
        let platform: String
        let osModal: String
        let deviceModal: String
        let deviceBrand: String

        /// Pull device fingerprint from `UIDevice`. On non-iOS platforms
        /// (macOS test-runner sandboxes) returns placeholder values so the
        /// `swift test` flow stays green.
        static func current() -> DeviceInfo {
            #if canImport(UIKit) && (os(iOS) || os(tvOS))
            let device = UIDevice.current
            return DeviceInfo(
                platform: "ios",
                osModal: device.systemVersion,
                deviceModal: hardwareModelIdentifier() ?? device.model,
                deviceBrand: "Apple"
            )
            #else
            // Sandbox / unit-test fallback. Real wire shape preserved.
            return DeviceInfo(
                platform: "ios",
                osModal: "17.0",
                deviceModal: "iPhone15,2",
                deviceBrand: "Apple"
            )
            #endif
        }

        /// `uname()`-style hardware identifier ("iPhone15,2"). Matches
        /// what RN's `react-native-device-info` returns for `getModel()`
        /// on iOS — preferred over `UIDevice.model` ("iPhone") because
        /// the more-specific id is what RN ships.
        ///
        /// Returns nil under non-iOS (test runner on macOS).
        private static func hardwareModelIdentifier() -> String? {
            #if os(iOS) || os(tvOS)
            var systemInfo = utsname()
            uname(&systemInfo)
            let mirror = Mirror(reflecting: systemInfo.machine)
            let id = mirror.children.reduce("") { partial, element in
                guard let value = element.value as? Int8, value != 0 else { return partial }
                return partial + String(UnicodeScalar(UInt8(value)))
            }
            return id.isEmpty ? nil : id
            #else
            return nil
            #endif
        }
    }

    /// Compose the enriched `data` object for a single event.
    ///
    /// - Parameters:
    ///   - attributes: caller-provided fields (e.g. `["productId": .string("SKU-1234")]`)
    ///   - config: super-properties (country/currency/businessUnit)
    ///   - deviceId: persisted device id
    ///   - sessionId: resolved by [SessionManager]
    ///   - deviceInfo: platform+model+brand+osModal — injected for testability
    ///
    /// Returns an `[String: JSONValue]` so the caller (``EventTracker``)
    /// can hand it straight to `JSONEncoder` for the wire payload.
    static func enrich(
        attributes: [String: JSONValue],
        config: EventConfig,
        deviceId: String,
        sessionId: String,
        deviceInfo: DeviceInfo = .current()
    ) -> [String: JSONValue] {
        // Use OrderedDictionary-style append so the encoder writes keys in
        // a deterministic order. Swift's `[String: JSONValue]` is unordered
        // at the storage level, but `JSONEncoder.outputFormatting`'s sorted
        // mode (or the absence thereof) handles golden comparison via
        // parsed-tree equality — see DeviceRegistrationServiceTests for the
        // pattern. We DON'T require byte-for-byte raw-string equality;
        // backend tolerates any key order, and the goldens assert parsed
        // tree shape.
        var out: [String: JSONValue] = [:]
        // Caller attributes go FIRST. SDK-managed fields below override
        // anything a caller tries to slip in under the same key — matches
        // RN's spread.
        for (k, v) in attributes { out[k] = v }

        out["platform"] = .string(deviceInfo.platform)
        out["osModal"] = .string(deviceInfo.osModal)
        out["deviceModal"] = .string(deviceInfo.deviceModal)
        out["deviceBrand"] = .string(deviceInfo.deviceBrand)

        // Super-properties: only emit when set. Empty default ⇒ key absent.
        // RN-bug-tracker entry #2 (RN ships them as empty strings).
        if !config.country.isEmpty {
            out["country"] = .string(config.country)
        }
        if !config.currency.isEmpty {
            out["currency"] = .string(config.currency)
        }
        if !config.businessUnit.isEmpty {
            out["businessUnit"] = .string(config.businessUnit)
        }
        // screen-tracking super-property: only emit when set. Once
        // `Swan.setCurrentScreenName(name)` lands a non-empty value, every
        // subsequent enqueued custom event carries it; the empty default
        // keeps the wire shape unchanged for hosts that don't use it.
        if !config.currentScreenName.isEmpty {
            out["currentScreenName"] = .string(config.currentScreenName)
        }

        out["deviceId"] = .string(deviceId)
        out["sessionId"] = .string(sessionId)
        return out
    }
}
