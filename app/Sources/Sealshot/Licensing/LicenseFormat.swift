import Foundation
import CryptoKit

/// Shared "yyyy-MM-dd" (UTC) day parser — the single date vocabulary used
/// by license fields and the build's release-date stamp. Returns nil for
/// anything else; callers treat nil as fail-open.
enum UTCDay {
    static func parse(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)
    }
}

/// Which licence this file is. Raw values are the stable wire format and are
/// deliberately NOT the display strings — the preamble renders `.label`.
/// Decoding an unknown value fails: a type this build doesn't understand must
/// not silently render as another type.
enum LicenseType: String, Codable, Equatable {
    case individual = "individual"
    case businessVolume = "business-volume"

    var label: String {
        switch self {
        case .individual: return "Individual"
        case .businessVolume: return "Business Volume"
        }
    }
}

/// The signed fact a license asserts. The signature (in `SignedLicense`)
/// covers these exact payload BYTES — the payload travels base64-encoded and
/// is never re-serialized before verification, so JSON key order can't break
/// signatures. `textHash` binds the signed payload to the clear-text
/// preamble it ships with (see `LicenseFileFormat`) — it is itself part of
/// the signed bytes, so it can't be forged independently of the signature.
struct LicensePayload: Codable, Equatable {
    let id: UUID
    let name: String
    let email: String
    let licenseType: LicenseType
    let issued: String          // "yyyy-MM-dd" (UTC)
    /// "yyyy-MM-dd" (UTC), or EMPTY for a license that covers every future
    /// release. Empty is the normal case for anything issued from 2026-08-26
    /// on: updates are permanent, and the field is left blank rather than
    /// carrying a sentinel date, because every gate that reads it goes through
    /// `updatesThroughDate` and treats an unparseable value as "no limit".
    /// It never limited the APP — only which releases a license covers.
    let updatesThrough: String
    let seats: Int
    let textHash: String        // base64(SHA256(canonicalized preamble)) — see LicenseFileFormat

    /// `textHash` defaults to "" so call sites that only care about the
    /// other fields (e.g. UpdatePolicyTests, EntitlementGateTests) don't
    /// need to fabricate a hash. Real license payloads always carry a real
    /// hash — see `LicenseFormatTests.makeLicenseFile`.
    init(id: UUID, name: String, email: String, licenseType: LicenseType, issued: String,
         updatesThrough: String, seats: Int, textHash: String = "") {
        self.id = id
        self.name = name
        self.email = email
        self.licenseType = licenseType
        self.issued = issued
        self.updatesThrough = updatesThrough
        self.seats = seats
        self.textHash = textHash
    }

    var updatesThroughDate: Date? { UTCDay.parse(updatesThrough) }
}

enum LicenseError: Error, Equatable {
    case malformed
    case unknownSigningKey
    case badSignature
    case revoked
    /// Preamble text doesn't hash to `payload.textHash` — the clear-text
    /// portion of the file was edited (or the preamble was stripped/rebuilt)
    /// after issuance.
    case textTampered
}

/// Envelope: the signed blob embedded in a `.sealshotlicense` file after the
/// `SEALSHOT1.` marker. Never accepted on its own — see `LicenseFileFormat`.
struct SignedLicense: Codable, Equatable {
    let v: Int
    let key: Int        // which embedded public key signed it (1 primary, 2 standby)
    let payload: String // base64 of the LicensePayload JSON bytes
    let sig: String     // base64 Ed25519 signature over those bytes
}

/// The clear-text `.sealshotlicense` file format — the ONLY valid license
/// artifact (no back-compat with bare blobs or bare envelope JSON). A file
/// is a human-readable preamble (name/email/id/dates, for display and to
/// make sharing the working artifact necessarily share the identity)
/// followed by a `SEALSHOT1.<base64 envelope>` line. The preamble's
/// canonicalized SHA256 is bound into the signed payload
/// (`LicensePayload.textHash`), so editing or stripping the preamble
/// invalidates the license without any new crypto.
///
/// This canonicalization is the ONE shared implementation on the app side —
/// both issuance-time hashing (test helpers here) and verification
/// (`LicenseVerifier`) call through it, so they can't drift from each
/// other. licensegen (scripts/licensegen/Sources/licensegen/main.swift)
/// implements the identical algorithm on the CLI side — keep the two in
/// lockstep; each file has a comment pointing at the other.
enum LicenseFileFormat {
    static let blobPrefix = "SEALSHOT1."

    /// Canonicalize whole file text before locating the blob line or hashing
    /// the preamble:
    /// 1. Strip a leading UTF-8 BOM.
    /// 2. Normalize line endings: CRLF and lone CR → LF.
    /// 3. Unicode-normalize to NFC.
    /// 4. Trim trailing whitespace from each line.
    /// Must match licensegen's `canonicalize` exactly.
    static func canonicalize(_ text: String) -> String {
        var t = text
        if t.hasPrefix("\u{FEFF}") { t.removeFirst() }
        t = t.replacingOccurrences(of: "\r\n", with: "\n")
             .replacingOccurrences(of: "\r", with: "\n")
        t = t.precomposedStringWithCanonicalMapping
        let lines = t.components(separatedBy: "\n").map { line -> String in
            var s = Substring(line)
            while let last = s.last, last.isWhitespace { s.removeLast() }
            return String(s)
        }
        return lines.joined(separator: "\n")
    }

    /// Split canonicalized file text into (preamble, blob base64). Preamble
    /// is everything before the first line starting with `blobPrefix`, with
    /// trailing blank lines dropped. Returns nil when there's no blob line,
    /// the preamble is empty (a bare `SEALSHOT1.` blob), or there's any
    /// non-blank content after the blob line — all malformed. Blank/
    /// whitespace-only trailing lines are tolerated (transport tolerance:
    /// extra trailing newlines from re-saving), but real appended content
    /// would otherwise be silently ignored, letting garbage ride along in a
    /// file that still verifies VALID.
    static func splitPreambleAndBlob(_ canonicalizedText: String) -> (preamble: String, blobBase64: String)? {
        let lines = canonicalizedText.components(separatedBy: "\n")
        guard let blobIndex = lines.firstIndex(where: { $0.hasPrefix(blobPrefix) }) else { return nil }
        guard lines[(blobIndex + 1)...].allSatisfy({ $0.isEmpty }) else { return nil }
        var preambleLines = Array(lines[..<blobIndex])
        while preambleLines.last == "" { preambleLines.removeLast() }
        guard !preambleLines.isEmpty else { return nil }
        return (preambleLines.joined(separator: "\n"), String(lines[blobIndex].dropFirst(blobPrefix.count)))
    }

    /// base64(SHA256(utf8 bytes of the canonicalized preamble)).
    static func textHash(preamble: String) -> String {
        Data(SHA256.hash(data: Data(preamble.utf8))).base64EncodedString()
    }

    /// Label column width. Values align at column 18 (see the v1.0 pricing doc).
    static let labelColumn = 18
    /// Policy constant, not a payload field: one seat covers three Macs, for
    /// individual and volume seats alike. The rendered preamble is stored in the
    /// file, so changing this can never alter an already-issued licence.
    ///
    /// Raised 2 -> 3 on 2026-08-16. Must stay in lockstep with licensegen's
    /// `macsPerUser` and the Worker's `MACS_PER_USER`, or the three builders
    /// emit different bytes and textHash stops matching.
    static let macsPerUser = 3

    /// Build the exact preamble template (labels padded to an 18-char
    /// column so values align) used by licensegen at issue time and by
    /// tests that need a realistic file. Not used by the app at runtime —
    /// the app only ever parses/verifies, never issues.
    static func buildPreamble(name: String, email: String, id: UUID, issued: String,
                               updatesThrough: String, seats: Int,
                               licenseType: LicenseType) -> String {
        func field(_ label: String, _ value: String) -> String {
            label.padding(toLength: max(label.count, labelColumn), withPad: " ", startingAt: 0) + value
        }
        let isVolume = licenseType == .businessVolume
        // Empty updatesThrough = updates are permanent. A blank value after
        // "Updates through:" would read as an omission on the one document a
        // customer keeps, so the LABEL changes with it.
        let isPermanent = updatesThrough.isEmpty
        var lines = [
            "Sealshot License",
            String(repeating: "=", count: 16),
            field("Licensed to:", name),
            field(isVolume ? "Purchaser email:" : "Email:", email),
            field("License ID:", id.uuidString),
            field("License type:", licenseType.label),
            field("License issued:", issued),
            field("App access:", "Perpetual"),
            isPermanent ? field("Updates:", "All future versions")
                        : field("Updates through:", updatesThrough),
            field(isVolume ? "User seats:" : "Users:", String(seats)),
            field("Macs per user:", String(macsPerUser)),
            "",
        ]
        if isVolume {
            lines += [
                "This is an offline, organization-wide license for up to \(seats) users.",
                "Sealshot does not transmit installation or usage information.",
            ]
        } else {
            lines += [
                "This license does not expire. It permits use of every Sealshot",
                isPermanent ? "release, including all future versions."
                            : "release whose entitlement date is on or before \(updatesThrough).",
                "",
                "Keep this file exactly as received. The information above is",
                "cryptographically signed; modifying it invalidates the license.",
            ]
        }
        return lines.joined(separator: "\n")
    }
}
