<!--
Running release notes for the NEXT release. Any change that alters
user-visible behavior adds a bullet here, in plain user language (what
changed for the user, not how). Group bullets under the ## headings below;
add or drop headings as needed.

At release time scripts/release.sh promotes this file to v<VERSION>.md and
uses it for the Sparkle appcast description, the GitHub release body, and a
website changelog PR. Publishing fails if no notes exist. After a release,
recreate this file with this same comment on top.
-->


## Fixes

- **Live Text now reads pasted images.** Paste a screenshot onto a new canvas
  (or on top of another capture) and Live Text, Find in Image and QR detection
  said "no text found" over text that was plainly on screen — they were reading
  the canvas underneath the pasted picture instead of the picture. They now
  read what you see.

- **Quick Look keeps its keyboard on a second display.** With the preview open,
  clicking another app on your other monitor and then clicking back on the
  preview left Esc, the arrow keys and Space doing nothing — the preview was
  still on screen but the keyboard had stayed with the other app, and the only
  way out was dismissing the preview. Clicking the preview now takes the
  keyboard back, the way Finder's Quick Look does.

- **The strip no longer sticks on an old capture you opened.** Opening an image
  from the Library that was too old to be in the editor's strip used to park it
  in the first slot for the rest of the session, so every screenshot you took
  afterwards appeared *behind* it. Opened captures now simply count as recent
  and take their place in the strip like anything else — and a new screenshot
  is always first again. Nothing is written to the capture itself just because
  you looked at it.

- **Live Text no longer switches Enhance Clarity on for you.** Picking the Live
  Text tool used to turn Enhance Clarity on behind your back — and on a capture
  that had never been enhanced, it quietly ran the whole enhancement first,
  leaving that generated image saved inside the capture afterwards. Live Text
  now simply reads the picture you are looking at: the enhanced version when you
  have Enhance Clarity on, the original when you don't. Find in Image and QR
  detection follow the same rule. If small text reads poorly, turn on Enhance
  Clarity and Live Text will use it.
