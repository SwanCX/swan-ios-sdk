import Foundation

/// Typed semantic e-commerce event helpers.
///
/// **Capability:** `semantic-ecommerce-events`.
///
/// Spec: `spec/api/events.yaml`, `spec/locked-decisions.md` (typo names are
/// load-bearing), `conformance/scenarios/semantic-ecommerce-events.feature`.
///
/// Each method delegates to ``Swan/track(_:attributes:)`` with a fixed
/// canonical event name. The TYPO names below (`productAddedToaddTocart`,
/// `orderExperianceRating`) are the wire contract — DO NOT rename. Backend's
/// `eventsSchema.ts` keys those misspellings verbatim.
///
/// Method names ARE corrected (``productAddedToAddTocart(attributes:)``,
/// ``orderExperianceRating(attributes:)``) so call-site code doesn't
/// propagate the typo. Only the wire string preserves the typo.
///
/// All methods accept an optional `[String: JSONValue]` for type-safe
/// attributes. Most callers will use the convenience `[String: Any]`
/// overload — see ``Swan/track(_:attributes:)-9zo5p`` for the conversion
/// rules.
///
/// ## iOS-vs-Android divergence
///
/// Android exposes `SwanEvents` as a Kotlin `object` with `@JvmStatic`
/// methods so Java callers can write `SwanEvents.productViewed(...)`.
/// iOS uses a Swift enum-namespace (`enum SwanEvents` with no cases) —
/// idiomatic for stateless namespacing. Both compile to the same shape
/// at the call site.
public enum SwanEvents {

    // ─── Lifecycle ───

    /// wire `name = appLaunched`.
    public static func appLaunched(attributes: [String: JSONValue] = [:]) {
        Swan.shared.track(EventNames.appLaunched, attributes: attributes)
    }

    /// wire `name = appLaunched` — convenience `[String: Any]` overload.
    public static func appLaunched(attributes: [String: Any]) {
        Swan.shared.track(EventNames.appLaunched, attributes: attributes)
    }

    /// wire `name = appUpdated`.
    public static func appUpdated(attributes: [String: JSONValue] = [:]) {
        Swan.shared.track(EventNames.appUpdated, attributes: attributes)
    }

    public static func appUpdated(attributes: [String: Any]) {
        Swan.shared.track(EventNames.appUpdated, attributes: attributes)
    }

    /// wire `name = accountDeletion`.
    public static func accountDeletion(attributes: [String: JSONValue] = [:]) {
        Swan.shared.track(EventNames.accountDeletion, attributes: attributes)
    }

    public static func accountDeletion(attributes: [String: Any]) {
        Swan.shared.track(EventNames.accountDeletion, attributes: attributes)
    }

    /// wire `name = forgotPassword`.
    public static func forgotPassword(attributes: [String: JSONValue] = [:]) {
        Swan.shared.track(EventNames.forgotPassword, attributes: attributes)
    }

    public static func forgotPassword(attributes: [String: Any]) {
        Swan.shared.track(EventNames.forgotPassword, attributes: attributes)
    }

    /// wire `name = screen`. Manual screen-view event — not auto-tracked.
    public static func screen(attributes: [String: JSONValue] = [:]) {
        Swan.shared.track(EventNames.screen, attributes: attributes)
    }

    public static func screen(attributes: [String: Any]) {
        Swan.shared.track(EventNames.screen, attributes: attributes)
    }

    // ─── Search / share ───

    /// wire `name = search`. Standard caller payload: `{searchKeyword: String}`.
    public static func search(attributes: [String: JSONValue] = [:]) {
        Swan.shared.track(EventNames.search, attributes: attributes)
    }

    public static func search(attributes: [String: Any]) {
        Swan.shared.track(EventNames.search, attributes: attributes)
    }

    /// wire `name = share`.
    public static func share(attributes: [String: JSONValue] = [:]) {
        Swan.shared.track(EventNames.share, attributes: attributes)
    }

    public static func share(attributes: [String: Any]) {
        Swan.shared.track(EventNames.share, attributes: attributes)
    }

    // ─── Product ───

    /// wire `name = productViewed`.
    public static func productViewed(attributes: [String: JSONValue] = [:]) {
        Swan.shared.track(EventNames.productViewed, attributes: attributes)
    }

    public static func productViewed(attributes: [String: Any]) {
        Swan.shared.track(EventNames.productViewed, attributes: attributes)
    }

    /// wire `name = productClicked`.
    public static func productClicked(attributes: [String: JSONValue] = [:]) {
        Swan.shared.track(EventNames.productClicked, attributes: attributes)
    }

    public static func productClicked(attributes: [String: Any]) {
        Swan.shared.track(EventNames.productClicked, attributes: attributes)
    }

    /// wire `name = productListViewed`.
    public static func productListViewed(attributes: [String: JSONValue] = [:]) {
        Swan.shared.track(EventNames.productListViewed, attributes: attributes)
    }

    public static func productListViewed(attributes: [String: Any]) {
        Swan.shared.track(EventNames.productListViewed, attributes: attributes)
    }

    /// wire `name = productRatedOrReviewed`.
    public static func productRatedOrReviewed(attributes: [String: JSONValue] = [:]) {
        Swan.shared.track(EventNames.productRatedOrReviewed, attributes: attributes)
    }

    public static func productRatedOrReviewed(attributes: [String: Any]) {
        Swan.shared.track(EventNames.productRatedOrReviewed, attributes: attributes)
    }

    /// wire `name = productReview`.
    public static func productReview(attributes: [String: JSONValue] = [:]) {
        Swan.shared.track(EventNames.productReview, attributes: attributes)
    }

    public static func productReview(attributes: [String: Any]) {
        Swan.shared.track(EventNames.productReview, attributes: attributes)
    }

    /// wire `name = productQuantitySelected`.
    public static func productQuantitySelected(attributes: [String: JSONValue] = [:]) {
        Swan.shared.track(EventNames.productQuantitySelected, attributes: attributes)
    }

    public static func productQuantitySelected(attributes: [String: Any]) {
        Swan.shared.track(EventNames.productQuantitySelected, attributes: attributes)
    }

    // ─── Cart (TYPO load-bearing — see EventNames) ───

    /// wire `name = productAddedToaddTocart` (RN typo preserved on the wire;
    /// Swift method name is the corrected `productAddedToAddTocart`).
    ///
    /// Locked: the typo is the contract. See `spec/locked-decisions.md` and
    /// `conformance/scenarios/semantic-ecommerce-events.feature` scenario
    /// "productAddedToaddTocart preserves the RN typo on the wire".
    public static func productAddedToAddTocart(attributes: [String: JSONValue] = [:]) {
        Swan.shared.track(EventNames.productAddedToAddToCart, attributes: attributes)
    }

    public static func productAddedToAddTocart(attributes: [String: Any]) {
        Swan.shared.track(EventNames.productAddedToAddToCart, attributes: attributes)
    }

    /// wire `name = productRemovedFromAddToCart`.
    public static func productRemovedFromAddToCart(attributes: [String: JSONValue] = [:]) {
        Swan.shared.track(EventNames.productRemovedFromAddToCart, attributes: attributes)
    }

    public static func productRemovedFromAddToCart(attributes: [String: Any]) {
        Swan.shared.track(EventNames.productRemovedFromAddToCart, attributes: attributes)
    }

    /// wire `name = clearCart`. RN sends `{}` even with attributes — we
    /// match that behavior for parity.
    public static func clearCart() {
        Swan.shared.track(EventNames.clearCart, attributes: [String: JSONValue]())
    }

    /// wire `name = cartViewed`.
    public static func cartViewed(attributes: [String: JSONValue] = [:]) {
        Swan.shared.track(EventNames.cartViewed, attributes: attributes)
    }

    public static func cartViewed(attributes: [String: Any]) {
        Swan.shared.track(EventNames.cartViewed, attributes: attributes)
    }

    // ─── Category ───

    /// wire `name = selectCategory`.
    public static func selectCategory(attributes: [String: JSONValue] = [:]) {
        Swan.shared.track(EventNames.selectCategory, attributes: attributes)
    }

    public static func selectCategory(attributes: [String: Any]) {
        Swan.shared.track(EventNames.selectCategory, attributes: attributes)
    }

    /// wire `name = categoryViewedPage`.
    public static func categoryViewedPage(attributes: [String: JSONValue] = [:]) {
        Swan.shared.track(EventNames.categoryViewedPage, attributes: attributes)
    }

    public static func categoryViewedPage(attributes: [String: Any]) {
        Swan.shared.track(EventNames.categoryViewedPage, attributes: attributes)
    }

    // ─── Wishlist ───

    /// wire `name = productAddedToWishlist`.
    public static func productAddedToWishlist(attributes: [String: JSONValue] = [:]) {
        Swan.shared.track(EventNames.productAddedToWishlist, attributes: attributes)
    }

    public static func productAddedToWishlist(attributes: [String: Any]) {
        Swan.shared.track(EventNames.productAddedToWishlist, attributes: attributes)
    }

    /// wire `name = productRemovedFromWishlist`.
    public static func productRemovedFromWishlist(attributes: [String: JSONValue] = [:]) {
        Swan.shared.track(EventNames.productRemovedFromWishlist, attributes: attributes)
    }

    public static func productRemovedFromWishlist(attributes: [String: Any]) {
        Swan.shared.track(EventNames.productRemovedFromWishlist, attributes: attributes)
    }

    /// wire `name = wishlistProductAddedToCart`.
    public static func wishlistProductAddedToCart(attributes: [String: JSONValue] = [:]) {
        Swan.shared.track(EventNames.wishlistProductAddedToCart, attributes: attributes)
    }

    public static func wishlistProductAddedToCart(attributes: [String: Any]) {
        Swan.shared.track(EventNames.wishlistProductAddedToCart, attributes: attributes)
    }

    // ─── Checkout / order ───

    /// wire `name = offerAvailed`.
    public static func offerAvailed(attributes: [String: JSONValue] = [:]) {
        Swan.shared.track(EventNames.offerAvailed, attributes: attributes)
    }

    public static func offerAvailed(attributes: [String: Any]) {
        Swan.shared.track(EventNames.offerAvailed, attributes: attributes)
    }

    /// wire `name = checkoutStarted`.
    public static func checkoutStarted(attributes: [String: JSONValue] = [:]) {
        Swan.shared.track(EventNames.checkoutStarted, attributes: attributes)
    }

    public static func checkoutStarted(attributes: [String: Any]) {
        Swan.shared.track(EventNames.checkoutStarted, attributes: attributes)
    }

    /// wire `name = checkoutCompleted`.
    public static func checkoutCompleted(attributes: [String: JSONValue] = [:]) {
        Swan.shared.track(EventNames.checkoutCompleted, attributes: attributes)
    }

    public static func checkoutCompleted(attributes: [String: Any]) {
        Swan.shared.track(EventNames.checkoutCompleted, attributes: attributes)
    }

    /// wire `name = checkoutCanceled`.
    public static func checkoutCanceled(attributes: [String: JSONValue] = [:]) {
        Swan.shared.track(EventNames.checkoutCanceled, attributes: attributes)
    }

    public static func checkoutCanceled(attributes: [String: Any]) {
        Swan.shared.track(EventNames.checkoutCanceled, attributes: attributes)
    }

    /// wire `name = paymentInfoEntered`.
    public static func paymentInfoEntered(attributes: [String: JSONValue] = [:]) {
        Swan.shared.track(EventNames.paymentInfoEntered, attributes: attributes)
    }

    public static func paymentInfoEntered(attributes: [String: Any]) {
        Swan.shared.track(EventNames.paymentInfoEntered, attributes: attributes)
    }

    /// wire `name = orderCompleted`.
    public static func orderCompleted(attributes: [String: JSONValue] = [:]) {
        Swan.shared.track(EventNames.orderCompleted, attributes: attributes)
    }

    public static func orderCompleted(attributes: [String: Any]) {
        Swan.shared.track(EventNames.orderCompleted, attributes: attributes)
    }

    /// wire `name = orderRefunded`.
    public static func orderRefunded(attributes: [String: JSONValue] = [:]) {
        Swan.shared.track(EventNames.orderRefunded, attributes: attributes)
    }

    public static func orderRefunded(attributes: [String: Any]) {
        Swan.shared.track(EventNames.orderRefunded, attributes: attributes)
    }

    /// wire `name = orderCancelled`.
    public static func orderCancelled(attributes: [String: JSONValue] = [:]) {
        Swan.shared.track(EventNames.orderCancelled, attributes: attributes)
    }

    public static func orderCancelled(attributes: [String: Any]) {
        Swan.shared.track(EventNames.orderCancelled, attributes: attributes)
    }

    /// wire `name = orderExperianceRating` (RN typo preserved — "Experiance",
    /// not "Experience"). Locked: see `spec/locked-decisions.md`.
    public static func orderExperianceRating(attributes: [String: JSONValue] = [:]) {
        Swan.shared.track(EventNames.orderExperianceRating, attributes: attributes)
    }

    public static func orderExperianceRating(attributes: [String: Any]) {
        Swan.shared.track(EventNames.orderExperianceRating, attributes: attributes)
    }

    /// wire `name = purchased`.
    public static func purchased(attributes: [String: JSONValue] = [:]) {
        Swan.shared.track(EventNames.purchased, attributes: attributes)
    }

    public static func purchased(attributes: [String: Any]) {
        Swan.shared.track(EventNames.purchased, attributes: attributes)
    }

    /// wire `name = shipped`.
    public static func shipped(attributes: [String: JSONValue] = [:]) {
        Swan.shared.track(EventNames.shipped, attributes: attributes)
    }

    public static func shipped(attributes: [String: Any]) {
        Swan.shared.track(EventNames.shipped, attributes: attributes)
    }
}
