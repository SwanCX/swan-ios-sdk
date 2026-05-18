import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif

/// Renderer for ``NotificationTemplate/basic`` — sets title, body, sound,
/// badge, category, and optional image attachment on a
/// `UNMutableNotificationContent`.
///
/// **Capability:** `push-template-basic`.
///
/// Spec:
///   - `spec/wire/push-payload-fcm.yaml#FcmDataField` — `title`, `body`,
///     `image`, `sound`, `category` fields.
///   - `conformance/scenarios/push-template-basic.feature`:
///     1. tier1 "Basic Android payload bytes match the golden" — wire-only.
///     2. tier2 "Standard notification rendered with title + body" — this
///        renderer applies title/body to the NSE-mutable content.
///     3. tier2 "Image asset rendered when data.image is present" — this
///        renderer; downloads via ``AttachmentFetching`` and attaches as
///        `UNNotificationAttachment`; silent text-only fallback on
///        fetch failure.
///     4. tier2 "Tap on basic notification routes to data.defaultRoute" —
///        the tap path is owned by ``NotificationRouter`` /
///        ``Swan/handleNotificationUserInfo(_:messageId:)`` (unchanged);
///        this renderer doesn't manage tap routing.
///
/// # iOS vs Android divergences
///
/// - Android `BasicTemplateRenderer` builds a fresh
///   `NotificationCompat.Builder` because the SDK is invoked from the
///   FirebaseMessaging receiver, BEFORE the OS has any notification
///   object. On iOS the OS hands us a pre-populated
///   `UNMutableNotificationContent` (built from the APNs `aps.alert`
///   block) when the Notification Service Extension runs. We MUTATE
///   that object rather than constructing one from scratch — host apps
///   plug into the system-level notification path correctly even if
///   they don't call into `Templates.renderContent(...)`.
/// - No `setPriority` / channel concept — APNs priority is set by the
///   server in the `apns-priority` header; client cannot alter it.
/// - No `setAutoCancel` — iOS auto-cancels on tap by default.
/// - No `BigTextStyle` — iOS expands long bodies automatically when the
///   user 3D-touches / long-presses the banner. We DO populate
///   `subtitle` from `data.subtitle` when present so the second-line
///   surface is filled.
internal final class BasicTemplateRenderer {

    private let attachmentFetcher: AttachmentFetching

    init(attachmentFetcher: AttachmentFetching = URLSessionAttachmentFetcher()) {
        self.attachmentFetcher = attachmentFetcher
    }

    #if canImport(UserNotifications)

    /// Apply title/body/sound/badge/category + optional image attachment
    /// to `content` in place. `completion` fires on an arbitrary thread
    /// — the NSE's `didReceive` host code is responsible for calling
    /// `contentHandler(content)` from whichever thread is appropriate.
    ///
    /// The renderer guarantees `completion` is called exactly once, even
    /// on failure paths.
    func render(
        data: [String: String],
        into content: UNMutableNotificationContent,
        completion: @escaping (UNMutableNotificationContent) -> Void
    ) {
        applyStringFields(data: data, into: content)
        applyBadge(data: data, into: content)

        let imageURL = (data["image"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if imageURL.isEmpty {
            completion(content)
            return
        }

        attachmentFetcher.fetch(imageURL) { fetched in
            guard let fetched = fetched else {
                // RN parity (conformance: "no exception is raised when the
                // image fetch fails"): silent text-only fallback.
                completion(content)
                return
            }
            var options: [String: Any] = [:]
            if let uti = fetched.utiHint {
                options[UNNotificationAttachmentOptionsTypeHintKey] = uti
            }
            if let attachment = try? UNNotificationAttachment(
                identifier: "swan-image-\(UUID().uuidString)",
                url: fetched.localURL,
                options: options
            ) {
                content.attachments = [attachment]
            }
            completion(content)
        }
    }
    #endif

    // MARK: - Pure helpers (testable without UserNotifications)

    /// Build the [(field, value)] tuple list that the renderer would
    /// apply to a content. Pure so tests can assert behavior without
    /// importing UserNotifications.
    internal func deriveAssignments(data: [String: String]) -> Assignments {
        let title = (data["title"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let body = (data["body"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let subtitle = (data["subtitle"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let category = (data["category"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let sound = resolveSoundName(data["sound"])
        let badge: Int? = {
            guard let raw = data["badge"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty,
                  let n = Int(raw) else { return nil }
            return max(0, n)
        }()
        let imageURL: String? = {
            let raw = (data["image"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return raw.isEmpty ? nil : raw
        }()
        return Assignments(
            title: title.isEmpty ? nil : title,
            body: body.isEmpty ? nil : body,
            subtitle: subtitle.isEmpty ? nil : subtitle,
            category: category.isEmpty ? nil : category,
            sound: sound,
            badge: badge,
            imageURL: imageURL
        )
    }

    /// Resolve the iOS sound asset name per RN parity:
    /// undefined / null / "" → "default"; "default" → "default";
    /// "none" / "silent" → nil (no sound); other → "<name>.wav" appended
    /// when extension missing. Mirrors `getApnsSound`
    /// (PUSH-HTTP/index.js:52-58).
    internal func resolveSoundName(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let lowered = trimmed.lowercased()
        if trimmed.isEmpty || lowered == "default" { return "default" }
        if lowered == "none" || lowered == "silent" { return nil }
        // Custom — append .wav if no extension.
        if trimmed.contains(".") { return trimmed }
        return "\(trimmed).wav"
    }

    internal struct Assignments: Equatable {
        let title: String?
        let body: String?
        let subtitle: String?
        let category: String?
        let sound: String?
        let badge: Int?
        let imageURL: String?
    }

    #if canImport(UserNotifications)
    private func applyStringFields(
        data: [String: String],
        into content: UNMutableNotificationContent
    ) {
        let assignments = deriveAssignments(data: data)
        if let title = assignments.title { content.title = title }
        if let body = assignments.body { content.body = body }
        if let subtitle = assignments.subtitle { content.subtitle = subtitle }
        if let category = assignments.category { content.categoryIdentifier = category }
        if let sound = assignments.sound {
            // RN parity: explicit name → custom sound; "default" → default.
            if sound == "default" {
                content.sound = .default
            } else {
                content.sound = UNNotificationSound(named: UNNotificationSoundName(sound))
            }
        }
        // "none" / "silent" → leave content.sound nil; per APNs semantics
        // an explicitly omitted sound silences the banner. Don't reset
        // an existing default the OS set from aps.sound.
    }

    private func applyBadge(
        data: [String: String],
        into content: UNMutableNotificationContent
    ) {
        let assignments = deriveAssignments(data: data)
        if let badge = assignments.badge {
            content.badge = NSNumber(value: badge)
        }
    }
    #endif
}
