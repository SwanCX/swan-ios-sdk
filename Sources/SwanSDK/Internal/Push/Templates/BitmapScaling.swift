import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(ImageIO)
import ImageIO
#endif
#if canImport(MobileCoreServices)
import MobileCoreServices
#endif

/// Image-on-disk downscaling helper for the push template renderers.
///
/// **Capabilities:** `push-template-basic`, `push-carousel-manual`,
/// `push-carousel-auto`.
///
/// # iOS vs Android divergence
///
/// On Android the rich-notification rendering pathway is *RemoteViews*,
/// which serializes the bitmap through a Binder Parcel. The Parcel has a
/// hard ~2MB cap (Android `CarouselTemplate.kt:323-337` references this).
/// We MUST scale on Android to stay under that cap or `setLargeIcon`
/// silently no-ops on API ≤33.
///
/// On iOS, a notification attachment is a *file URL* — the OS streams
/// the image from disk at render time and there is no equivalent IPC
/// cap. The reason we still downscale here is the Notification Service
/// Extension's ~24MB RAM budget: a carousel of 10 raw 4032×3024 JPEGs
/// would OOM-kill the extension before it finished decoding. Downscaling
/// to 1024px long-edge brings each item under ~250KB while keeping the
/// big-picture preview crisp on the largest iPhone display.
///
/// # Algorithm
///
/// 1. Use `CGImageSourceCreateThumbnailAtIndex` rather than
///    `UIImage.draw(in:)`. The Image I/O thumbnail path decodes at the
///    target size directly — never materializes the full-resolution
///    bitmap in memory. Critical for NSE memory safety.
/// 2. Write the thumbnail back to disk as JPEG (quality 0.85) and
///    return the new file URL. The renderer points
///    `UNNotificationAttachment(url:)` at the scaled file.
///
/// # macOS gracefulness
///
/// `swift test` runs on macOS, so the SDK module needs to compile
/// without UIKit. The non-UIKit branch returns `nil` — the caller falls
/// back to the original (unscaled) file. Tests assert the scaling
/// trigger via the threshold-bytes check, not pixel dimensions.
internal enum BitmapScaling {

    /// Downscale the image at `url` so its long edge ≤ `maxPixelDim`,
    /// write the result to a new file, and return the new file URL.
    ///
    /// Returns `nil` when scaling is unavailable (non-iOS build) or any
    /// step fails. The caller MUST treat `nil` as "use the original
    /// file" — this is a soft-fail optimization, not a correctness
    /// requirement.
    static func scaleIfNeeded(
        at url: URL,
        maxPixelDim: CGFloat,
        pathExtension: String
    ) -> URL? {
        #if canImport(ImageIO)
        return scaleViaImageIO(at: url, maxPixelDim: maxPixelDim, pathExtension: pathExtension)
        #else
        return nil
        #endif
    }

    #if canImport(ImageIO)
    private static func scaleViaImageIO(
        at url: URL,
        maxPixelDim: CGFloat,
        pathExtension: String
    ) -> URL? {
        let opts: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, opts as CFDictionary) else {
            SwanLogger.warn("BitmapScaling: failed to open image source at \(url.lastPathComponent)")
            return nil
        }
        let thumbOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelDim,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOpts as CFDictionary) else {
            SwanLogger.warn("BitmapScaling: failed to generate thumbnail")
            return nil
        }

        // Write the thumbnail back to a sibling file. Reuse extension
        // (jpg/png) so the file's UTI hint stays meaningful.
        let dest = url.deletingLastPathComponent()
            .appendingPathComponent("swan-scaled-\(UUID().uuidString).\(pathExtension)")

        let utiString: CFString
        switch pathExtension.lowercased() {
        case "png":
            utiString = "public.png" as CFString
        case "gif":
            // Animated GIF preservation isn't supported via the thumbnail
            // path — we'd lose frames. Fall through: encode as JPEG.
            utiString = "public.jpeg" as CFString
        default:
            utiString = "public.jpeg" as CFString
        }

        guard let writer = CGImageDestinationCreateWithURL(dest as CFURL, utiString, 1, nil) else {
            SwanLogger.warn("BitmapScaling: failed to create destination")
            return nil
        }
        let writeOpts: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.85,
        ]
        CGImageDestinationAddImage(writer, thumb, writeOpts as CFDictionary)
        if !CGImageDestinationFinalize(writer) {
            SwanLogger.warn("BitmapScaling: finalize failed")
            try? FileManager.default.removeItem(at: dest)
            return nil
        }
        return dest
    }
    #endif
}
