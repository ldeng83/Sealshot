#!/usr/bin/env bash
#
# gen-assets.sh — generate the static art the styled DMG needs:
#   * background.tiff  (multi-resolution 1x + 2x window background)
#   * VolumeIcon.icns  (the mounted-disk icon, from the app icon)
#
# Output lands in scripts/dmg/assets/. These are deterministic build products
# derived from render-background.swift and the app icon, so they are gitignored
# and regenerated on demand by make-dmg.sh.
#
#   ./scripts/dmg/gen-assets.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OUT="$HERE/assets"
ICON_SRC="$ROOT/app/Resources/Assets.xcassets/AppIcon.appiconset/icon_1024.png"

rm -rf "$OUT"; mkdir -p "$OUT"

# 1. Window background — render 1x + 2x PNGs, fold into one HiDPI .tiff.
echo "▸ rendering DMG background…"
swift "$HERE/render-background.swift" "$OUT" >/dev/null
tiffutil -cathidpicheck "$OUT/background.png" "$OUT/background@2x.png" \
  -out "$OUT/background.tiff" >/dev/null

# 2. Volume icon — build an .icns from the app icon so the mounted disk and
#    its Finder sidebar entry carry the seal mascot.
echo "▸ building volume icon…"
ICONSET="$OUT/Volume.iconset"
mkdir -p "$ICONSET"
for sz in 16 32 128 256 512; do
  sips -z "$sz" "$sz"           "$ICON_SRC" --out "$ICONSET/icon_${sz}x${sz}.png"   >/dev/null
  sips -z $((sz*2)) $((sz*2))   "$ICON_SRC" --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$OUT/VolumeIcon.icns"
rm -rf "$ICONSET" "$OUT/background.png" "$OUT/background@2x.png"

echo "▸ assets ready in $OUT"
ls -la "$OUT"
