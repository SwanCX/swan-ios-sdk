import Foundation

/// Canonical event-name constants emitted on the wire.
///
/// Source-of-truth: `swan-react-native-sdk/src/index.tsx:71-107` (`ECOM_EVENTS`).
///
/// Spec: `spec/api/events.yaml` (descriptions), `spec/wire/event-ingest.yaml`
/// (`BatchEvent.name` semantics), `spec/wire/golden/event-ingest-batch.json`.
///
/// **TYPOS ARE LOAD-BEARING.** Two names are misspelled in the canonical RN
/// event schema, and the backend's `eventsSchema.ts` keys those misspellings
/// verbatim. Renaming would break wire parity and silently drop events:
///
///   - ``productAddedToAddToCart`` = `productAddedToaddTocart`
///     (extra "addTo", lowercase 'cart'). Backend: `eventsSchema.ts`,
///     normalized via `name.toLowerCase()` to `productaddedtoaddtocart` in
///     `eventNames.ts:11`.
///   - ``orderExperianceRating`` = `orderExperianceRating`
///     ("Experiance" not "Experience"). Backend: `eventsSchema.ts`.
///
/// The public API method names ARE corrected (``SwanEvents/productAddedToAddTocart(attributes:)``,
/// ``SwanEvents/orderExperianceRating(attributes:)``) — only the wire string
/// preserves the typo. See `spec/api/events.yaml` summaries for each method.
///
/// Mirror of Android's `EventNames.kt` (`platforms/android/sdk/src/main/kotlin/
/// cx/swan/sdk/internal/events/EventNames.kt`). Held internal — only
/// ``SwanEvents`` and ``EventTracker`` reference it.
internal enum EventNames {

    // MARK: - Lifecycle / identity (emitted by trackEvent on the standard path)
    static let appLaunched = "appLaunched"
    static let appUpdated = "appUpdated"
    static let accountDeletion = "accountDeletion"
    static let forgotPassword = "forgotPassword"
    /// Emitted by identify-login port — NOT custom-events. Kept here for
    /// the reserved-name registry only.
    static let userLogin = "userLogin"
    /// Emitted by logout-profile-reset port — NOT custom-events.
    static let userLogout = "userLogout"

    // MARK: - Search / browse
    static let search = "search"
    static let screen = "screen"
    static let share = "share"

    // MARK: - Product
    static let productViewed = "productViewed"
    static let productClicked = "productClicked"
    static let productListViewed = "productListViewed"
    static let productRatedOrReviewed = "productRatedOrReviewed"
    static let productReview = "productReview"
    static let productQuantitySelected = "productQuantitySelected"

    // MARK: - Cart (TYPO: extra "addTo", lowercase 'cart' — preserve verbatim)
    static let productAddedToAddToCart = "productAddedToaddTocart"
    static let productRemovedFromAddToCart = "productRemovedFromAddToCart"
    static let clearCart = "clearCart"
    static let cartViewed = "cartViewed"

    // MARK: - Category
    static let selectCategory = "selectCategory"
    static let categoryViewedPage = "categoryViewedPage"

    // MARK: - Wishlist
    static let productAddedToWishlist = "productAddedToWishlist"
    static let productRemovedFromWishlist = "productRemovedFromWishlist"
    static let wishlistProductAddedToCart = "wishlistProductAddedToCart"

    // MARK: - Checkout / order
    static let offerAvailed = "offerAvailed"
    static let checkoutStarted = "checkoutStarted"
    static let checkoutCompleted = "checkoutCompleted"
    static let checkoutCanceled = "checkoutCanceled"
    static let paymentInfoEntered = "paymentInfoEntered"
    static let purchased = "purchased"
    static let shipped = "shipped"
    static let orderCompleted = "orderCompleted"
    static let orderRefunded = "orderRefunded"
    static let orderCancelled = "orderCancelled"

    // MARK: - TYPO: "Experiance" preserved verbatim per backend schema
    static let orderExperianceRating = "orderExperianceRating"

    /// Reserved internal names. These NEVER flow through the standard
    /// `/v2/trackEvent` batch — RN's `sendEventBatch` filters and routes them
    /// to dedicated endpoints. The custom-events port intentionally does not
    /// accept them as user-supplied names; the offline-queue port (Phase 1.8
    /// equivalent for iOS) will enforce the routing.
    ///
    /// See `spec/behavior/queue.yaml routing_by_eventName`.
    static let reserved: Set<String> = [
        "SWAN_NOTIFICATION_ACK",
        "PUSH_SUBSCRIBE",
        "PUSH_UNSUBSCRIBE",
        "PROFILE_ENRICH",
    ]
}
