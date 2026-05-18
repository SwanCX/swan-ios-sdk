import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Plain-JSON HTTP POST to `/mobile-push-tracking`.
///
/// **Capability:** `delivery-click-ack` (Phase 1.16 port).
///
/// # Why a dedicated URLSession-based transport
///
/// The shared ``SwanHttpClient`` does two things on every request:
///   1. LZW64-compresses the JSON body.
///   2. LZW64-encodes the `X-Swan-Device-Id` header.
///
/// The ACK wire (`spec/wire/notification-ack.yaml` "Compression" note)
/// is PLAIN JSON with a PLAIN deviceId header — RN calls
/// `sendToSwan(..., data)` without the third `encode` arg
/// (src/index.tsx:1831), so both default to unencoded. Bypassing both
/// transforms via the shared client would require a per-request opt-out
/// flag we don't currently have; cleaner to use a dedicated URLSession.
///
/// 10s timeout matches the device-registration / sendToSwan ceiling.
///
/// Returns `true` on 2xx; `false` on any non-2xx / network / IO failure.
/// Errors are NOT thrown — every path returns a bool. Matches the RN
/// `ackPromises.map` path (src/index.tsx:1836) and the cold-start
/// `sendDirectNotificationAck` posture
/// (src/index.tsx:5190-5200 — every error is swallowed).
final class DirectAckTransport {

    private let webhookUrl: String
    private let session: URLSession

    init(webhookUrl: String, session: URLSession? = nil) {
        self.webhookUrl = webhookUrl
        if let session = session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = Self.timeoutSeconds
            config.timeoutIntervalForResource = Self.timeoutSeconds
            self.session = URLSession(configuration: config)
        }
    }

    /// Test-only initializer accepting an `HttpTransport` so tests can
    /// inject a `FakeTransport` and inspect bytes. Production uses
    /// URLSession directly.
    init(webhookUrl: String, underlying: HttpTransport) {
        self.webhookUrl = webhookUrl
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = Self.timeoutSeconds
        self.session = URLSession(configuration: config)
        self._underlying = underlying
    }

    /// Optional test-injectable transport. When set, all `post(...)` calls
    /// flow through it instead of `URLSession`.
    private var _underlying: HttpTransport?

    /// POST the payload. Returns `true` on 2xx, `false` otherwise.
    func post(_ payload: AckPayload) async -> Bool {
        guard let url = URL(string: webhookUrl) else {
            SwanLogger.warn("DirectAckTransport.post: invalid webhookUrl \(webhookUrl)")
            return false
        }
        let body: Data
        do {
            body = try payload.toJsonData()
        } catch {
            SwanLogger.warn("DirectAckTransport.post: encode failed: \(error.localizedDescription)")
            return false
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Plain header — RN: `'X-Swan-Device-Id': deviceIdHeader` where
        // deviceIdHeader = deviceId when encode=false (src/index.tsx:1500).
        request.setValue(payload.deviceId, forHTTPHeaderField: "X-Swan-Device-Id")
        request.httpBody = body

        if let underlying = _underlying {
            do {
                let response = try await underlying.send(request)
                return (200..<300).contains(response.status)
            } catch {
                SwanLogger.warn("ACK POST exception: \(error.localizedDescription)")
                return false
            }
        }

        // Production path: URLSession.dataTask wrapped in continuation
        // (iOS 13 floor; URLSession.data(for:) is iOS 15+).
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let task = session.dataTask(with: request) { _, response, error in
                if let error = error {
                    SwanLogger.warn("ACK POST exception: \(error.localizedDescription)")
                    cont.resume(returning: false)
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    cont.resume(returning: false)
                    return
                }
                let ok = (200..<300).contains(http.statusCode)
                if !ok {
                    SwanLogger.warn("ACK POST failed — HTTP \(http.statusCode)")
                }
                cont.resume(returning: ok)
            }
            task.resume()
        }
    }

    static let timeoutSeconds: TimeInterval = 10.0
}
