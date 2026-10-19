# Swan iOS SDK — Changelog

## [ios/1.5.4] — 2026-10-18

**Distribution:** Swift Package Manager and CocoaPods (`pod 'SwanSDK', '~> 1.5'`)
**Deployment target:** iOS 13.0+ · Swift 5.9+ · Xcode 15+

### Added

- **Carousel click receipts can say which card was tapped.** This applies when your own Notification Content Extension records card taps in your App Group under `swanTemplateClickData`; apps that show carousels only through the Notification Service Extension are not affected. Next to `route` in the click data your extension writes, add `itemIndex`: the tapped card's 0-based position in the push's `carouselItems`, which is `Templates.CarouselPayloadPublic.Item.position`. The click receipt for that tap then carries the same `itemIndex`, including when a receipt that failed to send is retried later. A tap on the notification itself, a standard push and the delivery receipt never carry `itemIndex`. Click data without `itemIndex` works as before: the card's route opens and the receipt doesn't say which card was tapped. **If your extension already writes `itemIndex`** (for example, one carried over from a React Native app), check it before you upgrade: the SDK now sends the value your extension writes, so it must be the card's `position` (not its index among the cards on screen) and must be left out when the tap didn't come from a card. See [Open the tapped card and report which card it was](/docs/guides/ios-extensions#open-the-tapped-card-and-report-which-card-it-was).
- **`Templates.CarouselPayloadPublic.Item.position`** — each parsed card's 0-based position in the push's `carouselItems`. In the filmstrip layout, cards without an image are left out of `items`, so a card's `position` can differ from its index in `items`. Write `position` as `itemIndex`.

### Fixed

- **A tapped carousel card now opens when your app passes the notification's own id.** If your app called `handleNotificationUserInfo(_:messageId:)` with `response.notification.request.identifier`, the SDK didn't match it to the card tap your Content Extension had recorded, so the push's `defaultRoute` opened instead of the tapped card's route. The SDK now matches the tap against the push's `messageId` / `gcm.message_id` as well as the id you pass. Apps that call `handleNotificationUserInfo(_:)` without a `messageId` were not affected.
- **A login the server reports as failed no longer changes who the device is signed in as.** When the server accepted a `login()` / `identify()` call but reported that it couldn't sign the customer in, the SDK still saved the new identifier. On a signed-out device, the device then looked signed in while its events stayed on the anonymous profile, and a later `logout()` did nothing, so the server was never told the customer had signed out. On a device already signed in as another customer, events stayed on that previous customer's profile, and calling `login()` again for the new customer was skipped as "already signed in". A failed login now leaves the device's identity as it was, the same as when the device is offline, and calling `login()` / `identify()` again retries it.
- **Events now report the SDK version your app ships.** Every event and identity call reported `sdkVersion` `2.7.3`, whichever iOS SDK release was installed, so data in Swan couldn't tell iOS SDK releases apart. The SDK now reports its own release version (`1.5.4` for this release). Devices on iOS SDK 1.5.3 or earlier keep reporting `2.7.3`.

---
