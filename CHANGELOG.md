# Swan iOS SDK — Changelog

## [ios/1.4.0] — 2026-05-19

**Distribution:** Swift Package Manager and CocoaPods (`pod 'SwanSDK', '~> 1.4'`)
**Deployment target:** iOS 13.0+ · Swift 5.9+ · Xcode 15+

### Added

- **Expanded Objective-C surface on `SwanObjC`.** Mixed-language host apps can now drive most of the customer-facing SDK from Obj-C call sites without writing a Swift bridging file. The previous facade covered initialization, identity basics, custom event tracking, super-properties, and APNs token registration — about a fifth of the public surface. The new entries close the gap:
  - **Async via completion handlers** (Obj-C cannot call Swift `async` directly): `loginWithCompletion`, `requestNotificationPermissionWithCompletion`, `hasNotificationPermissionWithCompletion`, `isPushEnabledWithCompletion`. Each completes on the main thread.
  - **Device + session state:** `getDeviceInfo` (returns an `NSDictionary` mirror of `SwanDeviceInfo`, with nested location dictionary if a location has been supplied), `getCurrentSessionId`, `getQueueSize`.
  - **Location:** `updateLocation:longitude:accuracy:` (negative `accuracy` to omit), `isLocationEnabled`.
  - **Push handling:** `handleDeepLink:`, `handleNotificationUserInfo:` (and a `messageId:` overload), `handleNotificationTap:` (same), `handlePushNotificationUserInfo:`, `unsubscribePush`, `ackPushDelivered:`, `ackPushClicked:type:linkId:`, `flushPendingAcks`.
  - **Notification categories + badge:** `createNotificationChannelWithId:name:importance:soundName:`, `deleteNotificationChannelWithId:`, `getNotificationChannelId`, `getBadgeCount`, `setBadgeCount:`.
  - **Lifecycle:** `addInitializedListener:`.

  Listeners that emit typed Swift-struct payloads (`addNotificationOpenedListener`, `addDeepLinkOpenedListener`, the telemetry-event listeners) remain Swift-only — host apps that need them write a small Swift bridging file to adapt the payload into NSObjects. The expanded `Objective-C host apps` section of the [iOS getting-started guide](/docs/getting-started/ios#objective-c-host-apps) shows the full new surface.

---
