# Sealshot

**Professional screen capture for macOS. Free and open source.**

Capture, record, annotate, redact, and extract data — everything processed on
your Mac. No account. No telemetry. No cloud.

**[seal-shot.com](https://seal-shot.com)** · [Download the notarized app](https://seal-shot.com/download/) · [Documentation](https://seal-shot.com/docs/) · [Donate](https://seal-shot.com/donate/)

## What it does

- **Capture** — area, window, fullscreen, delayed, and scrolling capture, with
  a pixel loupe and live dimensions
- **Record** — screen, window, or region, with system audio and microphone
- **Annotate** — shapes, arrows, text, numbered badges on their own layer;
  original pixels are never touched
- **Smart Redaction** — finds emails, card numbers, API keys and other
  sensitive text on-device and proposes redactions for review
- **Extract** — tables, form fields, and Live Text pulled out of any capture
  as copyable text
- **Encrypt** — optional at-rest encryption for everything Sealshot stores,
  unlocked with Touch ID
- **Library** — OCR full-text search across every capture, collections,
  favorites

Everything runs locally. The app makes three kinds of network request, all
user-visible and documented in the [privacy policy](https://seal-shot.com/privacy/):
update checks, the revoked-license list, and the optional redaction model
download.

## Free to use, funded by donations

Every feature works without paying — nothing expires, nothing is watermarked,
no capture is ever refused. After a while, the app shows an occasional
reminder (never before or during a capture, at most fortnightly). Donating any
amount at [seal-shot.com/donate](https://seal-shot.com/donate/) — and then
ticking **"I've donated"** in Settings ▸ Support — turns it off for good. It's
the honor system: building from source without the reminder is equally fine,
and if Sealshot is useful to you, we'd rather have the donation.

## Building from source

Requirements: macOS 14+, Xcode 16+, [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
cd app
xcodegen generate
open Sealshot.xcodeproj
```

Two schemes:

- **Sealshot-Direct** — the app as distributed. Build and run this one.
- **Sealshot-MAS** — a sandboxed variant kept for structural parity; it is
  also the only scheme configured for tests:

```sh
xcodebuild test -project Sealshot.xcodeproj -scheme Sealshot-MAS \
  -destination 'platform=macOS,arch=arm64'
```

The `.xcodeproj` is generated and gitignored — after adding or moving files,
run `xcodegen generate` again.

## Repository layout

| Path | What it is |
|---|---|
| `app/` | The application (Swift, AppKit + SwiftUI) |
| `app/Packages/WebRTCAPM` | Vendored audio processing (BSD-3, see its LICENSE) |
| `scripts/release.sh` | Release pipeline: build, notarize, publish |
| `scripts/licensegen` | Legacy license tooling, kept for the pre-donation licenses still in the wild |
| `docs/release-notes/` | Release notes, one file per version |
| `appcast.xml` | Sparkle update feed for the published builds |
| `license-blocklist.json` | Signed revocation list checked on-device |

Releases are published from this repository:
[Releases](https://github.com/ldeng83/Sealshot/releases) carries the signed,
notarized DMGs, and `appcast.xml` is what installed copies poll for updates.

## Contributing

Issues and pull requests are welcome. A few things worth knowing before a
larger change: the test suite is the contract (`xcodebuild test` above, ~1,400
tests); pure, unit-testable policy types are the house style for anything with
rules in it; and US English throughout ("license", not "licence").

## License

The code is [GPL-3.0](LICENSE). The Sealshot name, logo, and seal-shot.com
domain are not — see [TRADEMARKS.md](TRADEMARKS.md). Forks are welcome under
their own name.
