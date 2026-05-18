# Swan iOS SDK — Changelog

## [ios/1.3.0] — 2026-05-18

**Distribution:** Swift Package Manager and CocoaPods (`pod 'SwanSDK', '~> 1.3'`)
**Deployment target:** iOS 13.0+ · Swift 5.9+ · Xcode 15+

### Fixed

- **Carousel Content Extension now renders on iOS 26.** The `UNNotificationContentExtension` principal-class lookup is strict Obj-C on iOS 26 — Swift-mangled `Module.ClassName` Info.plist values no longer resolve. Fix requires `@objc(StableName)` on the class + bare name in Info.plist. The new `platforms/ios/EXTENSIONS.md` documents this for customer integrators.
- **Carousel per-item routing.** Tapping a specific carousel slide now resolves to that item's route, not the outer `defaultRoute`. The SDK now reads the App Group click-data the Content Extension persists and overrides `data["route"]` before firing `addNotificationOpenedListener`.
- **Cold-start tap fired listener twice.** When iOS cold-launched the app via a notification tap, the same payload could arrive via both `launchOptions[.remoteNotification]` and `userNotificationCenter(_:didReceive:withCompletionHandler:)`. The router's `ProcessedClickStore` dedup gate now engages on the messageId extracted from the payload (previously the gate was bypassed because the caller didn't pass an explicit `messageId`).
- **Pre-init listener subscriptions in the test harness.** PR #67 patched the production bootstrap to drain pending listeners; the test seam (`makeInternalsForTests`) had the same gap. Unit tests subscribing pre-init now see their listeners attach correctly.
- **`ProcessedClickStore` whitespace bypass.** Trailing or leading whitespace on a messageId could bypass dedup because the store stored/looked up the raw id. Now both paths trim consistently.
- **`KeyValueStore.clear()` over-broad.** In App Group mode, `clear()` iterated all keys including NSGlobalDomain, wiping unrelated SDK / extension data sharing the suite. Now uses an explicit allowlist of Swan-owned keys.
- **NSE `ColdStartAckSender` first-launch silent drop.** When the NSE fires before the host has ever run, the App Group has no credentials and the ACK is dropped — now logged at `.warn` with explicit guidance, not silently at `.debug`.
- **NCE controller `tapHandled` flag stale across recycled instances.** iOS reuses NCE controllers between notifications; the flag now resets on every `didReceive(_:)` so per-item click data is captured for each notification.
- **`NotificationRouter` listener-identity uses UUIDs.** Previously the unregister closure used `unsafeBitCast`-based closure pointer comparison, which is implementation-defined for `@Sendable` value closures. Now each registration has a stable UUID; unregister is deterministic.
- **`SessionTracker` no longer over-fires on control-center / Face ID / screenshot interruptions.** Switched from `willResignActive` to `didEnterBackground` — `willResignActive` fires on every transient inactive transition and was triggering spurious flushes + leaving the periodic-flush task stuck paused.
- **Carousel click-data stale routing when `handleNotificationUserInfo` is called without an explicit `messageId`.** Hosts that forward `userInfo` only (without passing the message identifier as a separate argument) could see a previous notification's stored carousel click route applied to the current tap. The SDK now resolves a fallback `messageId` from the payload's `messageId` / `gcm.message_id` keys before consulting the click-data gate.

### Changed

- **Sample app's `willPresent` handler no longer forwards to `handleNotificationUserInfo`.** Foreground delivery is now ACK-only; the "opened" listener fires only from `didReceive(response:)` (an actual tap). `EXTENSIONS.md §3.5` documents this distinction.
- **Sample app's cold-start `launchOptions[.remoteNotification]` forwarding removed.** `didReceive(response:)` is iOS's canonical cold-start path; the legacy forwarding was creating a duplicate delivery path.
- **NSE bundle hardcoded App Group literal replaced with named constant** pinning it to `SwanConfig.appGroup` + entitlements.

### Added

- **`platforms/ios/EXTENSIONS.md`** — customer-facing host-integration guide for Notification Service Extension + Notification Content Extension, including iOS 26-specific requirements (`@objc(StableName)`, `UserNotificationsUI.framework` link), `willPresent`/`didReceive` semantics, per-item carousel deep-link wiring, and a troubleshooting matrix.
- **Sample Notification Content Extension target** in `SampleAppXcode/` so customers have a working reference implementation (3-image carousel with page control + per-item tap routing).
- **5 new regression tests**: pre-init listener fire, carousel per-item route override, cold-start dedup, ProcessedClickStore whitespace, listener-identity unregister.

### Verified end-to-end on real device

iPhone 17 Pro / iOS 26.4.2 with real APNs HTTP/2 delivery:

| State | Banner | Carousel default-route | Carousel per-item |
|---|---|---|---|
| Foreground | ✓ | ✓ | ✓ |
| Background | ✓ | ✓ | ✓ |
| Killed (cold-start) | ✓ | ✓ | ✓ |

NSE delivery ACK, Content Extension long-press, swipe between slides, tap slide → app cold-launches with correct per-item route — all confirmed.

---
