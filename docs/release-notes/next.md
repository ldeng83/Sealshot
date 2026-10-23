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


## New

- **Rotate and flip the whole image.** Image ▸ Rotate Left (⌘L), Rotate Right
  (⌘R), Flip Horizontal, Flip Vertical and Reset Orientation — also on a button
  beside the size readout and in the canvas's right-click menu. Your marks turn
  with the image and land on the same spots; text and steps move with it but
  stay upright and readable. It never touches the original pixels: Reset
  Orientation or Revert to Original brings the image back as it was, and each
  turn or flip is one undo step. A rotated or flipped capture needs Sealshot
  0.8.3 or later to open.

## Improvements

- **Steps are sized for the image you're on.** A new image starts with a step
  size that suits its resolution instead of one fixed size that looked tiny on a
  large Retina capture, and the Size slider goes much higher on big images.
  Whatever size you last set — with the slider, by dragging a step's handle, or
  by drawing a step out — is the size of the next one in that image. While you
  drag a step's handle the Size slider moves with it, and the handle stops where
  the slider does.

## Fixes

- **Live Text copies one column at a time.** On a page with columns or a
  sidebar, selecting text down one column also grabbed the lines beside it, and
  the copied text came out interleaved. Live Text now reads each block of text
  on its own, so a selection or copy stays where you made it.

- **Live Text reads a capital O in codes.** Order numbers, license keys and other
  codes with a letter O next to digits were read with a zero — "O-1042" came
  out as "0-1042". Live Text now looks at the letter's shape and gets it right.

- **Double-click highlights the whole word.** The highlight on a double-clicked
  word in Live Text could stop a letter short or spill one letter over, even
  though the copied text was right. It now covers the word exactly.

- **Fit Width keeps your place.** Choosing Fit Width on a tall capture jumped to
  the middle of the image; it now keeps the part you were looking at. Fit Height
  does the same on a wide one.

- **A new capture opens the editor even after you closed it.** Closing the
  Sealshot window used to keep it closed for every capture afterwards. Taking a
  capture now opens it on the new shot.

- **Resize a text box while you're typing in it.** The handles around a text box
  you're typing in now work: drag one to rewrap the text, and keep typing.
  Pressing Esc while typing now finishes the text and deselects it, like the
  other tools.

- **Sealshot always opens a window.** If the capture you last had open couldn't
  be read, Sealshot launched with no window and no message. It now opens the
  window and tells you which capture couldn't be opened.
