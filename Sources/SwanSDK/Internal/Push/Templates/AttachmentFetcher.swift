import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif

/// Async fetcher that downloads a remote image and returns a local file
/// URL on disk that ``UNNotificationAttachment`` can ingest. Test seam
/// for the `push-template-basic` + `push-carousel-manual` +
/// `push-carousel-auto` renderers.
///
/// The result includes the recommended UTI hint string so the renderer
/// can pass `UNNotificationAttachmentOptionsTypeHintKey` to
/// `UNNotificationAttachment(identifier:url:options:)` (matters on iOS
/// 13/14 — without the hint the OS sometimes refuses the attachment).
///
/// Failure semantics:
///   - Blank / un-parseable URL → completion fires with `nil`.
///   - Network failure / non-2xx → completion fires with `nil`.
///   - Filesystem write failure → completion fires with `nil`.
///
/// The renderer is responsible for falling back to title-only rendering
/// on `nil`. Mirrors the Android `ImageFetcher.fetch` posture (failure =
/// silent text-only fallback, NEVER throws).
internal struct FetchedAttachment: Equatable {
    /// Local file URL the fetcher wrote the image to. Lives in the NSE
    /// temp directory; the OS cleans these up when the extension exits.
    let localURL: URL

    /// MIME-derived UTI string (e.g. `public.jpeg`, `public.png`,
    /// `com.compuserve.gif`) suitable for
    /// `UNNotificationAttachmentOptionsTypeHintKey`. `nil` when the
    /// response gave us no MIME and the URL extension didn't hint either
    /// — the OS will still accept the attachment, just without the hint.
    let utiHint: String?

    /// Byte size of the file on disk. Surfaced for tests so they can
    /// assert the bitmap downscale path triggered.
    let byteSize: Int64
}

/// Protocol so the renderer can be unit-tested without the network.
internal protocol AttachmentFetching {
    /// Download `url` and write to a local file. Calls `completion` on
    /// an arbitrary thread (not necessarily the caller's). MUST NOT
    /// throw — pass `nil` on any failure.
    func fetch(_ urlString: String, completion: @escaping (FetchedAttachment?) -> Void)
}

/// Production implementation — URLSession-backed download + temp-dir
/// write.
///
/// # Bitmap scaling threshold
///
/// iOS's per-attachment hard cap is 5MB for images. The Notification
/// Service Extension's process is limited to ~24MB RAM total. We
/// downscale to keep memory safe (especially in carousel mode where N
/// images load) when an image exceeds ``URLSessionAttachmentFetcher/SCALE_THRESHOLD_BYTES``.
/// Downscale targets ``URLSessionAttachmentFetcher/MAX_PIXEL_DIM`` on the
/// long edge.
///
/// This is materially more permissive than Android's per-image budget
/// (~2MB parcel limit) because iOS images are an attachment URL passed by
/// reference, not serialized into a Parcel. The threshold here exists to
/// protect NSE RAM, not the IPC channel.
///
/// Implementation note: actual Core Graphics downscaling is gated on
/// `#if canImport(UIKit)` so the SDK still compiles in the macOS test
/// sandbox. On macOS the fetcher returns the raw file unchanged.
internal final class URLSessionAttachmentFetcher: AttachmentFetching {

    /// Above this byte size we attempt to downscale before handing the
    /// file to ``UNNotificationAttachment``. 1.5MB picked as a safe
    /// midpoint between Apple's 5MB hard cap and the NSE's 24MB total
    /// RAM ceiling — leaves headroom for a carousel of up to ~10 items
    /// to all fit in memory simultaneously.
    internal static let SCALE_THRESHOLD_BYTES: Int64 = 1_500_000

    /// Max pixel dimension (long edge) after downscale. 1024 keeps the
    /// big-picture preview crisp on the largest iPhone Pro Max display
    /// without bloating the working set.
    internal static let MAX_PIXEL_DIM: CGFloat = 1024

    /// Per-image network timeout. Chosen to keep total NSE time under
    /// the 30s budget when fetching ≤10 carousel items in parallel.
    internal static let REQUEST_TIMEOUT: TimeInterval = 8.0

    private let session: URLSession

    init(session: URLSession = URLSession.shared) {
        self.session = session
    }

    func fetch(
        _ urlString: String,
        completion: @escaping (FetchedAttachment?) -> Void
    ) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else {
            SwanLogger.warn("AttachmentFetcher: blank or invalid URL — \(urlString)")
            completion(nil)
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = URLSessionAttachmentFetcher.REQUEST_TIMEOUT

        let task = session.downloadTask(with: request) { tempURL, response, error in
            if let error = error {
                SwanLogger.warn("AttachmentFetcher: download error: \(error.localizedDescription)")
                completion(nil)
                return
            }
            guard let tempURL = tempURL else {
                SwanLogger.warn("AttachmentFetcher: nil download location")
                completion(nil)
                return
            }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                SwanLogger.warn("AttachmentFetcher: non-2xx status \(http.statusCode)")
                completion(nil)
                return
            }

            let (extName, uti) = resolveTypeHint(response: response, url: url)
            let destinationURL = makeDestinationURL(pathExtension: extName)

            let fileManager = FileManager.default
            do {
                if fileManager.fileExists(atPath: destinationURL.path) {
                    try fileManager.removeItem(at: destinationURL)
                }
                try fileManager.copyItem(at: tempURL, to: destinationURL)
                let attrs = try fileManager.attributesOfItem(atPath: destinationURL.path)
                let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
                if size == 0 {
                    SwanLogger.warn("AttachmentFetcher: downloaded file is empty")
                    try? fileManager.removeItem(at: destinationURL)
                    completion(nil)
                    return
                }

                // Downscale large images so NSE RAM doesn't blow.
                let finalURL: URL
                let finalSize: Int64
                if size > URLSessionAttachmentFetcher.SCALE_THRESHOLD_BYTES,
                   let scaled = BitmapScaling.scaleIfNeeded(
                       at: destinationURL,
                       maxPixelDim: URLSessionAttachmentFetcher.MAX_PIXEL_DIM,
                       pathExtension: extName
                   ) {
                    // Replace the original temp file with the scaled one
                    // so we don't leak two files for one attachment.
                    try? fileManager.removeItem(at: destinationURL)
                    finalURL = scaled
                    let scaledAttrs = try fileManager.attributesOfItem(atPath: scaled.path)
                    finalSize = (scaledAttrs[.size] as? NSNumber)?.int64Value ?? size
                } else {
                    finalURL = destinationURL
                    finalSize = size
                }
                completion(FetchedAttachment(localURL: finalURL, utiHint: uti, byteSize: finalSize))
            } catch {
                SwanLogger.warn("AttachmentFetcher: filesystem error \(error.localizedDescription)")
                completion(nil)
            }
        }
        task.resume()
    }
}

/// Determine `(pathExtension, utiHint)` from response MIME with URL
/// extension fallback. Defaults to JPEG which is what Notifee assumes
/// when neither hint is available.
private func resolveTypeHint(response: URLResponse?, url: URL) -> (String, String?) {
    if let mime = response?.mimeType?.lowercased() {
        switch mime {
        case "image/jpeg", "image/jpg":
            return ("jpg", "public.jpeg")
        case "image/png":
            return ("png", "public.png")
        case "image/gif":
            return ("gif", "com.compuserve.gif")
        default:
            break
        }
    }
    switch url.pathExtension.lowercased() {
    case "png": return ("png", "public.png")
    case "gif": return ("gif", "com.compuserve.gif")
    case "jpg", "jpeg": return ("jpg", "public.jpeg")
    default: return ("jpg", nil)
    }
}

/// Build a unique file URL under the NSE-friendly caches directory.
private func makeDestinationURL(pathExtension: String) -> URL {
    let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSTemporaryDirectory())
    let uniqueId = UUID().uuidString
    return cacheDir.appendingPathComponent("swan-notification-\(uniqueId).\(pathExtension)")
}
