#!/usr/bin/env bash
#
# release.sh — build, sign, notarize, and package Sealshot for direct download.
#
# Produces a notarized, stapled universal (arm64 + x86_64) .dmg from the
# Sealshot-Direct target that testers can download and run with no Gatekeeper
# warnings.
#
# PREREQUISITES (one-time):
#   1. Paid Apple Developer Program membership.
#   2. A "Developer ID Application" certificate in your login keychain.
#      Create at https://developer.apple.com/account/resources/certificates
#      then download + double-click to install. Verify with:
#        security find-identity -v -p codesigning | grep "Developer ID Application"
#   3. Notarization credentials stored as a keychain profile (recommended):
#        xcrun notarytool store-credentials sealshot-notary \
#          --apple-id "you@example.com" \
#          --team-id JY9UQ3JLAP \
#          --password <app-specific-password>
#      (App-specific password: https://appleid.apple.com → Sign-In & Security.)
#
# USAGE:
#   NOTARY_PROFILE=sealshot-notary ./scripts/release.sh
#   # or pass credentials directly:
#   APPLE_ID=you@example.com APPLE_APP_PASSWORD=xxxx-xxxx-xxxx-xxxx ./scripts/release.sh
#
# ENV VARS:
#   NOTARY_PROFILE     notarytool keychain profile name (preferred)
#   APPLE_ID           Apple ID email          (if not using NOTARY_PROFILE)
#   APPLE_APP_PASSWORD app-specific password    (if not using NOTARY_PROFILE)
#   TEAM_ID            Apple team ID            (default: JY9UQ3JLAP)
#   VERSION            marketing version string (default: read from project.yml)
#   SKIP_NOTARIZE=1    build + sign + .dmg only, skip notarization (smoke test)
#   SKIP_PUBLISH=1     skip zip/appcast/GitHub release (useful for manual tester drops)
#
# RELEASE NOTES:
#   docs/release-notes/next.md accumulates user-facing notes during
#   development. Publishing promotes it to docs/release-notes/v<VERSION>.md
#   and uses it for the appcast <description>, the GitHub release body, and a
#   changelog PR against the website repo. Publishing fails without notes.

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP_DIR="$ROOT/app"
BUILD="$ROOT/build/release"
PROJECT="$APP_DIR/Sealshot.xcodeproj"
SCHEME="Sealshot-Direct"
APP_NAME="Sealshot"

TEAM_ID="${TEAM_ID:-JY9UQ3JLAP}"
VERSION="${VERSION:-$(grep -m1 'MARKETING_VERSION' "$APP_DIR/project.yml" | sed -E 's/.*"([^"]+)".*/\1/')}"
RELEASE_DATE="$(date -u +%Y-%m-%d)"
DMG="$BUILD/${APP_NAME}-${VERSION}.dmg"
ZIP="$BUILD/${APP_NAME}-${VERSION}.zip"
# The public source repo IS the release repo: assets on its Releases page,
# appcast.xml and license-blocklist.json at its root. It is also, literally,
# the old Sealshot-Release repo — transferred and renamed, so every URL
# compiled into builds ≤ 0.8.0 (appcast, blocklist, model asset) resolves
# here through GitHub's redirects. One appcast serves every generation.
# NEVER create a repo named Sealshot-Release under raydeng83 or ldeng83, and
# never rename this one: either would sever those redirects and strand every
# older install at its current version, silently.
RELEASE_REPO="ldeng83/Sealshot"
WEBSITE_REPO="raydeng83/Sealshot-Website"
NOTES_DIR="$ROOT/docs/release-notes"
NOTES_NEXT="$NOTES_DIR/next.md"
NOTES_FILE="$NOTES_DIR/v${VERSION}.md"
SPARKLE_TOOLS_VERSION="2.9.3"   # keep roughly in sync with the SPM Sparkle version
TOOLS="$ROOT/build/tools/sparkle-$SPARKLE_TOOLS_VERSION"

fetch_sparkle_tools() {
  if [ ! -x "$TOOLS/bin/sign_update" ]; then
    echo "▸ fetching Sparkle $SPARKLE_TOOLS_VERSION CLI tools…"
    mkdir -p "$TOOLS"
    curl -fsSL "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_TOOLS_VERSION/Sparkle-$SPARKLE_TOOLS_VERSION.tar.xz" \
      | tar -xJ -C "$TOOLS"
  fi
}

# Render the release-notes markdown (## headings, bullets, **bold**, `code`)
# as simple HTML for the appcast <description>. HTML comments (the convention
# header in next.md) are stripped.
notes_to_html() {
  sed -E -e '/<!--/,/-->/d' \
         -e 's/\*\*([^*]+)\*\*/<b>\1<\/b>/g' \
         -e 's/`([^`]+)`/<code>\1<\/code>/g' "$1" |
  awk '
    function flushli() { if (li != "") { list = list "<li>" li "</li>\n"; li = "" } }
    function flushpara() { if (para != "") { print "<p>" para "</p>"; para = "" } }
    function flushlist() { flushli(); if (list != "") { printf "<ul>\n%s</ul>\n", list; list = "" } }
    /^## /           { flushpara(); flushlist(); print "<h2>" substr($0, 4) "</h2>"; next }
    /^# /            { flushpara(); flushlist(); print "<h1>" substr($0, 3) "</h1>"; next }
    /^- /            { flushpara(); flushli(); li = substr($0, 3); next }
    /^[[:space:]]*$/ { flushli(); flushpara(); next }
    {
      line = $0; sub(/^[[:space:]]+/, "", line)
      # A wrapped paragraph accumulates across lines, exactly as a wrapped
      # bullet does. Emitting one <p> per SOURCE LINE turned the 0.7.5 notes
      # into eleven one-line paragraphs in the Sparkle update window.
      if (li != "") li = li " " line
      else { flushlist(); para = (para == "" ? line : para " " line) }
    }
    END { flushlist(); flushpara() }
  '
}

echo "▸ Sealshot $VERSION → notarized .dmg (team $TEAM_ID)"

# 0. Regenerate the (gitignored) xcodeproj so it reflects the current sources.
if command -v xcodegen >/dev/null 2>&1; then
  echo "▸ xcodegen generate"
  (cd "$APP_DIR" && xcodegen generate >/dev/null)
fi

# Confirm a Developer ID Application cert exists before doing expensive work.
DEVID_LINE="$(security find-identity -v -p codesigning | grep "Developer ID Application" || true)"
if [ -z "$DEVID_LINE" ]; then
  echo "error: no 'Developer ID Application' certificate found in the keychain." >&2
  echo "       See the PREREQUISITES section at the top of this script." >&2
  exit 1
fi
DEVID_IDENTITY="$(echo "$DEVID_LINE" | head -1 | sed -E 's/.*"(.*)"/\1/')"
echo "▸ signing identity: $DEVID_IDENTITY"

# Resolve notarization credentials up front so we fail before the long archive.
NOTARY_ARGS=()
if [ "${SKIP_NOTARIZE:-0}" != "1" ]; then
  if [ -n "${NOTARY_PROFILE:-}" ]; then
    NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
  elif [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_APP_PASSWORD:-}" ]; then
    NOTARY_ARGS=(--apple-id "$APPLE_ID" --password "$APPLE_APP_PASSWORD" --team-id "$TEAM_ID")
  else
    echo "error: notarization credentials missing. Set one of:" >&2
    echo "  • NOTARY_PROFILE=<name>  (after: xcrun notarytool store-credentials <name> \\" >&2
    echo "        --apple-id you@example.com --team-id $TEAM_ID --password <app-specific-pw>)" >&2
    echo "  • APPLE_ID=… APPLE_APP_PASSWORD=…  (team defaults to $TEAM_ID)" >&2
    echo "  Or run with SKIP_NOTARIZE=1 to build a signed (un-notarized) dmg." >&2
    exit 1
  fi
fi

# Publishing preflight — fail fast before the long build.
if [ "${SKIP_PUBLISH:-0}" != "1" ]; then
  command -v gh >/dev/null 2>&1 || {
    echo "error: gh CLI required to publish (brew install gh), or SKIP_PUBLISH=1" >&2; exit 1; }
  gh auth status >/dev/null 2>&1 || {
    echo "error: gh not authenticated — run: gh auth login" >&2; exit 1; }
  gh auth setup-git >/dev/null 2>&1 || true   # ensure git can push via gh credentials
  fetch_sparkle_tools
  # Prove the EdDSA private key is reachable by signing a scratch file.
  SCRATCH=$(mktemp)
  "$TOOLS/bin/sign_update" "$SCRATCH" >/dev/null 2>&1 || {
    echo "error: Sparkle signing key missing — run: $TOOLS/bin/generate_keys" >&2
    rm -f "$SCRATCH"; exit 1; }
  rm -f "$SCRATCH"
  # Release notes must exist before the long build — they feed the appcast
  # description, the GitHub release body, and the website changelog.
  if [ ! -s "$NOTES_FILE" ] && [ ! -s "$NOTES_NEXT" ]; then
    echo "error: no release notes — write docs/release-notes/next.md (or v${VERSION}.md)," >&2
    echo "       or run with SKIP_PUBLISH=1." >&2
    exit 1
  fi
fi

rm -rf "$BUILD"
mkdir -p "$BUILD"

# 1. Archive a universal Release build.
echo "▸ archiving (arm64 + x86_64)…"
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$BUILD/$APP_NAME.xcarchive" \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  SEALSHOT_RELEASE_DATE="$RELEASE_DATE" \
  -quiet

# 2. Export the Developer ID-signed (hardened runtime) app.
EXPORT_PLIST="$BUILD/ExportOptions.plist"
cat > "$EXPORT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
</dict>
</plist>
PLIST

echo "▸ exporting signed app…"
xcodebuild -exportArchive \
  -archivePath "$BUILD/$APP_NAME.xcarchive" \
  -exportPath "$BUILD/export" \
  -exportOptionsPlist "$EXPORT_PLIST" \
  -quiet

APP="$BUILD/export/$APP_NAME.app"
echo "▸ verifying signature…"
codesign --verify --deep --strict --verbose=2 "$APP"

# 3. Build the styled drag-to-Applications .dmg (custom background, icon
#    layout, and volume icon). Requires a GUI login session — the styling step
#    drives Finder via AppleScript, which is unavailable over headless ssh.
echo "▸ building styled dmg…"
"$ROOT/scripts/dmg/make-dmg.sh" "$APP" "$DMG" "$APP_NAME"

# Sign the dmg itself so the container also carries a Developer ID signature.
codesign --force --sign "$DEVID_IDENTITY" --timestamp "$DMG"

if [ "${SKIP_NOTARIZE:-0}" = "1" ]; then
  echo "▸ SKIP_NOTARIZE set — signed .dmg ready (NOT notarized): $DMG"
  exit 0
fi

# 4. Notarize the dmg (notarytool inspects the nested signed app too).
echo "▸ submitting to Apple notary service (this can take a few minutes)…"
xcrun notarytool submit "$DMG" "${NOTARY_ARGS[@]}" --wait

# 5. Staple the ticket so the dmg validates offline — and staple the .app
# itself: Sparkle installs the app from the zip, so without its own ticket
# an offline user would hit a Gatekeeper online-check on first launch.
echo "▸ stapling…"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type open --context context:primary-signature -v "$DMG" || true

echo ""
echo "✅ Notarized dmg: $DMG"

if [ "${SKIP_PUBLISH:-0}" = "1" ]; then
  echo "▸ SKIP_PUBLISH set — skipping zip/appcast/GitHub release."
  exit 0
fi

# 6. Sparkle update archive: zip the stapled app and sign it.
echo "▸ creating update zip…"
ditto -c -k --keepParent "$APP" "$ZIP"
SIGN_ATTRS=$("$TOOLS/bin/sign_update" "$ZIP") || {
  echo "error: sign_update failed — EdDSA key may be missing from the keychain" >&2; exit 1; }
[[ "$SIGN_ATTRS" == sparkle:edSignature=* ]] || {
  echo "error: unexpected sign_update output: $SIGN_ATTRS" >&2; exit 1; }
echo "   $SIGN_ATTRS"

# 7. Promote the running release notes to this version and commit the rename.
if [ ! -s "$NOTES_FILE" ]; then
  echo "▸ promoting release notes → docs/release-notes/v${VERSION}.md"
  mv "$NOTES_NEXT" "$NOTES_FILE"
  git -C "$ROOT" add -A "docs/release-notes"
  git -C "$ROOT" commit -m "release notes: $APP_NAME $VERSION" -- "docs/release-notes" \
    || echo "   (release-notes commit skipped)"
fi
NOTES_HTML="$(notes_to_html "$NOTES_FILE")"

# 8. Append the appcast item (newest first, after the marker comment).
echo "▸ updating appcast…"
BUILD_NUM=$(grep -m1 'CURRENT_PROJECT_VERSION' "$APP_DIR/project.yml" | sed -E 's/.*"([^"]+)".*/\1/')
[ -n "$BUILD_NUM" ] || { echo "error: could not read CURRENT_PROJECT_VERSION from project.yml" >&2; exit 1; }
PUB_DATE=$(LC_ALL=C date -u +"%a, %d %b %Y %H:%M:%S +0000")
RELCLONE="$BUILD/release-repo"
rm -rf "$RELCLONE"
git clone --depth 1 "https://github.com/$RELEASE_REPO.git" "$RELCLONE"
# Without the marker the awk below would silently insert nothing and the
# release would publish with an appcast that never mentions it.
grep -qF "<!-- newest items first -->" "$RELCLONE/appcast.xml" || {
  echo "error: appcast.xml is missing the '<!-- newest items first -->' marker" >&2; exit 1; }

if grep -qF "<sparkle:version>${BUILD_NUM}</sparkle:version>" "$RELCLONE/appcast.xml"; then
  echo "   appcast already contains build $BUILD_NUM — skipping insertion"
else
  ITEM_FILE=$(mktemp)
  trap 'rm -f "$ITEM_FILE"' EXIT
  cat > "$ITEM_FILE" <<ITEM
    <item>
      <title>${VERSION}</title>
      <pubDate>${PUB_DATE}</pubDate>
      <sparkle:version>${BUILD_NUM}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <description><![CDATA[
${NOTES_HTML}
      ]]></description>
      <enclosure url="https://github.com/$RELEASE_REPO/releases/download/v${VERSION}/${APP_NAME}-${VERSION}.zip" ${SIGN_ATTRS} type="application/octet-stream"/>
    </item>
ITEM

  awk -v itemfile="$ITEM_FILE" '
    { print }
    /<!-- newest items first -->/ {
      while ((getline line < itemfile) > 0) print line
      close(itemfile)
    }
  ' "$RELCLONE/appcast.xml" > "$RELCLONE/appcast.xml.new"
  mv "$RELCLONE/appcast.xml.new" "$RELCLONE/appcast.xml"
  xmllint --noout "$RELCLONE/appcast.xml"   # fail loudly on malformed XML
fi

# 9. Publish: GitHub release with assets, then push the appcast.
echo "▸ publishing GitHub release v${VERSION}…"
if gh release view "v$VERSION" --repo "$RELEASE_REPO" >/dev/null 2>&1; then
  echo "   GitHub release v$VERSION already exists — skipping create"
else
  # The notes file carries the maintainer convention header as an HTML comment.
  # The appcast and the website entry both strip it; --notes-file does not, so
  # 0.7.1 and 0.7.2 published "Running release notes for the NEXT release…" as
  # the first thing in their release body. Strip it here too, and refuse an
  # empty result rather than publishing a blank release body.
  BODY="$BUILD/release-body.md"
  sed -E '/<!--/,/-->/d' "$NOTES_FILE" | awk 'NF || seen { seen=1; print }' > "$BODY"
  [ -s "$BODY" ] || { echo "error: release body empty after stripping comments" >&2; exit 1; }
  gh release create "v$VERSION" "$ZIP" "$DMG" \
    --repo "$RELEASE_REPO" --title "$APP_NAME $VERSION" --notes-file "$BODY"
fi
git -C "$RELCLONE" add appcast.xml
if ! git -C "$RELCLONE" diff --quiet HEAD; then
  git -C "$RELCLONE" commit -m "appcast: $APP_NAME $VERSION"
fi
git -C "$RELCLONE" push

# 10. Tag the app repo so release boundaries stay recoverable (0.6.0 shipped
#     untagged and had to be reconstructed from project.yml history).
if git -C "$ROOT" rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null; then
  echo "▸ tag v$VERSION already exists"
else
  echo "▸ tagging v$VERSION"
  git -C "$ROOT" tag -a "v$VERSION" -m "$APP_NAME $VERSION"
  git -C "$ROOT" push origin "v$VERSION" \
    || echo "warning: tag push failed — push manually: git push origin v$VERSION" >&2
fi

# 11. Open a website changelog PR. Non-fatal: the release is already out, so
#     a failure here just means adding the changelog entry by hand.
echo "▸ opening website changelog PR…"
if ! (
  set -e
  WEBCLONE="$BUILD/Sealshot-Website"
  rm -rf "$WEBCLONE"
  git clone --depth 1 "https://github.com/$WEBSITE_REPO.git" "$WEBCLONE"
  ENTRY="$WEBCLONE/src/content/docs/docs/changelog/v${VERSION}.md"
  if [ -e "$ENTRY" ]; then
    echo "   changelog entry for $VERSION already on the website — skipping"
  else
    IFS=. read -r MAJ MIN PAT <<<"$VERSION"
    ORDER=$(( -(MAJ * 10000 + MIN * 100 + PAT) ))
    SLUG="v${VERSION//./-}"
    HUMAN_DATE=$(date +"%B %e, %Y" | tr -s ' ')
    {
      printf -- '---\ntitle: Sealshot %s\ndescription: Release notes for Sealshot %s.\nslug: docs/changelog/%s\nsidebar:\n  order: %s\n---\n\n' \
        "$VERSION" "$VERSION" "$SLUG" "$ORDER"
      printf -- '**Released %s** ·\n[Download](https://github.com/%s/releases/tag/v%s)\n' \
        "$HUMAN_DATE" "$RELEASE_REPO" "$VERSION"
      sed -E '/<!--/,/-->/d' "$NOTES_FILE"
    } > "$ENTRY"
    BR="changelog-v${VERSION//./-}"
    git -C "$WEBCLONE" checkout -q -b "$BR"
    git -C "$WEBCLONE" add "$ENTRY"
    git -C "$WEBCLONE" commit -q -m "docs: changelog entry for $VERSION"
    git -C "$WEBCLONE" push -q -u origin "$BR"
    gh pr create --repo "$WEBSITE_REPO" --head "$BR" \
      --title "docs: Sealshot $VERSION changelog" \
      --body "Changelog entry for Sealshot $VERSION, generated from the app repo's release notes by scripts/release.sh. Before merging: reconcile the user guide against the v$VERSION tag, and double-check any change that touches the site's privacy claims."
  fi
); then
  echo "warning: website changelog PR failed — add src/content/docs/docs/changelog/v${VERSION}.md in $WEBSITE_REPO manually" >&2
fi

echo ""
echo "✅ Published: https://github.com/$RELEASE_REPO/releases/tag/v$VERSION"
echo "   Existing installs will pick this up via Sparkle within a day."
