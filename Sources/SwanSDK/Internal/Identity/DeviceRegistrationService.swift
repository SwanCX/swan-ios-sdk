import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Device registration service — anonymous-identity capability.
///
/// Spec:
///   - `spec/wire/device-register.yaml`         (HTTP contract)
///   - `spec/behavior/device-registration.yaml` (state machine)
///   - `spec/wire/golden/device-register-fresh.json`    (request shape)
///   - `spec/wire/golden/device-register-response.json` (response shape)
///
/// Mirrors RN's `DeviceRegistrationService.registerDevice()`
/// (`swan-react-native-sdk/src/services/DeviceRegistrationService.ts:54`)
/// and Android's `DeviceRegistrationService.kt`.
///
/// Cached path: if the [CredentialsStore] has persisted credentials,
/// returns those without a network call.
///
/// Fresh registration: POSTs the v1 RN body shape — `purpose:
/// "register_device"`, `platform: "ios"`, `deviceDetails.location: {}`.
/// The body is LZW64-compressed by [SwanHttpClient]; we serialize plain
/// JSON here.
final class DeviceRegistrationService {

    private let appId: String
    private let baseUrl: String
    private let client: HttpTransport
    private let store: CredentialsStore
    /// Persisted alongside credentials so
    /// ``ColdStartAckSender`` can POST `/mobile-push-tracking`
    /// without requiring ``Swan/initialize(appId:baseUrl:config:)`` to
    /// resolve the env-specific URL. Owned by `delivery-click-ack`.
    /// `nil` allowed for legacy callers (pre-`delivery-click-ack` tests);
    /// the cold-start sender silently no-ops on creds saved without it.
    /// Mirrors Android's `DeviceRegistrationService` `ackUrl` field.
    private let ackUrl: String?

    init(
        appId: String,
        baseUrl: String,
        client: HttpTransport,
        store: CredentialsStore,
        ackUrl: String? = nil
    ) {
        self.appId = appId
        self.baseUrl = Self.trimTrailingSlash(baseUrl)
        self.client = client
        self.store = store
        self.ackUrl = ackUrl
    }

    /// Returns persisted credentials if present, otherwise registers a
    /// new device. Idempotent on the second call within the same process.
    func registerDevice() async -> Result<SwanCredentials, Error> {
        if let cached = store.read() {
            return .success(cached)
        }

        do {
            let response = try await postRegister()
            guard let deviceId = response.deviceId else {
                return .failure(HttpError.missingField("deviceId"))
            }
            guard let generatedCDID = response.generatedCDID else {
                return .failure(HttpError.missingField("generatedCDID"))
            }
            let credentials = SwanCredentials(
                appId: appId,
                deviceId: deviceId,
                generatedCDID: generatedCDID,
                currentCDID: nil,
                identifier: nil,
                pushNotificationToken: nil,
                // delivery-click-ack: stamp the env-resolved webhook URL so
                // the cold-start path can read it without an SDK bootstrap.
                ackUrl: ackUrl
            )
            store.save(credentials)
            return .success(credentials)
        } catch {
            return .failure(error)
        }
    }

    private func postRegister() async throws -> DeviceRegisterResponse {
        let body = DeviceRegisterRequest(
            // RN sends an empty location object when geolocation is
            // unavailable. v1 ports do the same — location capability
            // lands later and will populate this. Backend tolerates `{}`.
            deviceDetails: DeviceDetails(location: LocationPayload()),
            platform: Self.platformIOS,
            purpose: Self.purposeRegister
        )

        let payload = try Self.jsonEncoder.encode(body)
        let url = URL(string: "\(baseUrl)\(Self.pathRegister)?appId=\(appId)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = payload

        let response = try await client.send(request)
        guard (200..<300).contains(response.status) else {
            let bodyString = String(data: response.data, encoding: .utf8) ?? ""
            throw HttpError.nonSuccess(status: response.status, body: bodyString)
        }
        return try Self.jsonDecoder.decode(
            DeviceRegisterResponse.self,
            from: response.data
        )
    }

    static let pathRegister = "/v2/device/register"
    static let platformIOS = "ios"
    static let purposeRegister = "register_device"

    /// Shared JSON encoder. We don't use `.sortedKeys` — the wire
    /// format does not require sorted keys; backend tolerates any key
    /// order. (Android's serializer doesn't sort either.) Byte-equality
    /// with the golden is asserted via parsed-tree comparison, not raw
    /// string equality.
    static let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        return encoder
    }()

    static let jsonDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        return decoder
    }()

    private static func trimTrailingSlash(_ s: String) -> String {
        var out = s
        while out.hasSuffix("/") { out.removeLast() }
        return out
    }
}
