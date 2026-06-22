# Swan iOS SDK — Changelog

## [ios/1.5.0] — 2026-06-19

**Distribution:** Swift Package Manager and CocoaPods (`pod 'SwanSDK', '~> 1.5'`)
**Deployment target:** iOS 13.0+ · Swift 5.9+ · Xcode 15+

### Fixed

- **`login()` now triggers the full backend pipeline.** Previously a `login()` call suppressed the backend's downstream side-effects (cart, journey, and messaging triggers) in the same way `identify()` does. `login()` now runs the complete pipeline, so logging a user in fires those side-effects as expected. `identify()` is unchanged and continues to switch the profile without those side-effects.

---
