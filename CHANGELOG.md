# Swan iOS SDK — Changelog

## [ios/1.3.1] — 2026-05-18

**Distribution:** Swift Package Manager and CocoaPods (`pod 'SwanSDK', '~> 1.3'`)
**Deployment target:** iOS 13.0+ · Swift 5.9+ · Xcode 15+

### Fixed

- **CocoaPods install now resolves.** The 1.3.0 spec referenced a source location CocoaPods Trunk could not read. 1.3.1 ships identical SDK code with a corrected source reference. Customers on `pod 'SwanSDK', '~> 1.3'` will pick this up automatically on the next `pod update`.

---
