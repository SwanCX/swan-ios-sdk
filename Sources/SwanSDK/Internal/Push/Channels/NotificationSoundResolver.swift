import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif

/// Pure resolver for the `data.sound` field on inbound FCM payloads —
/// iOS port.
///
/// **Capability:** `custom-notification-sound`.
///
/// Spec:
///   - `spec/wire/push-payload-fcm.yaml#FcmDataField.sound` — resolution
///     rules (default / silent / custom filename, iOS appends `.wav` if
///     no extension).
///   - `conformance/scenarios/custom-notification-sound.feature` —
///     preserve wire value end-to-end (RN v2.7 regression), silent
///     suppression, custom filename plays at notification time.
///
/// # RN parity
///
/// Mirrors `swan-react-native-sdk/src/utils/NotificationSoundHelper.ts`:
///   - `resolveSoundFromPayload` (lines 19-32): undefined/null/"" /
///     `"default"` → default; `"none"`/`"silent"` → silent; else
///     custom filename verbatim.
///   - `buildIosSound` (lines 38-45): silent → undefined; "default" →
///     "default"; custom → `<name>.wav` if no extension, else name as-is.
///
/// # iOS-vs-Android divergence
///
/// - **Android** strips the extension (looks up `R.raw.<name>` resources).
/// - **iOS** APPENDS `.wav` when none is present (`UNNotificationSound`
///   requires the bundled filename WITH extension).
/// - Android's `Sound` is parsed once into a typed sealed-class; iOS
///   port uses the same `Sound` enum so the cross-platform read path is
///   stable.
///
/// # Wire byte-equivalence
///
/// The resolver MUST NOT mutate the value seen on the wire. The
/// conformance scenario "Custom sound name is preserved on the payload"
/// asserts that for `data.sound = "alert_chime"`, the parsed
/// `Sound.custom(name:)` carries `name = "alert_chime"` verbatim — no
/// rewriting, no normalization, no host-side resolution at parse time.
///
/// The OS-bridge step happens at notification-build time inside
/// A22's `Internal/Push/Templates/` package; this resolver provides the
/// pure mapping + a ``SoundResolverHost`` seam so that package can
/// produce `UNNotificationSound` without leaking framework deps into
/// the resolver.
internal enum NotificationSoundResolver {

    /// Parsed representation of `data.sound`.
    ///
    /// Mirrors RN's `SoundConfig` (NotificationSoundHelper.ts:14) and
    /// Android's `Sound` sealed class:
    ///   - ``default``: enabled, RN parity name = "default"
    ///     (system default sound).
    ///   - ``silent``:  disabled (suppress sound — host sets
    ///     `UNMutableNotificationContent.sound = nil`).
    ///   - ``custom(name:)``: enabled, name = arbitrary filename
    ///     (verbatim from the wire).
    internal enum Sound: Equatable {
        case `default`
        case silent
        case custom(name: String)

        /// Whether the OS should play any sound. RN parity —
        /// `enabled: boolean` on `SoundConfig`
        /// (NotificationSoundHelper.ts:14).
        var enabled: Bool {
            switch self {
            case .default, .custom: return true
            case .silent: return false
            }
        }
    }

    /// Parse `data.sound` into a typed ``Sound``.
    ///
    /// RN parity (NotificationSoundHelper.ts:19-32):
    ///   - nil / empty / "default" → ``Sound/default``
    ///   - "none" / "silent"       → ``Sound/silent``
    ///   - anything else           → ``Sound/custom(name:)`` verbatim
    internal static func resolve(_ soundValue: String?) -> Sound {
        guard let value = soundValue, !value.isEmpty else { return .default }
        if value == "default" { return .default }
        if value == "none" || value == "silent" { return .silent }
        return .custom(name: value)
    }

    /// Resolve the iOS-side sound filename for a ``Sound``.
    ///
    /// Mirrors RN's `buildIosSound` (NotificationSoundHelper.ts:38-45):
    ///   - ``Sound/silent`` → `nil` (suppress sound; host sets
    ///     `content.sound = nil`)
    ///   - ``Sound/default`` → `"default"` (hint for callers to use
    ///     `UNNotificationSound.default`)
    ///   - ``Sound/custom(name:)`` → `<name>.wav` if `name` has no
    ///     extension; otherwise `name` verbatim. iOS requires the
    ///     filename WITH extension when constructing
    ///     `UNNotificationSound(named:)`.
    ///
    /// **Why `.wav` and not `.caf`?** RN appends `.wav` by default
    /// (NotificationSoundHelper.ts:44). To preserve byte-equivalent
    /// behavior on the iOS port we mirror that. Hosts that ship `.caf`
    /// or `.aiff` files (Apple-recommended for shorter latency) put the
    /// extension in the wire value (e.g. `data.sound = "alert.caf"`)
    /// and the resolver passes it through unchanged.
    internal static func iosSoundFileName(_ sound: Sound) -> String? {
        switch sound {
        case .silent:
            return nil
        case .default:
            return "default"
        case .custom(let name):
            if name.contains(".") { return name }
            return "\(name).wav"
        }
    }

    /// Convenience — parse + resolve in one call, for callers that take
    /// the raw wire value and just want the filename.
    ///
    /// Returns `nil` for silent, `"default"` for default, otherwise the
    /// custom filename with `.wav` appended if no extension.
    internal static func resolveSoundForPayload(_ soundValue: String?) -> String? {
        return iosSoundFileName(resolve(soundValue))
    }

    /// Wrap a ``Sound`` into a host-resolved token. The seam exists so
    /// unit tests can assert WITHOUT an `UNNotificationSound` instance.
    /// A22's rendering layer calls this with a
    /// ``SystemSoundResolverHost`` that returns the real OS object.
    internal static func unNotificationSoundToken(
        for sound: Sound,
        host: SoundResolverHost
    ) -> SoundResolverHost.Token? {
        switch sound {
        case .silent:
            return nil
        case .default:
            return host.defaultSoundToken()
        case .custom:
            guard let filename = iosSoundFileName(sound) else { return nil }
            return host.namedSoundToken(filename: filename)
        }
    }
}

/// Test seam for ``NotificationSoundResolver/unNotificationSoundToken(for:host:)``.
///
/// Production: ``SystemSoundResolverHost`` returns real
/// `UNNotificationSound` values wrapped in ``SoundResolverHost/Token``.
/// Tests: ``NotificationSoundResolverTests/FakeSoundResolverHost`` returns
/// the typed token directly so assertions don't depend on
/// `UNNotificationSound` (which has no `Equatable` conformance).
internal protocol SoundResolverHost: Sendable {
    func defaultSoundToken() -> SoundResolverHost.Token
    func namedSoundToken(filename: String) -> SoundResolverHost.Token
}

/// Stable representation of the resolved sound — used by the test
/// seam and threaded through to the rendering layer. The rendering
/// layer maps this to the actual `UNNotificationSound` instance at
/// build time.
///
/// Top-level (not nested) because Swift protocols can't host nested
/// types in an extension. We give it the `SoundResolverHost.Token`
/// typealias for ergonomic access at call sites.
internal enum SoundResolverToken: Equatable {
    case systemDefault
    case named(filename: String)
}

extension SoundResolverHost {
    internal typealias Token = SoundResolverToken
}

/// Production ``SoundResolverHost`` — returns the same ``Token`` shape
/// as the test fake. The rendering layer (A22) takes a ``Token`` and
/// constructs the matching `UNNotificationSound` so the resolver stays
/// framework-free.
internal struct SystemSoundResolverHost: SoundResolverHost {
    init() {}

    func defaultSoundToken() -> SoundResolverHost.Token {
        return .systemDefault
    }

    func namedSoundToken(filename: String) -> SoundResolverHost.Token {
        return .named(filename: filename)
    }
}
