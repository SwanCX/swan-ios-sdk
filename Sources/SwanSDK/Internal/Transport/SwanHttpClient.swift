import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Wraps the bytes coming back from the network for the request layer.
struct HttpResponseBody {
    let status: Int
    let data: Data
}

/// Minimal "execute this URLRequest" seam — lets tests swap in a fake
/// transport without intercepting global URLProtocol state.
protocol HttpTransport {
    func send(_ request: URLRequest) async throws -> HttpResponseBody
}

/// Production `URLSession`-backed transport. Applies the two wire-format
/// transforms RN applies in `sendToSwan`
/// (`swan-react-native-sdk/src/index.tsx:1486`):
///
///   1. LZW64-compress the JSON body (Content-Type stays
///      `application/json`).
///   2. LZW64-encode the `X-Swan-Device-Id` header — skipped if the
///      provider returns nil/empty (pre-registration calls
///      legitimately have no deviceId; RN sends an empty header).
///
/// Timeout: 10s, matching `spec/behavior/device-registration.yaml`
/// `request_timeout_ms` (and Android's `SwanHttpClient.DEFAULT_TIMEOUT_MS`).
final class SwanHttpClient: HttpTransport {

    static let defaultTimeoutSeconds: TimeInterval = 10.0

    /// Closure that reads the device id at send time (so we don't capture
    /// a stale credential set).
    typealias DeviceIdProvider = @Sendable () -> String?

    private let session: URLSession
    private let deviceIdProvider: DeviceIdProvider
    /// Underlying transport actually used to fire the request. Defaults
    /// to a `URLSession.shared`-style send; tests inject a fake.
    private let underlying: HttpTransport

    init(
        deviceIdProvider: @escaping DeviceIdProvider,
        timeout: TimeInterval = SwanHttpClient.defaultTimeoutSeconds,
        underlying: HttpTransport? = nil
    ) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: config)
        self.session = session
        self.deviceIdProvider = deviceIdProvider
        self.underlying = underlying ?? URLSessionTransport(session: session)
    }

    func send(_ request: URLRequest) async throws -> HttpResponseBody {
        var prepared = request
        applyDeviceIdHeader(to: &prepared)
        compressJsonBody(of: &prepared)
        return try await underlying.send(prepared)
    }

    private func applyDeviceIdHeader(to request: inout URLRequest) {
        guard let deviceId = deviceIdProvider(), !deviceId.isEmpty else {
            return  // pre-registration — RN sends empty header
        }
        guard let encoded = Lzw64.encode(deviceId), !encoded.isEmpty else {
            return
        }
        request.setValue(encoded, forHTTPHeaderField: "X-Swan-Device-Id")
    }

    private func compressJsonBody(of request: inout URLRequest) {
        guard let body = request.httpBody, !body.isEmpty else { return }

        // Only compress JSON-shaped bodies (matches Android: backend's
        // `parseJsonOrLzw64` only runs on JSON endpoints).
        let contentType = request.value(forHTTPHeaderField: "Content-Type") ?? ""
        let isJsonish = contentType.lowercased().contains("json") || contentType.isEmpty
        guard isJsonish else { return }

        guard let raw = String(data: body, encoding: .utf8) else { return }
        guard let encoded = Lzw64.encode(raw) else { return }
        request.httpBody = Data(encoded.utf8)
        // Content-Type stays application/json even when LZW64-encoded
        // — matches RN exactly (index.tsx:1519). Backend handles both
        // shapes via `parseJsonOrLzw64`.
        if contentType.isEmpty {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
    }
}

/// `URLSession.dataTask` wrapped in async/await. We can't use
/// `URLSession.data(for:)` on the iOS 13 / macOS 10.15 floor (it
/// arrived in iOS 15 / macOS 12), so we bridge manually.
final class URLSessionTransport: HttpTransport {
    private let session: URLSession

    init(session: URLSession) {
        self.session = session
    }

    func send(_ request: URLRequest) async throws -> HttpResponseBody {
        return try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: request) { data, response, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    continuation.resume(throwing: HttpError.invalidResponse)
                    return
                }
                continuation.resume(
                    returning: HttpResponseBody(
                        status: http.statusCode,
                        data: data ?? Data()
                    )
                )
            }
            task.resume()
        }
    }
}

enum HttpError: Error, Equatable {
    case invalidResponse
    case nonSuccess(status: Int, body: String)
    case missingField(String)
}
