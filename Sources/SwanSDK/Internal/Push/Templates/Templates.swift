import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif

/// Public entry-point for the Swan SDK's notification-template rendering.
///
/// **Capabilities:** `push-template-basic`, `push-carousel-manual`,
/// `push-carousel-auto`.
///
/// # Usage from a Notification Service Extension
///
/// The host app adds a Notification Service Extension target to its
/// Xcode project (`File → New → Target → Notification Service
/// Extension`). The auto-generated `NotificationService` subclass's
/// `didReceive(_:withContentHandler:)` body delegates the rendering to
/// this type:
///
/// ```swift
/// import UserNotifications
/// import SwanSDK
///
/// class NotificationService: UNNotificationServiceExtension {
///     var contentHandler: ((UNNotificationContent) -> Void)?
///     var bestAttemptContent: UNMutableNotificationContent?
///
///     override func didReceive(
///         _ request: UNNotificationRequest,
///         withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
///     ) {
///         self.contentHandler = contentHandler
///         bestAttemptContent = request.content.mutableCopy() as? UNMutableNotificationContent
///         guard let best = bestAttemptContent else {
///             contentHandler(request.content); return
///         }
///         Templates.renderContent(request: request, content: best) { rendered in
///             contentHandler(rendered ?? best)
///         }
///     }
///
///     override func serviceExtensionTimeWillExpire() {
///         if let contentHandler, let bestAttemptContent {
///             contentHandler(bestAttemptContent)
///         }
///     }
/// }
/// ```
///
/// Full step-by-step setup (App Group sharing, scheme, Privacy
/// Manifests, deep-link routing) is documented in
/// `platforms/ios/EXTENSIONS.md`.
///
/// # Why a static facade and not a per-instance type
///
/// Notification Service Extensions run in a separate process from the
/// host app and CANNOT share state with the host's
/// `Swan.shared` singleton. Every public method on this facade is
/// therefore *stateless* — host extensions don't need to invoke
/// `Swan.shared.initialize(...)` from the NSE process for templating to
/// work. Cross-process state (credentials, ACK URL) flows via App
/// Group `UserDefaults`; templating itself has zero state dependency.
public enum Templates {

    /// Render a notification request from its userInfo into the supplied
    /// mutable content. Routes between basic / carousel-manual /
    /// carousel-auto based on the `data.notificationType` /
    /// `data.carouselMode` fields.
    ///
    /// Calls `completion` exactly once. The completion receives `nil`
    /// when the request has no actionable Swan template fields (e.g.
    /// title/body/image all absent) — the caller should fall back to
    /// the request's `bestAttemptContent` in that case.
    #if canImport(UserNotifications)
    public static func renderContent(
        request: UNNotificationRequest,
        content: UNMutableNotificationContent,
        completion: @escaping (UNMutableNotificationContent?) -> Void
    ) {
        let data = UserInfoAdapter.toDataMap(request.content.userInfo)
        renderContent(data: data, content: content, completion: completion)
    }

    /// Variant for hosts that have already extracted the `data` map
    /// upstream (e.g. background message handlers).
    public static func renderContent(
        data: [String: String],
        content: UNMutableNotificationContent,
        completion: @escaping (UNMutableNotificationContent?) -> Void
    ) {
        renderContent(
            data: data,
            content: content,
            basicRenderer: BasicTemplateRenderer(),
            carouselRenderer: CarouselTemplateRenderer(),
            completion: completion
        )
    }

    /// Composite Notification Service Extension entrypoint. Fires the
    /// killed-state delivery ACK over the configured App Group and
    /// renders the notification content (images, carousel attachments)
    /// in a single call.
    ///
    /// **Use this** from your NSE's
    /// `didReceive(_:withContentHandler:)`. The full integration is
    /// documented in the `iOS — Rich pushes and extensions` guide.
    ///
    /// **Capabilities:** `delivery-click-ack` + `push-template-basic` /
    /// `push-carousel-manual` / `push-carousel-auto`.
    ///
    /// # Behavior
    ///
    /// - If the payload carries an FCM/APNs message id (`gcm.message_id`
    ///   or `messageId`), a `delivered` ACK is fired asynchronously
    ///   against the env-resolved webhook URL stored alongside the
    ///   credentials. The ACK runs in parallel with content rendering so
    ///   the host completion handler isn't delayed by the network round
    ///   trip.
    /// - Content rendering follows the same routing as
    ///   ``renderContent(request:content:completion:)``.
    /// - Missing App Group / missing credentials / missing `ackUrl` →
    ///   delivery ACK is silently skipped; content rendering still runs.
    ///
    /// - Parameters:
    ///   - request: the UN notification request from
    ///     `didReceive(_:withContentHandler:)`.
    ///   - content: the mutable content to populate with attachments.
    ///   - appGroup: the App Group identifier shared between the host
    ///     app and the NSE. Pass the same identifier configured on
    ///     ``SwanConfig/appGroup``. Pass `nil` to skip the delivery
    ///     ACK and only render content (matches the pre-NSE behavior
    ///     of plain ``renderContent(request:content:completion:)``).
    ///   - completion: invoked exactly once with the rendered content
    ///     (or `nil` if the payload isn't a Swan-templated push).
    public static func handleServiceRequest(
        request: UNNotificationRequest,
        content: UNMutableNotificationContent,
        appGroup: String?,
        completion: @escaping (UNMutableNotificationContent?) -> Void
    ) {
        let data = UserInfoAdapter.toDataMap(request.content.userInfo)
        let messageId = data["gcm.message_id"]
            ?? data["messageId"]
            ?? request.content.userInfo["gcm.message_id"] as? String
            ?? ""

        if let appGroup = appGroup, !appGroup.isEmpty, !messageId.isEmpty {
            Task.detached(priority: .utility) {
                _ = await ColdStartAckSender.send(
                    messageId: messageId,
                    event: .delivered,
                    appGroup: appGroup
                )
            }
        }

        renderContent(data: data, content: content) { rendered in
            if !messageId.isEmpty {
                SwanLogger.info("[SwanSDK] Notification displayed successfully with ID: \(messageId)")
            }
            completion(rendered)
        }
    }

    /// Internal test-seam — lets unit tests inject mock renderers without
    /// touching the URLSession-backed default fetcher. NOT part of the
    /// public API.
    internal static func renderContent(
        data: [String: String],
        content: UNMutableNotificationContent,
        basicRenderer: BasicTemplateRenderer,
        carouselRenderer: CarouselTemplateRenderer,
        completion: @escaping (UNMutableNotificationContent?) -> Void
    ) {
        let template = NotificationTemplate.from(data)
        switch template {
        case .basic:
            basicRenderer.render(data: data, into: content) { rendered in
                completion(rendered)
            }
        case .carouselManual, .carouselAuto:
            let payload = CarouselPayloadParser.parseIfCarousel(data) ?? CarouselPayload(
                items: [],
                mode: template,
                variant: .standard,
                intervalMs: CarouselPayload.DEFAULT_INTERVAL_MS,
                defaultRoute: data["defaultRoute"] ?? ""
            )
            carouselRenderer.render(data: data, payload: payload, into: content) { rendered in
                completion(rendered)
            }
        }
    }
    #endif

    /// Parse a raw notification `data` map into a typed
    /// ``CarouselPayload``. Returns `nil` when the map is not a carousel
    /// payload (`data.notificationType != "carousel"`).
    ///
    /// Surfaced for host-app-owned Notification Content Extensions that
    /// want to render a full swipeable carousel UI on top of the data
    /// shape the SDK delivers. See `platforms/ios/EXTENSIONS.md` for
    /// the Content Extension template.
    public static func parseCarousel(_ data: [String: String]) -> CarouselPayloadPublic? {
        guard let parsed = CarouselPayloadParser.parseIfCarousel(data) else { return nil }
        let mode: CarouselPayloadPublic.Mode = parsed.mode == .carouselAuto ? .auto : .manual
        let variant: CarouselPayloadPublic.Variant = parsed.variant == .filmstrip ? .filmstrip : .standard
        return CarouselPayloadPublic(
            items: parsed.items.map { item in
                CarouselPayloadPublic.Item(
                    imageURL: item.imageUrl,
                    title: item.title,
                    body: item.body,
                    route: item.route
                )
            },
            mode: mode,
            variant: variant,
            intervalMs: parsed.intervalMs,
            defaultRoute: parsed.defaultRoute
        )
    }

    /// Resolve which template the SDK would render for a `data` map.
    /// Pure helper for hosts that want to gate behavior on the template
    /// type WITHOUT triggering a render.
    public static func templateType(_ data: [String: String]) -> TemplateType {
        switch NotificationTemplate.from(data) {
        case .basic: return .basic
        case .carouselManual: return .carouselManual
        case .carouselAuto: return .carouselAuto
        }
    }

    /// Public mirror of ``NotificationTemplate`` so the SDK's internal
    /// enum can change without breaking the host-facing API.
    public enum TemplateType: String, Sendable, Equatable {
        case basic
        case carouselManual
        case carouselAuto
    }

    /// Public, host-facing carousel payload shape. Independent of the
    /// internal ``CarouselPayload`` so the public surface can evolve
    /// (e.g. add Codable conformance later) without coupling to
    /// internal type changes.
    public struct CarouselPayloadPublic: Sendable, Equatable {
        public struct Item: Sendable, Equatable {
            public let imageURL: String
            public let title: String
            public let body: String
            public let route: String
        }
        public enum Mode: String, Sendable, Equatable { case manual, auto }
        public enum Variant: String, Sendable, Equatable { case standard, filmstrip }

        public let items: [Item]
        public let mode: Mode
        public let variant: Variant
        public let intervalMs: Int
        public let defaultRoute: String

        /// Route for the item at `index`, with empty-route fallback to
        /// the outer `defaultRoute`. Mirrors the Android per-item route
        /// resolution.
        public func route(forItemAt index: Int) -> String {
            guard index >= 0, index < items.count else { return defaultRoute }
            let r = items[index].route
            return r.isEmpty ? defaultRoute : r
        }
    }
}
