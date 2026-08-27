#!/usr/bin/env bash
#
# make-dmg.sh — package a built .app into a styled drag-to-Applications DMG.
#
# Produces a compressed (UDZO) disk image whose mounted window shows a custom
# peach→orange background, the app and Applications icons positioned over the
# install arrow, a matching volume icon, and no Finder chrome.
#
# Finder draws the icons and their labels itself; the background art only
# carries the caption, arrow, and wordmark. The icon centre coordinates here
# MUST stay in sync with leftX/rightX/iconY in render-background.swift.
#
# USAGE:
#   ./scripts/dmg/make-dmg.sh <App.app> <output.dmg> [VolumeName]
#
# NOTE: requires a GUI login session — the AppleScript styling step drives
# Finder, which is unavailable over plain ssh / headless CI.
set -euo pipefail

APP="${1:?usage: make-dmg.sh <App.app> <output.dmg> [VolumeName]}"
DMG_OUT="${2:?usage: make-dmg.sh <App.app> <output.dmg> [VolumeName]}"
VOLNAME="${3:-Sealshot}"

HERE="$(cd "$(dirname "$0")" && pwd)"
ASSETS="$HERE/assets"

[ -d "$APP" ] || { echo "✗ app not found: $APP" >&2; exit 1; }

# Window + icon geometry. Window content area is 660×400 (matches the
# background); icons sit at the same centres the arrow points between.
WIN_W=660; WIN_H=400
ICON_SIZE=110
LEFT_X=175; RIGHT_X=485; ICON_Y=190

# 1. Fresh art every build.
"$HERE/gen-assets.sh"

# 2. Stage the contents of the image.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
APP_BASENAME="$(basename "$APP")"
cp -R "$APP" "$STAGE/$APP_BASENAME"
ln -s /Applications "$STAGE/Applications"
mkdir -p "$STAGE/.background"
cp "$ASSETS/background.tiff" "$STAGE/.background/background.tiff"
cp "$ASSETS/VolumeIcon.icns" "$STAGE/.VolumeIcon.icns"

# 3. Create a writable image sized with headroom, then mount it.
RW_DMG="$(mktemp -u).dmg"
echo "▸ creating writable image…"
hdiutil create -srcfolder "$STAGE" -volname "$VOLNAME" \
  -fs HFS+ -format UDRW -ov "$RW_DMG" >/dev/null

echo "▸ mounting…"
MOUNT_OUT="$(hdiutil attach "$RW_DMG" -readwrite -noverify -noautoopen)"
DEV="$(echo "$MOUNT_OUT" | grep -E '^/dev/' | head -1 | awk '{print $1}')"
# Use the ACTUAL mount point returned by attach. When a stale /Volumes/Sealshot
# is already mounted, macOS mounts the new image as "Sealshot 1", "Sealshot 2",
# …; hardcoding the name made the Finder styling target the OLD volume and left
# the new DMG without a .DS_Store (plain Finder background).
MNT="$(echo "$MOUNT_OUT" | grep -E '/Volumes/' | sed -E 's/.*Apple_HFS[[:space:]]+//' | head -1)"
[ -n "$MNT" ] || MNT="/Volumes/$VOLNAME"
MOUNT_NAME="$(basename "$MNT")"
trap 'hdiutil detach "$DEV" >/dev/null 2>&1 || true; rm -rf "$STAGE" "$RW_DMG"' EXIT

# Tell Finder the disk has a custom icon (the C flag on .VolumeIcon.icns).
SetFile -a C "$MNT" || true

# 4. Style the window with Finder via AppleScript.
echo "▸ styling window…"
osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$MOUNT_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 200 + $WIN_W, 120 + $WIN_H}
    set vopts to the icon view options of container window
    set arrangement of vopts to not arranged
    set icon size of vopts to $ICON_SIZE
    set text size of vopts to 12
    set background picture of vopts to file ".background:background.tiff"
    set position of item "$APP_BASENAME" of container window to {$LEFT_X, $ICON_Y}
    set position of item "Applications" of container window to {$RIGHT_X, $ICON_Y}
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT

# Give Finder a beat to flush .DS_Store, then bless the layout.
sync; sleep 2

# 5. Detach and compress to the final read-only image.
echo "▸ compressing…"
hdiutil detach "$DEV" >/dev/null
trap 'rm -rf "$STAGE" "$RW_DMG"' EXIT
rm -f "$DMG_OUT"
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_OUT" >/dev/null

echo "▸ styled dmg ready: $DMG_OUT"
