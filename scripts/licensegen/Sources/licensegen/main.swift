import Foundation
import CryptoKit
import Security

// Sealshot license tooling. The Ed25519 signing key lives ONLY in the login
// Keychain (service below) — never in the repo. Public keys are embedded in
// the app (LicenseKeys.swift).
let keychainService = "com.seal-shot.licensegen"
// keygen supports --account standby to mint the pre-embedded rotation key;
// issue/revoke always sign with "primary".
let keychainAccount = arg("account") ?? "primary"

struct SignedLicense: Codable {
    let v: Int; let key: Int; let payload: String; let sig: String
}

/// Mirrors LicenseType in app/Sources/Sealshot/Licensing/LicenseFormat.swift.
/// Raw values are the stable wire format, not the display strings.
enum LicenseType: String, Codable {
    case individual = "individual"
    case businessVolume = "business-volume"

    var label: String {
        switch self {
        case .individual: return "Individual"
        case .businessVolume: return "Business Volume"
        }
    }
}

struct LicensePayload: Codable {
    let id: UUID; let name: String; let email: String; let licenseType: LicenseType
    let issued: String; let updatesThrough: String; let seats: Int
    let textHash: String  // base64(SHA256(canonicalized preamble)) — see canonicalize() below
}
struct Blocklist: Codable {
    let v: Int; let key: Int; let revoked: [UUID]; let updated: String; let sig: String
}

func die(_ msg: String) -> Never { FileHandle.standardError.write(Data((msg + "\n").utf8)); exit(1) }

// MARK: - Clear-text license file format
//
// Mirrors LicenseFileFormat in
// app/Sources/Sealshot/Licensing/LicenseFormat.swift — the app's canonicalize/
// splitPreambleAndBlob/textHash/buildPreamble implement the IDENTICAL
// algorithm. Keep the two in lockstep; there is no shared package between
// this CLI and the app target.

let blobPrefix = "SEALSHOT1."

/// Canonicalize whole file text before locating the blob line or hashing the
/// preamble: strip a leading BOM, normalize line endings to LF, NFC-
/// normalize, trim trailing whitespace per line. Tolerates editor re-saves
/// of the file — not email rewrapping (the blob stays one line, no
/// whitespace-collapsing).
func canonicalize(_ text: String) -> String {
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

/// Preamble = canonicalized lines before the first `SEALSHOT1.` line,
/// trailing blanks dropped. nil when there's no blob line, the preamble is
/// empty (a bare blob), or there's any non-blank content after the blob
/// line (garbage appended after the blob would otherwise be silently
/// ignored). Blank/whitespace-only trailing lines are still tolerated.
func splitPreambleAndBlob(_ canonicalizedText: String) -> (preamble: String, blobBase64: String)? {
    let lines = canonicalizedText.components(separatedBy: "\n")
    guard let blobIndex = lines.firstIndex(where: { $0.hasPrefix(blobPrefix) }) else { return nil }
    guard lines[(blobIndex + 1)...].allSatisfy({ $0.isEmpty }) else { return nil }
    var preambleLines = Array(lines[..<blobIndex])
    while preambleLines.last == "" { preambleLines.removeLast() }
    guard !preambleLines.isEmpty else { return nil }
    return (preambleLines.joined(separator: "\n"), String(lines[blobIndex].dropFirst(blobPrefix.count)))
}

/// base64(SHA256(utf8 bytes of the canonicalized preamble)).
func textHash(preamble: String) -> String {
    Data(SHA256.hash(data: Data(preamble.utf8))).base64EncodedString()
}

/// Label column width. Values align at column 18 (see the v1.0 pricing doc).
/// Must match LicenseFileFormat.labelColumn in the app.
let labelColumn = 18
/// Policy constant, not a payload field: one seat covers two Macs, for
/// individual and volume seats alike. Must match LicenseFileFormat.macsPerUser.
let macsPerUser = 3

/// Exact preamble template (labels padded to an 18-char column so values
/// align), 7-bit ASCII except the customer's own name/email. Must match
/// LicenseFileFormat.buildPreamble in the app exactly.
func buildPreamble(name: String, email: String, id: UUID, issued: String,
                   updatesThrough: String, seats: Int, licenseType: LicenseType) -> String {
    func field(_ label: String, _ value: String) -> String {
        label.padding(toLength: max(label.count, labelColumn), withPad: " ", startingAt: 0) + value
    }
    let isVolume = licenseType == .businessVolume
    // Empty updatesThrough = updates are permanent; the LABEL changes with it,
    // because "Updates through:" with nothing after it reads as a missing field.
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

/// Reject control characters (including newlines/tabs, which would let a
/// crafted --name/--email inject extra preamble lines) and bidi-override/
/// isolate controls (which could visually disguise the identity shown to
/// the customer). Dies rather than silently stripping — the operator needs
/// to know the input was rejected.
func sanitizeOrDie(_ argName: String, _ value: String) {
    let bidiControls: ClosedRange<UInt32> = 0x202A...0x202E
    let bidiIsolates: ClosedRange<UInt32> = 0x2066...0x2069
    for scalar in value.unicodeScalars {
        if scalar.properties.generalCategory == .control
            || bidiControls.contains(scalar.value) || bidiIsolates.contains(scalar.value) {
            die("--\(argName) contains a control or bidi-override character (U+\(String(scalar.value, radix: 16, uppercase: true))) — not allowed")
        }
    }
}

func loadKey() -> Curve25519.Signing.PrivateKey {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: keychainService,
        kSecAttrAccount as String: "primary",
        kSecReturnData as String: true,
    ]
    var out: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
          let data = out as? Data,
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data)
    else { die("no signing key — run: licensegen keygen") }
    return key
}

func saveKey(_ key: Curve25519.Signing.PrivateKey) {
    let attrs: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: keychainService,
        kSecAttrAccount as String: keychainAccount,
        kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        kSecValueData as String: key.rawRepresentation,
    ]
    let status = SecItemAdd(attrs as CFDictionary, nil)
    guard status == errSecSuccess else { die("keychain save failed: \(status)") }
}

func keyExists() -> Bool {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: keychainService,
        kSecAttrAccount as String: keychainAccount,
    ]
    return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
}

func arg(_ name: String) -> String? {
    guard let i = CommandLine.arguments.firstIndex(of: "--" + name),
          i + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[i + 1]
}

/// Numeric flag with a default: absent uses the default, but a value that is
/// present and unparseable (or non-positive) dies instead of silently
/// defaulting. `Int(arg("seats") ?? "1") ?? 1` would mint a ONE-seat licence
/// for `--seats 1O` (letter O) — and on a manually invoiced volume order,
/// seats is the flag that carries the money.
func positiveIntOrDie(_ name: String, default defaultValue: Int) -> Int {
    guard let raw = arg(name) else { return defaultValue }
    guard let value = Int(raw), value > 0 else {
        die("--\(name) must be a positive whole number (got \"\(raw)\")")
    }
    return value
}

func dayString(_ date: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: date)
}

let encoder: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return e }()

/// Mirrors `UTCDay.parse` in the app's LicenseFormat.swift.
enum UTCDayParser {
    static func parse(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)
    }
}

switch CommandLine.arguments.dropFirst().first {
case "keygen":
    guard !keyExists() else { die("key already exists in keychain (service \(keychainService)) — refusing to overwrite") }
    let key = Curve25519.Signing.PrivateKey()
    saveKey(key)
    print("public key (base64) — paste into LicenseKeys.swift:")
    print(key.publicKey.rawRepresentation.base64EncodedString())

case "issue":
    guard let name = arg("name"), let email = arg("email") else {
        die("usage: licensegen issue --name \"Jane Doe\" --email jane@x.com [--seats 1] [--months N] [--type individual|business-volume] [--id <uuid>] [--extend-from <yyyy-MM-dd>]\n"
            + "       updates are PERMANENT unless --months is given")
    }
    sanitizeOrDie("name", name)
    sanitizeOrDie("email", email)
    let seats = positiveIntOrDie("seats", default: 1)
    // Permanent by default — that is what every product sells now. `--months N`
    // still issues a dated license, for reproducing an older one or honouring
    // terms agreed before the change. There is deliberately no `--months 0`
    // spelling of "permanent": omitting the flag is the spelling.
    let months = arg("months").map { _ in positiveIntOrDie("months", default: 12) }
    let typeRaw = arg("type") ?? "individual"
    guard let licenseType = LicenseType(rawValue: typeRaw) else {
        die("--type must be individual or business-volume")
    }
    // Renewal: reuse the licence id and extend from whichever is later, the
    // existing window or today — renewing early must never lose unused time,
    // and renewing after a lapse starts fresh from today.
    let id: UUID
    if let idStr = arg("id") {
        guard let parsed = UUID(uuidString: idStr) else { die("--id must be a UUID") }
        id = parsed
    } else {
        id = UUID()
    }
    let now = Date()
    let today = dayString(now)
    guard let todayDate = UTCDayParser.parse(today) else { die("internal error: could not parse today's date") }
    let baseDate: Date
    if let extendFrom = arg("extend-from") {
        guard let parsed = UTCDayParser.parse(extendFrom) else { die("--extend-from must be yyyy-MM-dd") }
        baseDate = max(parsed, todayDate)
    } else {
        baseDate = todayDate
    }
    // Month arithmetic in UTC, not local time. Every date here is a UTC
    // midnight and is formatted back as UTC, so a default-timezone calendar
    // adds months in local time and formats the result in UTC: west of
    // Greenwich that lands a day SHORT across a DST transition (on UTC-8,
    // 2027-03-14 + 12mo → 2028-03-13), shortening a paid update window, and
    // it is what turns 2025-01-31 + 1mo into 2025-03-01. The Worker applies
    // this rule in UTC — the two issuers must not disagree.
    var utcCalendar = Calendar(identifier: .gregorian)
    utcCalendar.timeZone = TimeZone(identifier: "UTC")!
    let issued = today
    let updatesThrough = months.map { dayString(utcCalendar.date(byAdding: .month, value: $0, to: baseDate)!) } ?? ""
    let preamble = buildPreamble(name: name, email: email, id: id, issued: issued,
                                 updatesThrough: updatesThrough, seats: seats, licenseType: licenseType)
    // Hash the CANONICALIZED preamble — every verify path canonicalizes
    // before hashing, so hashing the raw (as-built) preamble here would
    // mint a license that immediately fails verification whenever a field
    // value needs canonicalizing (trailing whitespace, NFD-decomposed
    // characters). The preamble embedded in the file itself stays raw —
    // only the hash input is canonicalized, matching what verify() does.
    let hash = textHash(preamble: canonicalize(preamble))
    let payload = LicensePayload(id: id, name: name, email: email, licenseType: licenseType,
                                 issued: issued, updatesThrough: updatesThrough, seats: seats,
                                 textHash: hash)
    let payloadData = try! encoder.encode(payload)
    let sig = try! loadKey().signature(for: payloadData)
    let lic = SignedLicense(v: 1, key: 1, payload: payloadData.base64EncodedString(),
                            sig: sig.base64EncodedString())
    let envelopeJSON = try! encoder.encode(lic)
    let fileText = preamble + "\n\n" + blobPrefix + envelopeJSON.base64EncodedString() + "\n"
    let file = "\(email).sealshotlicense"
    try! fileText.write(to: URL(fileURLWithPath: file), atomically: true, encoding: .utf8)
    // Status goes to stderr so stdout is exactly the file text — attach
    // this file to the customer's email as-is, or redirect stdout to
    // recreate it.
    FileHandle.standardError.write(Data("wrote \(file)  (license id \(id)) - attach this file to the customer email\n".utf8))
    print(fileText, terminator: "")

case "revoke":
    guard let idStr = arg("id"), let id = UUID(uuidString: idStr), let path = arg("blocklist") else {
        die("usage: licensegen revoke --id <UUID> --blocklist path/license-blocklist.json")
    }
    var revoked: [UUID] = []
    if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
       let old = try? JSONDecoder().decode(Blocklist.self, from: data) { revoked = old.revoked }
    if !revoked.contains(id) { revoked.append(id) }
    let sorted = revoked.map(\.uuidString).sorted().joined(separator: ",")
    let sig = try! loadKey().signature(for: Data(sorted.utf8))
    let list = Blocklist(v: 1, key: 1, revoked: revoked.sorted { $0.uuidString < $1.uuidString },
                         updated: dayString(Date()), sig: sig.base64EncodedString())
    try! encoder.encode(list).write(to: URL(fileURLWithPath: path))
    print("blocklist now revokes \(revoked.count) license(s) — commit + push to Sealshot-Release")

case "verify":
    guard CommandLine.arguments.count > 2,
          let rawText = try? String(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]), encoding: .utf8)
    else { die("usage: licensegen verify <file.sealshotlicense>") }
    guard let (preamble, blobBase64) = splitPreambleAndBlob(canonicalize(rawText)) else {
        print("INVALID — not a clear-text license file (no preamble found)")
        exit(1)
    }
    guard let envelopeData = Data(base64Encoded: blobBase64),
          let lic = try? JSONDecoder().decode(SignedLicense.self, from: envelopeData),
          let payloadData = Data(base64Encoded: lic.payload),
          let sig = Data(base64Encoded: lic.sig)
    else {
        print("INVALID — malformed license blob")
        exit(1)
    }
    guard loadKey().publicKey.isValidSignature(sig, for: payloadData) else {
        print("INVALID SIGNATURE")
        exit(1)
    }
    guard let payload = try? JSONDecoder().decode(LicensePayload.self, from: payloadData) else {
        print("INVALID — malformed payload")
        exit(1)
    }
    guard textHash(preamble: preamble) == payload.textHash else {
        print("INVALID — license file text has been modified")
        exit(1)
    }
    print("VALID — \(payload.name) <\(payload.email)> updates "
          + (payload.updatesThrough.isEmpty ? "permanent" : "through \(payload.updatesThrough)"))

default:
    die("usage: licensegen keygen|issue|revoke|verify")
}
