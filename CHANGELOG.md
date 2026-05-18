# Swan iOS SDK — Changelog

## [ios/1.3.2] — 2026-05-18

**Distribution:** Swift Package Manager and CocoaPods (`pod 'SwanSDK', '~> 1.3'`)
**Deployment target:** iOS 13.0+ · Swift 5.9+ · Xcode 15+

### Fixed

- **Swift Package Manager resolution.** Installing via SPM with `.package(url: "https://github.com/SwanCX/swan-ios-sdk", from: "1.3.2")` (or pinning by version range in Xcode → File → Add Packages…) now resolves a concrete version. The 1.3.0 and 1.3.1 mirrors used a non-SemVer tag scheme that SPM could not interpret as a version. From 1.3.2 forward, the distribution repo uses plain SemVer tags (`1.3.2`, …). CocoaPods installs (`pod 'SwanSDK', '~> 1.3'`) were unaffected by this issue and continue to work — this release only changes how SPM discovers versions.

---
