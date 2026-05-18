import Foundation

/// Payload fired to host-app listeners registered via
/// ``Swan/addPushNotificationReceivedListener(_:)`` when a data-only
/// push arrives in the foreground BEFORE the SDK has displayed the
/// system notification.
///
/// Foreground-only — background / killed-state pushes go through the
/// normal tap path (``Swan/addNotificationOpenedListener(_:)``) without
/// firing this event.
///
/// Not buffered — late subscribers don't see prior pushes. Host apps
/// that want a delivered record should subscribe at app launch.
public struct PushNotificationReceivedPayload: Equatable, Sendable {
    /// Push transport-layer id (APNs `id` field if present, otherwise
    /// any `messageId` carried in the data payload). `nil` for synthetic /
    /// test pushes that don't carry a message id.
    public let messageId: String?

    /// Title from the push's `data.title`. `nil` if the payload omits it.
    public let title: String?

    /// Body from the push's `data.body`. `nil` if the payload omits it.
    public let body: String?

    /// The raw push `data` map as delivered. String-only on the wire
    /// (matches what FCM enforces on the Android side; APNs payloads are
    /// flattened to the same shape for cross-platform parity). Host apps
    /// that need typed access should parse known keys themselves; the
    /// SDK does NOT pre-parse this map.
    public let data: [String: String]

    public init(
        messageId: String?,
        title: String?,
        body: String?,
        data: [String: String]
    ) {
        self.messageId = messageId
        self.title = title
        self.body = body
        self.data = data
    }
}
