# Building ANTINTWRK for iOS

This is the native iPhone/iPad client source. It includes the social WebView integration and the modified Matrix client. The separately deployed social server, signing identities, private credentials and service configuration are not part of this source distribution.

## Toolchain and dependencies

The current build was checked with Xcode 26.5 on macOS, using the iOS SDK supplied with Xcode. The application targets iOS/iPadOS 18.5 or later, arm64, with iPhone and iPad device families. Apple Silicon Mac compatibility is configured as an iPhone/iPad application; Mac Catalyst and Intel Mac support are not enabled or claimed as accepted.

The project uses XcodeGen, SwiftGen, Sourcery, SwiftFormat, SwiftLint and Swift Package Manager. Follow [the upstream development setup](CONTRIBUTING.md#setting-up-a-development-environment) and inspect `Tools/Sources/Commands/SetupProject.swift` before running the setup command, which installs development tools and configures repository hooks:

```sh
swift run tools setup-project
```

Use `project.yml` and the checked-in `Package.resolved` files as the dependency definitions. The Matrix Swift component version is 26.09.22; its public source/build repository is [matrix-rust-components-swift](https://github.com/element-hq/matrix-rust-components-swift), backed by [matrix-rust-sdk](https://github.com/matrix-org/matrix-rust-sdk). Do not replace a pinned package with an arbitrary latest build.

## Simulator build

Select the installed Xcode toolchain, regenerate the project if needed and build without distribution signing:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodegen
xcodebuild build -project ElementX.xcodeproj -scheme ElementX \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

The Simulator can exercise local interface, WebView and Matrix-client paths. It does not establish acceptance of physical-device notifications, calls, biometric hardware or real App Store purchases. The opt-in `StoreKitLocal` test scheme uses local Xcode StoreKit fixtures; those transactions are not Apple server receipts and must never grant production benefits.

## Devices and distribution

Use your own Apple Developer team, bundle identifiers, App Groups, Keychain access groups, Associated Domains, signing profiles and service registrations when producing a separately distributed fork. The checked-in operator identifiers do not grant permission to use its credentials or provision its services. Configure the Google/Apple authentication, push and billing services for your own identifiers before claiming those integrations work.

Production distribution requires the matching entitlements, export-compliance answers/documentation and applicable store review. Do not remove authentication, signature checks or encryption to make an export succeed. Do not treat a successful unsigned archive as an uploaded or approved application.

## Licences and source

Keep `LICENSE`, `LICENSE-COMMERCIAL`, upstream notices and third-party component licences. The upstream README describes its AGPL or separately agreed commercial licensing options. No commercial agreement or App Store exception is granted by this build guide. The source and build material needed for covered native modifications must remain available under the applicable licence when distributing a build.

An exported source snapshot may materialize current LFS assets as ordinary Git files. That changes storage representation, not the asset contents or their licences. Private development history and operational instructions are not required to build the client and must not be published with a source snapshot.
