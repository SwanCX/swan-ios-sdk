import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif

/// Renderer for ``NotificationTemplate/carouselManual`` and
/// ``NotificationTemplate/carouselAuto``.
///
/// **Capabilities:** `push-carousel-manual`, `push-carousel-auto`.
///
/// # v1 carousel limitation (DOCUMENTED DIVERGENCE FROM ANDROID)
///
/// Android renders the full carousel inside the system notification
/// shade via `RemoteViews` + `ViewFlipper` — the user sees all N images
/// without leaving the notification. iOS has no equivalent: rich
/// notification rendering is split between a Notification Service
/// Extension (which can only configure a *single* `UNMutableNotificationContent`
/// with one banner image) and an optional Notification Content
/// Extension (a separate target with a custom UIViewController, hooked
/// via `UNMutableNotificationContent.categoryIdentifier`).
///
/// **SDK v1 ships single-image-from-first-item rendering** in the NSE:
/// the carousel payload arrives, this renderer attaches the first item's
/// image (plus carousel-level title/body) to the notification content,
/// and stamps `categoryIdentifier = "swan_carousel"` so a host that
/// later adds a Notification Content Extension target picks it up
/// automatically.
///
/// Full carousel UX (swipe, page indicator, per-item rendering) is
/// **deferred** to a host-app-owned Notification Content Extension
/// template, documented in `platforms/ios/EXTENSIONS.md`. The SDK
/// surfaces the parsed ``CarouselPayload`` via
/// ``Templates/parseCarousel(_:)`` so host extensions can drop it into a
/// `UIViewController` without re-parsing.
///
/// # Per-image deep-link routing
///
/// Per-image routing IS preserved end-to-end: the SDK's
/// ``PushPayloadParser`` already prefers `data.route` over
/// `data.defaultRoute` (Phase 1.12). When a Notification Content
/// Extension wants to deep-link the visible item on tap, it calls
/// ``Swan/handleNotificationTap(_:messageId:)`` with a `data` map whose
/// `route` has been overridden to the tapped item's route — same wire
/// shape, same router emission. This sidesteps the RN v2.7 iOS
/// regression where per-image routes silently fell back to the outer
/// `defaultRoute` (root cause: RN's iOS handler keyed on the
/// notification's outer payload, not the item the user actually tapped).
///
/// # Auto-carousel limitation
///
/// `UNMutableNotificationContent` is static once delivered — no native
/// way to rotate an attachment on a timer. v1 renders the same
/// first-image preview for both manual and auto modes. Hosts that want
/// real auto-rotation implement it inside their Notification Content
/// Extension via a `Timer` over a `UICollectionView` cell stream
/// (`reference: RN ios/SwanNotificationContentExtension/templates/CarouselView.swift`).
internal final class CarouselTemplateRenderer {

    private let attachmentFetcher: AttachmentFetching

    /// APNs category the SDK stamps on carousel notifications so a host
    /// Notification Content Extension can hook them. Matches the server
    /// default at `PUSH-HTTP/index.js:189-191`.
    internal static let CAROUSEL_CATEGORY: String = "swan_carousel"

    init(attachmentFetcher: AttachmentFetching = URLSessionAttachmentFetcher()) {
        self.attachmentFetcher = attachmentFetcher
    }

    #if canImport(UserNotifications)

    /// Apply carousel-level title/body/sound, set the carousel category
    /// identifier, and attach the FIRST item's image (when present) to
    /// `content`. Calls `completion` exactly once.
    ///
    /// - Parameters:
    ///   - data: The flattened FCM-shaped data map.
    ///   - payload: The pre-parsed carousel payload — pass the result of
    ///     ``CarouselPayloadParser/parseIfCarousel(_:)``.
    ///   - content: The OS-provided mutable content to decorate.
    ///   - completion: Fires once the (optional) image fetch finishes.
    func render(
        data: [String: String],
        payload: CarouselPayload,
        into content: UNMutableNotificationContent,
        completion: @escaping (UNMutableNotificationContent) -> Void
    ) {
        applyTextFields(data: data, payload: payload, into: content)

        // Stamp the category so a future Notification Content Extension
        // (added by the host) hooks the right UN category — even if the
        // server's apns.payload.aps.category was missing for some reason.
        if content.categoryIdentifier.isEmpty {
            content.categoryIdentifier = CarouselTemplateRenderer.CAROUSEL_CATEGORY
        }

        // v1: render the FIRST item with a non-empty image URL. Items
        // with empty imageUrl are skipped because they'd produce no
        // banner image anyway (RN's iOS NSE has the same posture).
        let firstWithImage = payload.items.first(where: { !$0.imageUrl.isEmpty })
        guard let item = firstWithImage else {
            SwanLogger.debug("CarouselTemplateRenderer: no item has a non-empty imageUrl — text-only render")
            completion(content)
            return
        }

        attachmentFetcher.fetch(item.imageUrl) { fetched in
            guard let fetched = fetched else {
                completion(content)
                return
            }
            var options: [String: Any] = [:]
            if let uti = fetched.utiHint {
                options[UNNotificationAttachmentOptionsTypeHintKey] = uti
            }
            if let attachment = try? UNNotificationAttachment(
                identifier: "swan-carousel-\(UUID().uuidString)",
                url: fetched.localURL,
                options: options
            ) {
                content.attachments = [attachment]
            }
            completion(content)
        }
    }
    #endif

    // MARK: - Pure helpers

    /// Per-item route with outer-`defaultRoute` fallback. Mirrors
    /// Android `CarouselTemplateRenderer.routeForItem` /
    /// ``CarouselPayloadParser/routeForItem(_:index:)``.
    ///
    /// Exposed at this layer so a Notification Content Extension can
    /// resolve the tapped item's route without reaching into parser
    /// internals.
    func routeForItem(_ payload: CarouselPayload, index: Int) -> String {
        return CarouselPayloadParser.routeForItem(payload, index: index)
    }

    /// Return the carousel-level title/body the renderer would apply.
    /// Pure helper so unit tests can assert without
    /// `UserNotifications`.
    internal func deriveTextFields(
        data: [String: String],
        payload: CarouselPayload
    ) -> (title: String?, body: String?) {
        // Outer title/body — these are the OS-level banner strings.
        // Per-item title/body live inside the Notification Content
        // Extension (out of v1 scope; documented in EXTENSIONS.md).
        let outerTitle = (data["title"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let outerBody = (data["body"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // RN parity: when the outer title is blank, fall back to the
        // first item's title so the banner isn't empty.
        let firstItem = payload.items.first
        let title = outerTitle.isEmpty ? (firstItem?.title ?? "") : outerTitle
        let body = outerBody.isEmpty ? (firstItem?.body ?? "") : outerBody
        return (
            title: title.isEmpty ? nil : title,
            body: body.isEmpty ? nil : body
        )
    }

    #if canImport(UserNotifications)
    private func applyTextFields(
        data: [String: String],
        payload: CarouselPayload,
        into content: UNMutableNotificationContent
    ) {
        let (title, body) = deriveTextFields(data: data, payload: payload)
        if let title = title { content.title = title }
        if let body = body { content.body = body }
    }
    #endif
}
