#!/bin/bash
# Asserts licensegen's preamble matches the Swift app template.
#
# The licence id and the two dates are generated at run time, so they are
# normalised to placeholders before comparing. Everything that defines the
# FORMAT is still compared verbatim: every label, the 18-column alignment,
# App access, Users, Macs per user, and both closing paragraphs. Task 14's
# --id / --extend-from checks pin the id and dates exactly.
set -euo pipefail
cd "$(dirname "$0")"

# The expected bytes are the SHARED GOLDEN FIXTURE the app's
# LicenseFormatTests also asserts against — not a copy of them. A heredoc
# here would be a fourth copy of the template and would let licensegen and
# the fixture drift while both "pass". The fixture's own id and dates are
# run through the same placeholder normalisation as licensegen's output.
FIXTURE="../../app/Tests/SealshotTests/Fixtures/golden-preamble-v2.txt"
[ -f "$FIXTURE" ] || { echo "missing golden fixture: $FIXTURE" >&2; exit 1; }

normalize() {
  sed -e 's/^License ID:       .*/License ID:       <id>/' \
      -e 's/^License issued:   .*/License issued:   <date>/' \
      -e 's/^Updates through:  .*/Updates through:  <date>/' \
      -e 's/^release whose entitlement date is on or before .*/release whose entitlement date is on or before <date>./'
}

RAW=$(swift run licensegen issue --name "Jane Doe" --email "jane@example.com" \
        --seats 1 --type individual --months 12 2>/dev/null | sed -n '1,17p')
GOT=$(printf '%s' "$RAW" | normalize)
WANT=$(normalize < "$FIXTURE")

if [ "$GOT" != "$WANT" ]; then
  echo "PARITY FAIL — licensegen preamble does not match the app template" >&2
  diff <(printf '%s\n' "$WANT") <(printf '%s\n' "$GOT") >&2 || true
  exit 1
fi
echo "parity OK"

# The preamble can match byte-for-byte while the file is still unusable: a
# broken signature, or a textHash bound to the wrong (uncanonicalized) bytes,
# both leave the visible text untouched. Round-trip the file we just minted
# through licensegen's own verifier so something on this branch proves an
# issued licence actually verifies.
ISSUED_FILE="jane@example.com.sealshotlicense"
[ -f "$ISSUED_FILE" ] || {
  echo "FAIL: issue did not write $ISSUED_FILE" >&2; exit 1; }
swift run licensegen verify "$ISSUED_FILE" >/dev/null 2>&1 || {
  echo "FAIL: a freshly issued licence does not verify" >&2
  swift run licensegen verify "$ISSUED_FILE" >&2 || true
  exit 1; }
echo "verify-round-trip OK"

# Business-volume branch has its own labels ("Purchaser email:", "User
# seats:") and closing paragraph — nothing else exercises it, so pin it too.
RAW_VOL=$(swift run licensegen issue --name "Acme Corp" --email "buyer@acme.example" \
        --seats 25 --type business-volume --months 12 2>/dev/null | sed -n '1,14p')
GOT_VOL=$(printf '%s' "$RAW_VOL" | sed \
  -e 's/^License ID:       .*/License ID:       <id>/' \
  -e 's/^License issued:   .*/License issued:   <date>/' \
  -e 's/^Updates through:  .*/Updates through:  <date>/')

read -r -d '' WANT_VOL <<'EOF' || true
Sealshot License
================
Licensed to:      Acme Corp
Purchaser email:  buyer@acme.example
License ID:       <id>
License type:     Business Volume
License issued:   <date>
App access:       Perpetual
Updates through:  <date>
User seats:       25
Macs per user:    3

This is an offline, organization-wide license for up to 25 users.
Sealshot does not transmit installation or usage information.
EOF

if [ "$GOT_VOL" != "$WANT_VOL" ]; then
  echo "PARITY FAIL — licensegen business-volume preamble does not match the app template" >&2
  diff <(printf '%s\n' "$WANT_VOL") <(printf '%s\n' "$GOT_VOL") >&2 || true
  exit 1
fi
echo "volume parity OK"

# A renewal reuses the licence id and extends from the existing window.
ID="550E8400-E29B-41D4-A716-446655440000"
OUT=$(swift run licensegen issue --name "Jane Doe" --email "jane@example.com" \
        --id "$ID" --extend-from 2099-01-15 --months 12 2>/dev/null)
printf '%s' "$OUT" | grep -q "License ID:       $ID" || {
  echo "FAIL: --id was not honoured" >&2; exit 1; }
printf '%s' "$OUT" | grep -q "Updates through:  2100-01-15" || {
  echo "FAIL: --extend-from did not extend the existing window" >&2; exit 1; }
echo "renewal OK"

# A renewal from a LAPSED (past) window must not shorten coverage: the
# effective start is max(existing window, today), never the stale date
# itself. Assert against a dynamically computed today+12mo so this only
# passes if the implementation actually clamps to today.
TODAY=$(date -u +%Y-%m-%d)
EXPECT_THROUGH=$(date -u -j -v+12m -f "%Y-%m-%d" "$TODAY" +%Y-%m-%d)
PAST_ID="650E8400-E29B-41D4-A716-446655440001"
OUT_PAST=$(swift run licensegen issue --name "Jane Doe" --email "jane@example.com" \
        --id "$PAST_ID" --extend-from 2020-01-01 --months 12 2>/dev/null)
printf '%s' "$OUT_PAST" | grep -q "Updates through:  $EXPECT_THROUGH" || {
  echo "FAIL: --extend-from in the past did not clamp to today (max() missing?)" >&2; exit 1; }
echo "lapsed-renewal-clamps-to-today OK"

# A malformed --id must be rejected, not silently swapped for a fresh UUID
# (that would issue an unrelated licence with no error). Assert on exit
# status and on no file being written, not on stdout text.
rm -f "jane@example.com.sealshotlicense"
set +e
swift run licensegen issue --name "Jane Doe" --email "jane@example.com" \
        --id "not-a-uuid" --months 12 >/dev/null 2>&1
STATUS_BADID=$?
set -e
if [ "$STATUS_BADID" -eq 0 ]; then
  echo "FAIL: malformed --id should exit non-zero, got 0" >&2; exit 1; fi
if [ -f "jane@example.com.sealshotlicense" ]; then
  echo "FAIL: malformed --id should not write a license file" >&2
  rm -f "jane@example.com.sealshotlicense"; exit 1; fi
echo "bad-id-rejected OK"

# A malformed --extend-from must be rejected, not silently swallowed by the
# max() clamp (a string/date max means an invalid value can "lose" to today
# and never reach the parser at all).
rm -f "jane@example.com.sealshotlicense"
set +e
swift run licensegen issue --name "Jane Doe" --email "jane@example.com" \
        --extend-from "2025-13-40" --months 12 >/dev/null 2>&1
STATUS_BADDATE=$?
set -e
if [ "$STATUS_BADDATE" -eq 0 ]; then
  echo "FAIL: malformed --extend-from should exit non-zero, got 0" >&2; exit 1; fi
if [ -f "jane@example.com.sealshotlicense" ]; then
  echo "FAIL: malformed --extend-from should not write a license file" >&2
  rm -f "jane@example.com.sealshotlicense"; exit 1; fi
echo "bad-extend-from-rejected OK"

# --seats and --months must not swallow malformed input either. "1O" (letter
# O) used to mint a silent ONE-seat licence, and on a manually invoiced
# volume order seats is the flag that carries the money. Zero/negative are
# rejected too — neither has a meaning.
for BAD in "--seats 1O" "--seats 0" "--seats -5" "--months 12x" "--months 0"; do
  rm -f "jane@example.com.sealshotlicense"
  set +e
  # shellcheck disable=SC2086
  swift run licensegen issue --name "Jane Doe" --email "jane@example.com" \
          $BAD >/dev/null 2>&1
  STATUS_BADNUM=$?
  set -e
  if [ "$STATUS_BADNUM" -eq 0 ]; then
    echo "FAIL: '$BAD' should exit non-zero, got 0" >&2; exit 1; fi
  if [ -f "jane@example.com.sealshotlicense" ]; then
    echo "FAIL: '$BAD' should not write a license file" >&2
    rm -f "jane@example.com.sealshotlicense"; exit 1; fi
done
echo "bad-seats-and-months-rejected OK"

# The defaults still apply when the flags are absent (1 seat, 12 months) —
# the guard above must not have turned "absent" into an error.
rm -f "jane@example.com.sealshotlicense"
OUT_DEFAULTS=$(swift run licensegen issue --name "Jane Doe" \
        --email "jane@example.com" 2>/dev/null)
printf '%s' "$OUT_DEFAULTS" | grep -q "Users:            1" || {
  echo "FAIL: absent --seats should default to 1" >&2; exit 1; }
echo "numeric-defaults OK"

rm -f "jane@example.com.sealshotlicense" "buyer@acme.example.sealshotlicense"
