# Swan iOS SDK

Swan customer-engagement SDK for iOS.

## Install

### CocoaPods

```ruby
target 'YourApp' do
  pod 'SwanSDK', '~> 1.3'
end
```

Then `pod install` and open the generated `.xcworkspace`.

### Swift Package Manager

In Xcode → **File → Add Packages…**, enter:

```
https://github.com/SwanCX/swan-ios-sdk
```

Pin to the latest `ios/X.Y.Z` tag and add the `SwanSDK` product to your app target.

## Requirements

- iOS 13.0 or later
- Swift 5.9 or later
- Xcode 15 or later

## Documentation

See the full integration guide at https://swancx.github.io/swan-sdks/docs/getting-started/ios/.

## Versioning

Releases are tagged `ios/vX.Y.Z`. Pin your install to a specific minor (`~> 1.3`) and your app will pick up patch fixes automatically.

The full changelog lives at https://swancx.github.io/swan-sdks/docs/changelog/ios/.

## Support

Issues and questions: contact your Swan integration manager.

## License

Proprietary — see [LICENSE](LICENSE). Use is governed by your Swan customer agreement.
