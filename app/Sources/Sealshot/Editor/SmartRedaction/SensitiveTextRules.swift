import Foundation

/// A sensitive match within a single line of recognized text. `range` is in
/// character offsets (indexes into `RecognizedLine.characters`/`charBoxes`),
/// not UTF-16 units.
struct SensitiveMatch: Equatable {
    let category: SensitiveCategory
    let text: String
    let range: Range<Int>
}

/// Pure pattern-matching over OCR'd text — no Vision dependency. Patterns
/// originate from the SealshotSpike detector POC; the entropy detector is
/// suppressed wherever a stronger pattern already matched, so opaque tokens
/// with a known shape (Stripe keys, JWTs…) are reported once, by name.
enum SensitiveTextRules {

    private struct Rule {
        let category: SensitiveCategory
        let regex: NSRegularExpression
        let postFilter: ((String) -> Bool)?
        /// Which capture group to report/redact (0 = whole match). Used by the
        /// `key = value` rule to redact only the value, not the `password=` label.
        let captureGroup: Int

        init(_ category: SensitiveCategory, _ pattern: String,
             captureGroup: Int = 0,
             postFilter: ((String) -> Bool)? = nil) {
            self.category = category
            self.regex = try! NSRegularExpression(pattern: pattern, options: [])
            self.captureGroup = captureGroup
            self.postFilter = postFilter
        }
    }

    /// Standard comprehensive IPv6 matcher: the full 8-hextet form plus every
    /// `::`-compressed form. Every compressed alternative requires a `::`, so a
    /// plain `HH:MM:SS` time (only two colons, no `::`) never matches — that
    /// requirement is what keeps this rule safe, and it survives the spaces
    /// below untouched.
    ///
    /// Each colon may be followed by ONE space. OCR inserts them into long
    /// colon runs: a real screenshot recognized
    /// `2001:db8:85a3::8a2e:370:7334` as `2001:db8: 85a3: :8a2e:370:7334`,
    /// which the strict form missed entirely, leaving the address in the
    /// clear. A single optional space cannot turn a timestamp into a match
    /// because it doesn't create a `::`.
    private static let hextet = #"[0-9A-Fa-f]{1,4}"#
    /// A colon as OCR may render it — optionally followed by one space.
    private static let colon = #":\s?"#
    /// Alternation order matters: the engine takes the FIRST alternative that
    /// matches, not the longest, so every form ending in a hextet is listed
    /// before the one ending in `::`. Otherwise `fe80::1` matched as `fe80::`
    /// and redaction left the final hextet on screen.
    private static let ipv6Pattern =
        #"(?:\#(hextet)\#(colon)){7}\#(hextet)"#
        + #"|(?:\#(hextet)\#(colon)){1,6}\#(colon)\#(hextet)"#
        + #"|(?:\#(hextet)\#(colon)){1,5}(?:\#(colon)\#(hextet)){1,2}"#
        + #"|(?:\#(hextet)\#(colon)){1,4}(?:\#(colon)\#(hextet)){1,3}"#
        + #"|(?:\#(hextet)\#(colon)){1,3}(?:\#(colon)\#(hextet)){1,4}"#
        + #"|(?:\#(hextet)\#(colon)){1,2}(?:\#(colon)\#(hextet)){1,5}"#
        + #"|\#(hextet)\#(colon)(?:\#(colon)\#(hextet)){1,6}"#
        + #"|(?:\#(hextet)\#(colon)){1,7}\#(colon)"#

    private static let rules: [Rule] = [
        Rule(.email, #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#),
        // `(?<!\w)` instead of `\b` so a match can start at "+1 …" but not in
        // the middle of a longer digit/hex run (UUIDs, commit hashes).
        Rule(.phone, #"(?<!\w)(?:\+?1[\s.\-]?)?\(?\d{3}\)?[\s.\-]?\d{3}[\s.\-]?\d{4}\b"#,
             postFilter: { text in
                 let digits = text.filter(\.isNumber).count
                 return digits >= 10 && digits <= 11
             }),
        // International (E.164-ish): "+CC …" with any grouping — "+33 1 42 60
        // 09 16", "+44 20 7946 0958". The NANP rule above can't see non-US
        // groupings. The leading "+" plus an 8–15 digit count keeps false
        // positives near zero.
        Rule(.phone, #"(?<!\w)\+\d{1,3}[\s.\-]?(?:\(\d{1,4}\)[\s.\-]?)?\d(?:[\s.\-]?\d){5,13}\b"#,
             postFilter: { text in
                 let digits = text.filter(\.isNumber).count
                 return digits >= 8 && digits <= 15
             }),
        Rule(.creditCard, #"\b(?:\d[ \-]?){12,18}\d\b"#),
        // Card-fragment disclosure: "Visa ending in 4242" — the last four are
        // the only digits shown, so the PAN rule can't fire. Redact the digits.
        Rule(.creditCard,
             #"(?i)\b(?:card|visa|mastercard|amex|american\s+express|discover|debit|account|acct)\s+ending(?:\s+in)?\s+(\d{4})\b"#,
             captureGroup: 1),
        // Masked PAN: "Visa **** 4242", "•••• •••• •••• 4242" — redact the
        // visible last four.
        Rule(.creditCard, #"(?:[*•xX]{2,4}[\s\-]?){1,4}\s*(\d{4})\b"#, captureGroup: 1),

        // MARK: Cloud / API secrets (anchored — near-zero false positives)
        Rule(.awsKey, #"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#),
        Rule(.stripeKey, #"\b[sp]k_(?:live|test)_[A-Za-z0-9]{20,}\b"#),
        Rule(.githubToken, #"\bghp_[A-Za-z0-9]{36}\b"#),
        Rule(.githubToken, #"\bgithub_pat_[A-Za-z0-9_]{82}\b"#),
        Rule(.gitlabToken, #"\bglpat-[A-Za-z0-9_\-]{20}\b"#),
        Rule(.jwt, #"\beyJ[A-Za-z0-9_\-]{10,}\.eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\b"#),
        Rule(.bearerToken, #"\bBearer\s+[A-Za-z0-9_\-\.=]{20,}\b"#),
        Rule(.googleApiKey, #"\bAIza[0-9A-Za-z_\-]{35}\b"#),
        Rule(.slackToken, #"\bxox[baprs]-[0-9A-Za-z\-]{10,}\b"#),
        // Anthropic before OpenAI: `sk-ant-…` also satisfies the looser `sk-…`,
        // and overlap resolution keeps the higher-confidence (anthropic) one.
        Rule(.anthropicKey, #"\bsk-ant-[A-Za-z0-9_\-]{20,}\b"#),
        Rule(.openAIKey, #"\bsk-(?:proj-)?[A-Za-z0-9_\-]{20,}\b"#),
        Rule(.sendgridKey, #"\bSG\.[A-Za-z0-9_\-]{22}\.[A-Za-z0-9_\-]{43}\b"#),
        Rule(.twilioKey, #"\b(?:AC|SK)[a-f0-9]{32}\b"#),
        // Dashes are ADVISORY, not required. OCR routinely eats a run of them
        // — a real screenshot recognized `-----BEGIN PRIVATE KEY-----` as
        // `--BEGIN PRIVATE KEY-`, and the fixed 5-dash form matched nothing,
        // leaving a private key entirely unredacted. The phrase itself is
        // unambiguous, so it carries the rule. END too: OCR splits the block
        // into separate lines and the closing marker is its own line.
        Rule(.privateKeyBlock,
             #"(?i)-*\s*BEGIN\s+(?:RSA|EC|OPENSSH|DSA|PGP|ENCRYPTED)?\s*PRIVATE\s+KEY\s*-*"#),
        Rule(.privateKeyBlock,
             #"(?i)-*\s*END\s+(?:RSA|EC|OPENSSH|DSA|PGP|ENCRYPTED)?\s*PRIVATE\s+KEY\s*-*"#),
        // DB connection URIs and basic-auth URLs: `scheme://user:pass@host`.
        Rule(.credentialedURL,
             #"\b(?:postgres(?:ql)?|mysql|mongodb(?:\+srv)?|redis|amqp|ftp|https?)://[^\s:@/]+:[^\s:@/]+@\S+"#),

        // MARK: Financial (checksum-validated)
        Rule(.iban, #"\b[A-Z]{2}\d{2}[A-Z0-9]{11,30}\b"#, postFilter: { isIBANValid($0) }),
        Rule(.routingNumber, #"\b\d{9}\b"#, postFilter: { isABARoutingValid($0) }),
        Rule(.cryptoWallet, #"\b0x[a-fA-F0-9]{40}\b"#),
        Rule(.cryptoWallet, #"\b(?:bc1[a-z0-9]{25,90}|[13][a-km-zA-HJ-NP-Z1-9]{25,34})\b"#),

        // MARK: Postal addresses (deterministic complement to NSDataDetector)
        // Bare street lines ("456 Maple Drive") and city/state/zip lines miss
        // in NSDataDetector without fuller context (and synthetic docs use
        // fake state codes it rejects). Number + capitalized words + a street
        // suffix is unambiguous enough to redact on its own.
        Rule(.postalAddress,
             #"\b\d{1,6}\s+(?:[A-Z][A-Za-z'\-]+\s+){1,4}(?:Street|St\.?|Avenue|Ave\.?|Road|Rd\.?|Drive|Dr\.?|Lane|Ln\.?|Boulevard|Blvd\.?|Court|Ct\.?|Way|Place|Pl\.?|Terrace|Ter\.?|Circle|Cir\.?|Highway|Hwy\.?|Parkway|Pkwy\.?|Loop|Trail|Trl\.?|Run|Row|Cove|Bend|Crossing|Point|Pt\.?|Path|Alley|Square|Sq\.?|Commons)\b"#),
        // "Springfield, ST 62704" — city, 2-letter code, ZIP(+4).
        Rule(.postalAddress,
             #"\b[A-Z][A-Za-z'\-]+(?:\s[A-Z][A-Za-z'\-]+)?,\s*[A-Z]{2}\s+\d{5}(?:-\d{4})?\b"#),

        // MARK: Vehicles
        // 17 chars from the VIN alphabet (no I/O/Q), validated against the
        // ISO 3779 check digit (position 9) with at least one letter — so a
        // random 17-char token or ID number practically never false-positives.
        // Synthetic VINs with a wrong check digit (demo documents) are caught
        // by the `vin` label in `SensitiveLabels` instead.
        Rule(.vin, #"\b[A-HJ-NPR-Z0-9]{17}\b"#, postFilter: { isVINValid($0) }),

        // MARK: Network
        Rule(.ipAddress, #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#, postFilter: { isValidIPv4($0) }),
        Rule(.ipAddress, ipv6Pattern),
        Rule(.macAddress, #"\b(?:[0-9A-Fa-f]{2}[:\-]){5}[0-9A-Fa-f]{2}\b"#),

        // MARK: Contextual
        Rule(.ssn, #"\b\d{3}[\s\-]\d{2}[\s\-]\d{4}\b"#, postFilter: { isValidSSN($0) }),
        // DOB anywhere in a line (breadcrumbs: "Samir Chen · DOB 2001-05-03")
        // — the geometry paths anchor at line start and the labeled-value
        // regex needs a separator; a birth label directly followed by a
        // date-shaped value is unambiguous wherever it sits.
        Rule(.labeledField,
             #"(?i)\b(?:dob|d\.o\.b\.?|born|birthday|date\s+of\s+birth)\s*[:\-]?\s*(\d{4}-\d{2}-\d{2}|\d{1,2}[/\-]\d{1,2}[/\-]\d{2,4}|\d{1,2}\s+[A-Za-z]{3,9}\.?\s+\d{4}|[A-Za-z]{3,9}\.?\s+\d{1,2},?\s+\d{4})"#,
             captureGroup: 1),
        // Ticket / record identifiers: uppercase prefix + 4-digit run,
        // optionally a trailing group (PRIV-2346, INC-2174, CLM-3391-18,
        // POL-7745-CK, OT-2024-0512). Ops consoles show these unlabeled in
        // titles, breadcrumbs and table columns; they carry org context and
        // often key directly into internal systems.
        Rule(.labeledField, #"\b[A-Z]{2,4}-\d{4}(?:-[A-Z0-9]{2,5})?\b"#),
        // Redact only the value (group 2), regardless of its shape. The label
        // may carry an env-var prefix (LOG_UPLOAD_TOKEN=…), a parenthetical
        // qualifier ("credential (API key): …"), and the value may continue
        // across ONE space (OCR splits long tokens: "sk-test- bfe0614…") —
        // the continuation needs 10+ chars so trailing prose never rides along.
        Rule(.secretAssignment,
             #"(?i)(?:\b|_)(?:[a-z0-9]+[_\-])*(password|passwd|pwd|secret|api[_\-]?key|access[_\-]?token|client[_\-]?secret|token|credential)s?(?:\s*\([^)\n]{0,24}\))?\s*[:=]\s*["']?([^\s"']{6,}(?:\s[^\s"']{10,})?)"#,
             captureGroup: 2),
        // Credential in a URL query: signed links and token'd endpoints
        // ("…/share/abc?sig=cad9dfd4bf"). Redacts the parameter VALUE.
        Rule(.credentialedURL,
             #"(?i)[?&](?:sig|signature|token|access[_\-]?token|api[_\-]?key|apikey|key|x-amz-signature|x-goog-signature)=([A-Za-z0-9%._\-]{8,})"#,
             captureGroup: 1),

        // MARK: Identity documents
        // Passport/ID machine-readable zone (TD1/TD2/TD3): a 28–44 char run of
        // A–Z, 0–9 and `<` filler. The `<<` filler — which ordinary text never
        // contains — gates out false positives on long uppercase tokens. GLiNER2
        // only flags the document-number substring inside the MRZ; this redacts
        // the whole line (it also encodes the name, DOB and expiry).
        Rule(.machineReadableZone, #"[A-Z0-9<]{28,44}"#,
             postFilter: { $0.contains("<<") }),
    ]

    private static let entropyTokenRegex =
        try! NSRegularExpression(pattern: #"[A-Za-z0-9_\-+/=]{20,}"#)
    private static let entropyMinLength = 20
    private static let entropyMinBitsPerChar = 4.5

    /// All sensitive matches in one line from the regex rules alone, ordered by
    /// location with overlaps resolved and the entropy fallback applied.
    static func matches(in text: String) -> [SensitiveMatch] {
        combinedMatches(in: text, additional: [])
    }

    /// Raw regex-rule matches only — no overlap resolution, no entropy pass.
    /// The combiner folds these together with semantic detectors before
    /// resolving overlaps across the union.
    static func rawMatches(in text: String) -> [SensitiveMatch] {
        var found: [SensitiveMatch] = []
        for rule in rules {
            enumerate(rule.regex, in: text, group: rule.captureGroup) { matched, range in
                if let filter = rule.postFilter, !filter(matched) { return }
                found.append(SensitiveMatch(category: rule.category, text: matched, range: range))
            }
        }
        return found
    }

    /// Combine the regex rules with `additional` (e.g. NER / address / labeled
    /// fields), resolve overlaps across the union, then apply the entropy pass.
    static func combinedMatches(in text: String,
                                additional: [SensitiveMatch]) -> [SensitiveMatch] {
        // Resolve overlaps so the panel never shows two rows over one region: a
        // broad `credentialedURL` should win over the `email`/password inside it,
        // and a `labeledField` value over the `personName` inside it. Longest
        // wins; ties broken by higher pattern confidence.
        var found = resolveOverlaps(rawMatches(in: text) + additional)

        // Entropy pass: opaque high-entropy tokens not already covered by a
        // named pattern (a Stripe key is also high-entropy; report it once).
        enumerate(entropyTokenRegex, in: text) { token, range in
            guard token.count >= entropyMinLength,
                  shannonEntropy(of: token) >= entropyMinBitsPerChar,
                  !looksLikeProse(token),
                  !found.contains(where: { $0.range.overlaps(range) }) else { return }
            found.append(SensitiveMatch(category: .highEntropy, text: token, range: range))
        }

        return found.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// Greedily keep the longest / highest-confidence match per region,
    /// dropping any later match whose range overlaps a kept one.
    private static func resolveOverlaps(_ matches: [SensitiveMatch]) -> [SensitiveMatch] {
        let ranked = matches.sorted {
            if $0.range.count != $1.range.count { return $0.range.count > $1.range.count }
            return $0.category.baseConfidence > $1.category.baseConfidence
        }
        var kept: [SensitiveMatch] = []
        for m in ranked where !kept.contains(where: { $0.range.overlaps(m.range) }) {
            kept.append(m)
        }
        return kept
    }

    private static let privateKeyBegin = try! NSRegularExpression(
        pattern: #"(?i)-*\s*BEGIN\s+(?:RSA|EC|OPENSSH|DSA|PGP|ENCRYPTED)?\s*PRIVATE\s+KEY"#)
    private static let privateKeyEnd = try! NSRegularExpression(
        pattern: #"(?i)-*\s*END\s+(?:RSA|EC|OPENSSH|DSA|PGP|ENCRYPTED)?\s*PRIVATE\s+KEY"#)

    /// Whether a recognized line carries a PEM opening/closing marker. Used by
    /// the analyzer to bracket the key material between them — the markers
    /// alone are not the secret.
    static func isPrivateKeyBeginMarker(_ text: String) -> Bool {
        firstMatch(privateKeyBegin, in: text)
    }
    static func isPrivateKeyEndMarker(_ text: String) -> Bool {
        firstMatch(privateKeyEnd, in: text)
    }

    private static func firstMatch(_ regex: NSRegularExpression, in text: String) -> Bool {
        regex.firstMatch(in: text, options: [],
                         range: NSRange(text.startIndex..<text.endIndex, in: text)) != nil
    }

    /// Review-panel snippet: long matches (secrets) keep only their head and
    /// tail so the panel itself never displays a full credential.
    static func displaySnippet(for text: String) -> String {
        guard text.count > 16 else { return text }
        return text.prefix(8) + "…" + text.suffix(4)
    }

    /// Money-shaped tokens on a financial document: a number carrying a money
    /// signal ($, parentheses, a thousands-comma group, or a decimal). Bare
    /// integers (years/counts) and hyphen-separated runs (phones) do NOT qualify.
    /// Returns character-offset ranges (the DetectionGeometry/spanRects convention).
    static func moneyTokenMatches(in line: String) -> [(text: String, range: Range<Int>)] {
        guard let re = try? NSRegularExpression(
            pattern: #"(?<![\d.,$(])\(?(?:\$ ?)?\d{1,3}(?:,\d{3})*(?:\.\d+)?\)?(?![\d])"#) else { return [] }
        var out: [(text: String, range: Range<Int>)] = []
        enumerate(re, in: line) { text, range in
            // Money signal: $, parens, a thousands-comma, or a decimal point.
            if text.contains("$") || text.contains("(") || text.contains(")")
                || text.contains(",") || text.contains(".") {
                out.append((text, range))
            }
        }
        return out
    }

    /// The passport number from a TD3 machine-readable-zone SECOND line. Line 2
    /// begins with the 9-char passport-number field (`<`-padded), e.g.
    /// `ZE000509<9CAN8501019F2301147<<<<<<<<<<<<<<00` → `ZE000509`. Line 1 (`P<…`)
    /// and ordinary text return nil. Deterministic — independent of GLiNER2/FM.
    static func passportNumberFromMRZLine(_ line: String) -> String? {
        let chars = Array(line)
        guard chars.count >= 28, chars.count <= 44, line.contains("<") else { return nil }
        guard chars.allSatisfy({ ($0.isLetter && $0.isUppercase) || $0.isNumber || $0 == "<" }) else { return nil }
        // Line 2 starts with the passport-number field; line 1 ("P<…") has '<' as
        // its 2nd char — exclude it.
        guard chars[1] != "<" else { return nil }
        let number = String(chars[0..<9]).replacingOccurrences(of: "<", with: "")
        guard number.count >= 5, number.contains(where: { $0.isNumber }) else { return nil }
        return number
    }

    // MARK: - Helpers

    /// Run `regex` over `text`, reporting capture `group`'s substring and its
    /// range in *character* offsets (NSRange is UTF-16-based). `group` 0 is the
    /// whole match; a positive index reports that capture group instead.
    static func enumerate(_ regex: NSRegularExpression, in text: String,
                          group: Int = 0,
                          _ body: (String, Range<Int>) -> Void) {
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        regex.enumerateMatches(in: text, options: [], range: nsRange) { result, _, _ in
            guard let result, group < result.numberOfRanges else { return }
            let ns = result.range(at: group)
            guard ns.location != NSNotFound, let swiftRange = Range(ns, in: text) else { return }
            let lower = text.distance(from: text.startIndex, to: swiftRange.lowerBound)
            let length = text.distance(from: swiftRange.lowerBound, to: swiftRange.upperBound)
            body(String(text[swiftRange]), lower..<(lower + length))
        }
    }

    private static func isLuhnValid(_ raw: String) -> Bool {
        let digits = raw.compactMap(\.wholeNumberValue)
        guard digits.count >= 13, digits.count <= 19 else { return false }
        var sum = 0
        for (index, digit) in digits.reversed().enumerated() {
            if index % 2 == 1 {
                let doubled = digit * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += digit
            }
        }
        return sum % 10 == 0
    }

    /// IBAN check: strip spaces, move the first 4 chars to the end, map letters
    /// A–Z to 10–35, and verify the big number ≡ 1 (mod 97). Computed digit by
    /// digit so it never overflows.
    private static func isIBANValid(_ raw: String) -> Bool {
        let s = raw.uppercased().filter { $0.isLetter || $0.isNumber }
        guard s.count >= 15, s.count <= 34 else { return false }
        let rearranged = Array(s.dropFirst(4)) + Array(s.prefix(4))
        var remainder = 0
        for ch in rearranged {
            let value: Int
            if let d = ch.wholeNumberValue, ch.isNumber {
                value = d
            } else if ch.isLetter, let a = ch.asciiValue {
                value = Int(a) - 55   // 'A'(65) → 10 … 'Z'(90) → 35
            } else {
                return false
            }
            remainder = value >= 10 ? (remainder * 100 + value) % 97
                                    : (remainder * 10 + value) % 97
        }
        return remainder == 1
    }

    /// ABA routing-number check (9 digits): 3·(d1+d4+d7) + 7·(d2+d5+d8) +
    /// (d3+d6+d9) ≡ 0 (mod 10), excluding all-zero.
    private static func isABARoutingValid(_ raw: String) -> Bool {
        let d = raw.compactMap(\.wholeNumberValue)
        guard d.count == 9 else { return false }
        let sum = 3 * (d[0] + d[3] + d[6]) + 7 * (d[1] + d[4] + d[7]) + (d[2] + d[5] + d[8])
        return sum != 0 && sum % 10 == 0
    }

    /// ISO 3779 VIN check: 17 chars, at least one letter (a bare 17-digit run
    /// is an ID number, not a VIN), and the position-9 check digit matches the
    /// weighted transliteration sum mod 11 (10 → 'X').
    private static func isVINValid(_ raw: String) -> Bool {
        let chars = Array(raw.uppercased())
        guard chars.count == 17, chars.contains(where: \.isLetter) else { return false }
        let values: [Character: Int] = [
            "A": 1, "B": 2, "C": 3, "D": 4, "E": 5, "F": 6, "G": 7, "H": 8,
            "J": 1, "K": 2, "L": 3, "M": 4, "N": 5, "P": 7, "R": 9,
            "S": 2, "T": 3, "U": 4, "V": 5, "W": 6, "X": 7, "Y": 8, "Z": 9,
            "0": 0, "1": 1, "2": 2, "3": 3, "4": 4,
            "5": 5, "6": 6, "7": 7, "8": 8, "9": 9,
        ]
        let weights = [8, 7, 6, 5, 4, 3, 2, 10, 0, 9, 8, 7, 6, 5, 4, 3, 2]
        var sum = 0
        for (i, c) in chars.enumerated() {
            guard let v = values[c] else { return false }   // I/O/Q or junk
            sum += v * weights[i]
        }
        let expected = sum % 11
        let checkChar = chars[8]
        return expected == 10 ? checkChar == "X" : checkChar == Character("\(expected)")
    }

    /// US SSN sanity: area ≠ 000/666/900–999, group ≠ 00, serial ≠ 0000.
    /// The regex already requires hyphen/space separators, which keeps bare
    /// 9-digit numbers (order ids, etc.) from matching.
    private static func isValidSSN(_ raw: String) -> Bool {
        let d = raw.compactMap(\.wholeNumberValue)
        guard d.count == 9 else { return false }
        let area = d[0] * 100 + d[1] * 10 + d[2]
        let group = d[3] * 10 + d[4]
        let serial = d[5] * 1000 + d[6] * 100 + d[7] * 10 + d[8]
        if area == 0 || area == 666 || area >= 900 { return false }
        return group != 0 && serial != 0
    }

    /// IPv4 dotted-quad: exactly four octets, each 0–255.
    private static func isValidIPv4(_ raw: String) -> Bool {
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard part.count >= 1, part.count <= 3, part.allSatisfy(\.isNumber),
                  let n = Int(part), n <= 255 else { return false }
            return true
        }
    }

    private static func shannonEntropy(of s: String) -> Double {
        guard !s.isEmpty else { return 0 }
        var counts: [Character: Int] = [:]
        for ch in s { counts[ch, default: 0] += 1 }
        let n = Double(s.count)
        var bits = 0.0
        for count in counts.values {
            let p = Double(count) / n
            bits -= p * log2(p)
        }
        return bits
    }

    /// Vowel-heavy all-letter tokens are natural language, not secrets
    /// ("internationalization" clears the length bar but is prose).
    private static func looksLikeProse(_ s: String) -> Bool {
        let lowered = s.lowercased()
        let vowelCount = lowered.filter { "aeiou".contains($0) }.count
        let ratio = Double(vowelCount) / Double(max(lowered.count, 1))
        let hasDigit = lowered.contains(where: \.isNumber)
        let hasSymbol = lowered.contains(where: { "_-+/=".contains($0) })
        return ratio > 0.30 && !hasDigit && !hasSymbol
    }
}
