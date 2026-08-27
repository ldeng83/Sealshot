# Sealshot — Mac app

The Sealshot application: a menu-bar screenshot tool with capture overlay,
non-destructive editor, metadata pipeline, and library. See
[`../docs/dev/ARCHITECTURE.md`](../docs/dev/ARCHITECTURE.md) for how the
pieces fit together and [`../docs/dev/DEVELOPMENT.md`](../docs/dev/DEVELOPMENT.md)
for conventions.

## Prerequisites

- **Xcode 15+** installed at `/Applications/Xcode.app` (free from the App Store)
- Point `xcode-select` at Xcode (not Command Line Tools) — one time:
  ```
  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
  ```
- **XcodeGen** for project generation:
  ```
  brew install xcodegen
  ```
- (Optional) **SwiftLint** for local lint runs — CI installs it automatically:
  ```
  brew install swiftlint
  ```

## Generate the Xcode project

The Xcode project is generated from `project.yml`. The generated `Sealshot.xcodeproj` is gitignored — **do not hand-edit it**, edit `project.yml` and regenerate.

```
cd app
xcodegen generate
open Sealshot.xcodeproj
```

## Build and test from the command line

```
cd app
xcodegen generate

# MAS build + full test suite
xcodebuild test \
  -project Sealshot.xcodeproj \
  -scheme Sealshot-MAS \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO

# Direct build
xcodebuild build \
  -project Sealshot.xcodeproj \
  -scheme Sealshot-Direct \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO
```

Code signing is disabled for these local commands so the build doesn't depend on having an Apple Developer Team configured. To produce signed builds, set `DEVELOPMENT_TEAM` in Xcode's Signing & Capabilities UI (it'll be written to a local override Xcode keeps outside the generated project).

A handful of rendering tests are known to fail on some machines — see the
"Known test caveats" section of
[`../docs/dev/DEVELOPMENT.md`](../docs/dev/DEVELOPMENT.md) before assuming a
regression.

## Layout

```
app/
├── project.yml                 ← source of truth for the Xcode project
├── Sources/Sealshot/
│   ├── SealshotApp.swift       ← app entry, menu bar shell
│   ├── AppDelegate.swift
│   ├── AppInfo.swift           ← runtime detection of edition (MAS / Direct)
│   ├── Capture/                ← overlay, selection, capture modes, shortcuts
│   ├── Editor/                 ← canvas, annotations, tools, library, .seal I/O
│   │   ├── OCR/                ← Vision text recognition + Live Text selection
│   │   └── Theme/              ← shared UI components and theme tokens
│   └── Metadata/               ← auto title/tags/category pipeline
├── Resources/
│   ├── MAS/                    ← Mac App Store Info.plist + entitlements
│   ├── Direct/                 ← Developer ID Info.plist + entitlements
│   └── Assets.xcassets/        ← icons
└── Tests/SealshotTests/        ← XCTest suite (runs against MAS target)
```

Both targets share all sources; edition-specific behavior is gated at runtime
via `AppInfo`.
