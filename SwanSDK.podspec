#
# SwanSDK CocoaPods spec.
#
# Mirrors the Swift Package Manager `Package.swift` shape so SPM and
# CocoaPods consumers see the same artifact. Pod name matches the
# Swift module name (SwanSDK).
#
# Lint:    pod lib lint SwanSDK.podspec --allow-warnings
# Publish: pod trunk push SwanSDK.podspec --allow-warnings
#
# The version field MUST stay in sync with the git tag (`ios/vX.Y.Z`).
# The release workflow (.github/workflows/ios-release.yml) asserts
# they match before pushing to CocoaPods Trunk.

Pod::Spec.new do |s|
  s.name             = 'SwanSDK'
  s.version          = '1.3.1'
  s.summary          = 'Swan customer-engagement SDK for iOS'
  s.description      = <<-DESC
    The Swan iOS SDK is the client-side foundation of the Swan customer-engagement
    platform. Identity, event tracking, push notifications (APNs), deep linking,
    and location tagging. Same wire protocol as the Swan Android and React Native
    SDKs so backend services see one unified protocol regardless of platform.
  DESC

  s.homepage         = 'https://swancx.github.io/swan-sdks/'
  s.license          = { :type => 'Proprietary', :file => 'LICENSE' }
  s.author           = { 'Swan' => 'support@swan.cx' }
  s.source           = {
    :git => 'https://github.com/SwanCX/swan-ios-sdk.git',
    :tag => "ios/v#{s.version}"
  }

  s.ios.deployment_target = '13.0'

  # Pin to Swift 5 language mode for now — the SDK uses manual NSLock
  # synchronization on a few internal classes that don't yet conform to
  # Sendable, and Xcode's default Swift-6 strict-concurrency would block
  # the build. Migration is tracked as a follow-up; SPM consumers can
  # also use Swift 5 mode and aren't affected today.
  s.swift_versions = ['5.9']
  s.pod_target_xcconfig = {
    'SWIFT_VERSION' => '5.9',
    'SWIFT_STRICT_CONCURRENCY' => 'minimal'
  }

  # Paths are relative to this podspec's directory (repo root). The
  # source tree lives under `platforms/ios/` because the repo is a
  # multi-platform monorepo.
  s.source_files = 'Sources/SwanSDK/**/*.swift'

  # SDK is pure Swift + Foundation. No external dependencies — same
  # posture as the SPM Package.swift, keeps the install footprint tiny.
  s.frameworks = 'Foundation', 'UIKit', 'UserNotifications', 'Network'
end
