# Swan iOS SDK — Changelog

## [ios/1.5.3] — 2026-09-22

**Distribution:** Swift Package Manager and CocoaPods (`pod 'SwanSDK', '~> 1.5'`)
**Deployment target:** iOS 13.0+ · Swift 5.9+ · Xcode 15+

### Fixed

- **Profile updates now always apply to the customer who was active when the update was made.** `enrichProfile()` is queued and sent in the background; previously, if a login or logout happened — or the send was retried — before the queue flushed, the update could be written against the wrong customer. Each queued update now carries the customer it was made for and is always applied to that customer.

---
