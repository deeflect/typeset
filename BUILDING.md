# Building Typeset.md

## Prerequisites

- Xcode 26.3+, macOS 26+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

## Generate the project

The `.xcodeproj` is generated, not checked in. `project.yml` is the source of truth for all targets (the `Typeset` app, the `TypesetQuickLook` Quick Look extension, and their test bundles):

```sh
xcodegen generate
```

Run this after cloning, and again whenever `project.yml` or `Config/App.xcconfig` changes.

## Build

Without a signing identity:

```sh
xcodebuild -scheme Typeset -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO
```

To sign with your own Apple team, create `Config/Local.xcconfig` (gitignored) and re-run `xcodegen generate`:

```
DEVELOPMENT_TEAM = YOURTEAMID
APP_BUNDLE_ID = com.example.typeset
```

Then build without the `CODE_SIGNING_ALLOWED=NO` flag, or open `Typeset.xcodeproj` in Xcode and press ⌘R. The scheme builds both the app and the embedded Quick Look extension.

## Test

```sh
xcodebuild -scheme Typeset -destination 'platform=macOS' test   # app + Quick Look tests
cd Packages/TypesetCore && swift test                            # parser, differ
cd ../TypesetRendering && swift test                             # native renderer
```

`TypesetCore` and `TypesetRendering` are standalone local Swift packages, so their tests run without the Xcode project.

## Fixtures

Hand-written fixtures live in `Tests/Fixtures/*.md`. Large synthetic files for performance testing are generated on demand and gitignored:

```sh
./Scripts/make-fixtures.sh   # writes Tests/Fixtures/generated/large-{1,10}mb.md
```

## Project layout

```
Config/App.xcconfig           App identity (name, bundle ID, version)
project.yml                   XcodeGen project spec
App/Sources/Typeset/          App target: SwiftUI shell, views, file watcher, editing
App/Sources/TypesetQuickLook/ Quick Look extension
App/Tests/                    App and Quick Look XCTest suites
Packages/TypesetCore/         Block model, parser, differ
Packages/TypesetRendering/    Theme and native rendered document, shared by app and Quick Look
Tests/Fixtures/               Markdown fixtures
Scripts/                      Fixture generation, headless snapshots, release archive
```

Third-party licences are listed in `App/Sources/Typeset/Resources/ThirdPartyNotices.md`.
