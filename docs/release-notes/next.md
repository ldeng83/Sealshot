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


## Changes

- **Sealshot is now donation-supported, on the honor system.** The occasional
  reminder asks for a donation of any amount, and its "I Already Donated"
  button — or the checkbox in the new **Settings ▸ Support** tab — turns it
  off for good. Nothing verifies it: that's the point.

- **License files are retired.** Donations no longer come with a license, so
  there is nothing to activate, move between Macs, or lose. A license you
  already have keeps working exactly as before — Settings shows it as your
  supporter license, including one whose update window has lapsed, since
  there are no renewals for a lapse to sell. The License tab's activation
  machinery is gone with the files.
