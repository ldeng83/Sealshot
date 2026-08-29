# Security policy

Sealshot handles screenshots, screen recordings, and an encrypted library of
both — material that is often more sensitive than the app that holds it. A
security report is one of the more useful things you can send us.

## Supported versions

Sealshot is a single line of releases, and fixes go into the next one. Only the
most recent release is supported.

| Version | Supported |
|---|---|
| 0.8.1 (latest — see [Releases](https://github.com/ldeng83/Sealshot/releases)) | ✅ |
| 0.8.0 and earlier | ❌ — update first, then report if it still reproduces |

Installed copies update themselves through the Sparkle feed in `appcast.xml`;
builds from source track `main`.

## Reporting a vulnerability

**Please don't open a public issue, pull request, or discussion for a security
problem.** Use one of these instead:

- **[Report a vulnerability privately](https://github.com/ldeng83/Sealshot/security/advisories/new)**
  — GitHub's private advisory form. Preferred: it keeps the report, the fix,
  and the eventual disclosure in one place, visible only to you and the
  maintainer.
- **Email [support@seal-shot.com](mailto:support@seal-shot.com)** with
  `Security` in the subject, if you'd rather not use GitHub.

Useful to include, as much as you have:

- the Sealshot version and build (**Sealshot ▸ About**), or the commit if you
  built from source
- macOS version and whether the Mac is Apple silicon or Intel
- steps to reproduce, and what an attacker gets out of it
- a proof of concept, if you have one — please strip real personal data out of
  any sample captures you attach

## What to expect

- an acknowledgment within **3 business days**
- an assessment within **7 days**, with a fix target or an explanation of why
  we think it isn't exploitable
- a fix in the next release, or a patch release of its own if it's serious
- credit in the release notes and the published advisory, unless you'd rather
  stay anonymous

Sealshot is a one-person, donation-funded project, so there's no bug bounty.
Credit and genuine thanks are what we can offer.

## Scope

In scope, in this repository:

- the application in `app/`
- the release and notarization pipeline in `scripts/`
- the Sparkle update feed (`appcast.xml`) and the signature checks around it
- `license-blocklist.json` and how the app verifies it
- the signed, notarized DMGs published under Releases

Also worth reporting through the same channels, even though they live
elsewhere: the seal-shot.com website and the donation flow behind it.

We're particularly interested in anything that:

- moves capture data, recordings, or the library off the Mac
- reads encrypted-at-rest data without the user's Touch ID or passphrase
- makes a redaction reversible — a region that looks redacted on screen or in
  an export but can still be recovered from the file
- gets Sealshot to fetch, trust, or run code that isn't a properly signed
  Sealshot update

Sealshot makes exactly three kinds of network request — update checks, the
revoked-license list, and the optional redaction model download — all
documented in the [privacy policy](https://seal-shot.com/privacy/). A fourth
one is a bug worth reporting.

Out of scope:

- anything that already requires code execution, admin rights, or physical
  access to an unlocked Mac
- missing hardening with no demonstrated exploit path, and scanner output with
  no demonstrated impact
- resource exhaustion or crashes that only affect the person running the app
- vulnerabilities in macOS or in third-party dependencies — report those
  upstream, and tell us if Sealshot's particular use of them makes things worse
