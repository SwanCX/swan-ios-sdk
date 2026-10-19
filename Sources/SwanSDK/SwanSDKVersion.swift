import Foundation

/// The SDK version stamped on the wire as `common.sdkVersion` on every
/// event-ingest and identity call.
///
/// This MUST equal `s.version` in `SwanSDK.podspec` — the podspec is the
/// single source of truth for the released version, and the release
/// workflow asserts it matches the git tag. `scripts/check-ios-sdk-version.sh`
/// fails CI (and the release) if the two drift. Bump both together when
/// cutting a release.
enum SwanSDKVersion {
    static let current = "1.5.4"
}
