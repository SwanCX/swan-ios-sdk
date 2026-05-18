import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// POSTs subscribe / unsubscribe payloads to the Swan
/// `/device/push-subscription` endpoint.
///
/// **Capability:** `push-fcm-ios` (Phase 1.15 port).
///
/// Spec:
///   - `spec/wire/push-subscription.yaml` — wire format
///   - `spec/wire/golden/push-subscription-subscribe.json`
///   - `spec/wire/golden/push-subscription-unsubscribe.json`
///   - `conformance/scenarios/push-fcm-android.feature` — same wire
///     contract; the iOS port satisfies it via the apns sub-object
///     backend path
///   - `spec/locked-decisions.md` — `sdkCapabilities.dataOnlyPush: true`
///     is non-negotiable
///
/// Mirrors Android's `PushSubscriptionService.kt` line-for-line.
///
/// # iOS-vs-Android divergence
///
/// - `lastLoginPlatform` is `"ios"` (Android sends `"android"`).
/// - The token is the **hex-encoded APNs device token** the host app
///   handed to ``Swan/registerAPNsToken(_:)`` — NOT an FCM token.
///   The Swan backend's PUSH-HTTP pipeline accepts both shapes via the
///   FCM v1 `apns` sub-object; per the iOS port docs we send the raw
///   APNs token and let backend do the FCM wrap.
///
/// # Pre-condition: device registration must have completed
///
/// If [CredentialsStore.read] returns `nil`, returns
/// `Result.failure(...)` and does NOT fire the network call — matches
/// RN's `syncPushSubscription` guard (src/index.tsx:629).
final class PushSubscriptionService {

    private let appId: String
    private let baseUrl: String
    private let sdkVersion: String
    private let client: HttpTransport
    private let credentialsStore: CredentialsStore
    /// Test seam — production code uses `Self.defaultIsoUtcNow`.
    private let isoTimestamp: () -> String

    init(
        appId: String,
        baseUrl: String,
        sdkVersion: String,
        client: HttpTransport,
        credentialsStore: CredentialsStore,
        isoTimestamp: @escaping () -> String = PushSubscriptionService.defaultIsoUtcNow
    ) {
        self.appId = appId
        self.baseUrl = Self.trimTrailingSlash(baseUrl)
        self.sdkVersion = sdkVersion
        self.client = client
        self.credentialsStore = credentialsStore
        self.isoTimestamp = isoTimestamp
    }

    /// POST a PUSH_SUBSCRIBE payload. Returns success on backend 2xx.
    /// The token is NOT persisted here — the orchestrator
    /// (``APNsTokenService``) writes ``CredentialsStore.pushNotificationToken``
    /// on success so a re-subscribe with the same token can short-circuit.
    func subscribe(token: String) async -> Result<Void, Error> {
        if token.isEmpty {
            return .failure(PushSubscriptionError.blankToken)
        }
        guard let creds = credentialsStore.read() else {
            return .failure(PushSubscriptionError.credentialsNotLoaded)
        }

        let now = isoTimestamp()
        let body = PushSubscriptionRequest(
            subscription: PushSubscriptionBlock(
                pushNotificationToken: token,
                subscribed: true,
                lastLoginPlatform: Self.platformIOS,
                sdkCapabilities: PushSdkCapabilities(
                    dataOnlyPush: true,
                    version: sdkVersion
                )
            ),
            status: Self.statusUpdated,
            subscribedAt: now,
            unSubscribedAt: nil,
            // linkedAt = RN `deviceActivatedAt`. iOS port doesn't persist
            // it separately in v1 (mirror Android). `nil` drops the key
            // from the encoded payload, matching spec golden's
            // null-or-missing tolerance.
            linkedAt: nil,
            CDID: creds.currentCDID ?? creds.generatedCDID,
            device: Self.deviceMobile
        )
        return await post(body)
    }

    /// POST a PUSH_UNSUBSCRIBE payload. `subscription: null`,
    /// `status: "revoked"`. Mirrors RN's `processPushUnsubscribeEvents`
    /// (src/index.tsx:1751).
    func unsubscribe() async -> Result<Void, Error> {
        guard let creds = credentialsStore.read() else {
            return .failure(PushSubscriptionError.credentialsNotLoaded)
        }

        let now = isoTimestamp()
        let body = PushSubscriptionRequest(
            subscription: nil,
            status: Self.statusRevoked,
            subscribedAt: nil,
            unSubscribedAt: now,
            linkedAt: nil,
            CDID: creds.currentCDID ?? creds.generatedCDID,
            device: Self.deviceMobile
        )
        return await post(body)
    }

    private func post<T: Encodable>(_ body: T) async -> Result<Void, Error> {
        do {
            let payload = try Self.jsonEncoder.encode(body)
            let url = URL(string: "\(baseUrl)\(Self.pathPushSubscription)?appId=\(appId)")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = payload
            let response = try await client.send(request)
            guard (200..<300).contains(response.status) else {
                let bodyString = String(data: response.data, encoding: .utf8) ?? ""
                return .failure(HttpError.nonSuccess(status: response.status, body: bodyString))
            }
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Constants

    static let pathPushSubscription = "/device/push-subscription"
    static let platformIOS = "ios"
    static let deviceMobile = "mobile"
    static let statusUpdated = "updated"
    static let statusRevoked = "revoked"

    static let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        // Match Android: no sorted keys (backend tolerates any order;
        // byte-equality is asserted via parsed-tree comparison).
        return encoder
    }()

    /// `new Date().toISOString()` → `2026-05-13T07:23:00.000Z`. Locale +
    /// TZ pinned so wire output is identical across all devices.
    static func defaultIsoUtcNow() -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return fmt.string(from: Date())
    }

    private static func trimTrailingSlash(_ s: String) -> String {
        var out = s
        while out.hasSuffix("/") { out.removeLast() }
        return out
    }
}

/// Service-specific errors. Mapped from Android's
/// `IllegalArgumentException` + `IllegalStateException`.
enum PushSubscriptionError: Error, Equatable {
    case blankToken
    case credentialsNotLoaded
}
