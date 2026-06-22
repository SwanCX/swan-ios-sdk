import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Conformance-only transport seam.
///
/// This is the iOS analog of the Android `ConformanceCaptureInterceptor`
/// wiring (SWA-7575 / SWA-7585) and the RN sample app's `global.fetch`
/// wrapper. It lets the native iOS conformance runner OBSERVE the SDK's
/// outbound HTTP and SHORT-CIRCUIT it with canned stub responses — so the
/// wire-format + event-flow scenarios become assertable on a simulator
/// WITHOUT a reachable Swan backend.
///
/// ## Why this is not public customer API
///
/// The conformance bridge + sample app live in a SEPARATE module from
/// `SwanSDK`, so a purely `internal` seam cannot reach them. Swift's
/// `@_spi` is the canonical mechanism for "exported across modules but
/// excluded from the stable public API surface": the symbol is `public`
/// at the linker level but is invisible unless the importer opts in with
/// `@_spi(SwanConformance) import SwanSDK`. Customer host apps that do a
/// plain `import SwanSDK` never see it, and the API-claim gate
/// (`scripts/check-api-claims.sh`) only audits the top-level (`-maxdepth 1`)
/// SDK files — this lives under `Internal/Conformance/`, so it is not part
/// of the audited public surface (parity with Android keeping the capture
/// out of `sdk.api`).
///
/// ## Why this does not change production network behavior
///
/// `protocolClasses` is `nil` by default and is NEVER populated by the SDK
/// itself. Only the conformance sample app sets it, and only under
/// `#if SWAN_CONFORMANCE` (a flag absent from every release build). When
/// `nil`, `SwanHttpClient` builds its `URLSession` exactly as before. The
/// hook is read once, at `SwanHttpClient` construction, so toggling it has
/// no effect on an already-built transport.
@_spi(SwanConformance)
public enum SwanConformanceHooks {

    // Guards `_protocolClasses` — mirrors `SwanLogger`'s NSLock-around-a-
    // static-var convention so this compiles at the SDK's Swift 5.9 floor
    // without `nonisolated(unsafe)` (a 5.10 spelling).
    private static let lock = NSLock()
    private static var _protocolClasses: [AnyClass]?

    /// `URLProtocol` subclasses to PREPEND to the SDK's `URLSession`
    /// configuration's `protocolClasses`. A globally-registered
    /// `URLProtocol` is NOT consulted by a session that uses a custom
    /// `URLSessionConfiguration` (which `SwanHttpClient` does) — the class
    /// must be present in that config's `protocolClasses`. This hook is the
    /// only supported way to inject one.
    ///
    /// Set this from the conformance sample app BEFORE `Swan.initialize(...)`
    /// runs (i.e. in `application(_:didFinishLaunchingWithOptions:)` before
    /// the `Swan.shared.initialize` call), under `#if SWAN_CONFORMANCE`.
    public static var protocolClasses: [AnyClass]? {
        get { lock.lock(); defer { lock.unlock() }; return _protocolClasses }
        set { lock.lock(); defer { lock.unlock() }; _protocolClasses = newValue }
    }

    /// Read accessor used by `SwanHttpClient`. Internal callers do not need
    /// the `@_spi` import; this stays plain-`internal`.
    static func currentProtocolClasses() -> [AnyClass]? {
        return protocolClasses
    }

    // MARK: Connectivity toggle (SWA-7578)

    private static let offlineLock = NSLock()
    private static var _offline = false

    /// Conformance-only connectivity flag. When `true`, the conformance
    /// sample app's capturing `URLProtocol` simulates a dead network: it
    /// fails every intercepted SDK request with a network error instead of
    /// returning a stub response. This lets the conformance runner drive the
    /// SDK's offline → enqueue → reconnect → flush path deterministically on
    /// a simulator, WITHOUT touching the SDK's production behavior.
    ///
    /// ## Why this is not production behavior
    ///
    /// The SDK itself NEVER reads this flag — it is consulted ONLY by the
    /// sample app's `ConformanceHTTPProtocol`, which compiles in solely under
    /// `#if SWAN_CONFORMANCE`. Unlike `protocolClasses`, this is read LIVE on
    /// every request (so the runner can flip offline/online on an
    /// already-running app), but in a release build nothing ever reads it and
    /// the production network path is unchanged. Defaults to `false` (online).
    ///
    /// Toggled by the conformance bridge's `setOffline` command.
    public static var offline: Bool {
        get { offlineLock.lock(); defer { offlineLock.unlock() }; return _offline }
        set { offlineLock.lock(); defer { offlineLock.unlock() }; _offline = newValue }
    }

    // MARK: LZW64 decode (SWA-7372)

    /// Decode an LZW64-encoded request body. The SDK compresses every
    /// `/v2/trackEvent` body with the same LZW64 scheme the backend decodes;
    /// the conformance HTTP stub needs to peek at the decoded body so it can
    /// return a profile-switching userLogin response (which lets the SDK reach
    /// the logged-in state a userLogout then exercises). Returns `nil` when the
    /// input is not valid LZW64. Conformance-only — the production network path
    /// never calls this.
    public static func decodeLzw64(_ input: String) -> String? {
        return Lzw64.decode(input)
    }
}
