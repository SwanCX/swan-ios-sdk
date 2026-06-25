# Swan iOS SDK — Changelog

## [ios/1.5.1] — 2026-06-25

**Distribution:** Swift Package Manager and CocoaPods (`pod 'SwanSDK', '~> 1.5'`)
**Deployment target:** iOS 13.0+ · Swift 5.9+ · Xcode 15+

### Changed

- **Device registration resolves the device identifier more robustly.** The SDK now reliably obtains the device identifier when registering, so the identifier is consistently available for events and attribution.

---
