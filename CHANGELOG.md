# Swan iOS SDK — Changelog

## [ios/1.5.2] — 2026-08-18

**Distribution:** Swift Package Manager and CocoaPods (`pod 'SwanSDK', '~> 1.5'`)
**Deployment target:** iOS 13.0+ · Swift 5.9+ · Xcode 15+

### Fixed

- **Push delivery and click receipts are now reported reliably.** Previously, if the device was briefly offline the moment a push arrived — most often when the app had been force-closed, or when the receipt was sent from the Notification Service Extension — the delivery or click receipt could be lost, under-counting delivery and engagement. Receipts are now saved on the device as soon as a push is handled and are automatically retried the next time the app launches or returns to the foreground. Unsent receipts are retained for up to 7 days.
- **Push notifications are no longer delayed by receipt reporting.** Sending a delivery receipt no longer blocks the notification from being displayed, so a slow or unreachable network can no longer hold up the push.

---
