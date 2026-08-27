# Styled DMG packaging

Builds Sealshot's drag-to-Applications disk image with a custom window
background, fixed icon layout, and a seal-mascot volume icon. `release.sh`
calls `make-dmg.sh` automatically; the pieces are split out so the art and the
window styling can be iterated independently.

## Files

| File | Role |
|------|------|
| `render-background.swift` | Renders the window background art (gradient, hex weave, viewfinder brackets, caption, install arrow, wordmark) at 1× and 2×. Draws **no** icons — Finder paints those on top. |
| `gen-assets.sh` | Runs the renderer, folds the PNGs into a HiDPI `background.tiff`, and builds `VolumeIcon.icns` from the app icon. Output → `assets/` (gitignored). |
| `make-dmg.sh` | Stages app + Applications symlink + background + volume icon, creates a writable image, drives Finder via AppleScript to set window bounds / icon view / icon size / positions / background and hide chrome, then converts to a compressed read-only `.dmg`. |

## Geometry contract

Finder draws the icons; the background only carries the caption, arrow, and
wordmark. The icon centres must therefore match between the two layers:

- `render-background.swift`: `leftX`, `rightX`, `iconTopY` (measured from the top)
- `make-dmg.sh`: `LEFT_X`, `RIGHT_X`, `ICON_Y`, plus `WIN_W`/`WIN_H` (660×400) and `ICON_SIZE`

Change one, change the other.

## Usage

```sh
# Standalone, against any built .app:
./scripts/dmg/make-dmg.sh path/to/Sealshot.app out.dmg Sealshot

# Regenerate just the art (e.g. while tweaking the background):
./scripts/dmg/gen-assets.sh
```

**Requires a GUI login session.** The styling step drives Finder via
AppleScript and will not work over a plain headless ssh / CI runner.
