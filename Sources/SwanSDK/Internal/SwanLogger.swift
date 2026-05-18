import Foundation
import os.log

/// SDK-internal logger that gates debug/info traces behind a runtime
/// flag — toggled by ``SwanConfig/logging`` (see
/// ``Swan/initialize(appId:baseUrl:config:)`` / ``Swan/enableLogs(_:)``).
///
/// **Capability:** `init-config` (Phase 1.10).
///
/// Mirrors RN's `src/utils/Logger.ts`. RN gates `log`, `warn` and
/// `error` behind the same flag — we deliberately diverge: warnings
/// and errors always pass through to the system log so host apps and
/// crash reporters keep their diagnostic signal. Suppressing SDK
/// errors silently is the kind of "RN could be cleaner" call we fix
/// in the native port per the agent's bug-handling rule. Android made
/// the same call — keep iOS aligned.
///
/// Backed by `os.log` (`OSLog`) — the modern Apple-recommended logging
/// facade. On iOS 14+ unified logging captures these messages; on
/// older OSes they flow through to `os_log`. No third-party deps.
///
/// Thread-safety: writes to ``enabled`` flow through a lock so a flip
/// via ``setEnabled(_:)`` is immediately observed by other threads.
/// (Atomic-class-style volatile reads aren't first-class in Swift; a
/// plain `NSLock` is cheap enough at the call rate of an SDK logger.)
internal enum SwanLogger {

    private static let lock = NSLock()
    private static var _enabled: Bool = false

    /// Default OSLog category. Distinct enough to filter in Console.app.
    private static let log = OSLog(subsystem: "cx.swan.sdk", category: "SwanSDK")

    /// Toggle internal debug/info logging. Public via
    /// ``Swan/enableLogs(_:)``.
    static func setEnabled(_ value: Bool) {
        lock.lock()
        _enabled = value
        lock.unlock()
    }

    /// Returns current state — exposed for tests.
    static func isEnabled() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return _enabled
    }

    /// Debug-level. Suppressed unless ``isEnabled()`` is `true`.
    static func debug(_ message: @autoclosure () -> String) {
        guard isEnabled() else { return }
        let m = message()
        os_log("%{public}@", log: log, type: .debug, m)
    }

    /// Info-level. Suppressed unless ``isEnabled()`` is `true`.
    static func info(_ message: @autoclosure () -> String) {
        guard isEnabled() else { return }
        let m = message()
        os_log("%{public}@", log: log, type: .info, m)
    }

    /// Warning-level. Always emitted — see type doc. The flag does NOT
    /// suppress warnings so host apps keep diagnostic signal.
    static func warn(_ message: @autoclosure () -> String) {
        let m = message()
        os_log("%{public}@", log: log, type: .default, m)
    }

    /// Error-level. Always emitted.
    static func error(_ message: @autoclosure () -> String) {
        let m = message()
        os_log("%{public}@", log: log, type: .error, m)
    }
}
