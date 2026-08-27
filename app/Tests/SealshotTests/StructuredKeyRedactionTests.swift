import XCTest
@testable import Sealshot

/// Sensitive values in STRUCTURED documents — JSON, YAML, plists, `.env`
/// dumps — where the key is quoted and/or `snake_case`.
///
/// Reported from the field: a screenshot of a JSON config had most of its
/// secrets left unboxed. The cause was structural rather than a missing
/// pattern — every label rule expects `label:`, and the closing quote in
/// `"label":` sits between the label and the separator, so on a JSON
/// screenshot the ENTIRE label vocabulary was switched off. What still got
/// boxed there was caught incidentally by token shape (`xoxb-…`) or by the
/// entropy fallback (base64), which is why coverage looked arbitrary rather
/// than absent.
final class StructuredKeyRedactionTests: XCTestCase {

    private func detected(_ line: String) -> [SensitiveMatch] {
        SensitiveTextRules.combinedMatches(
            in: line, additional: ContextualDetectors.matches(in: line))
    }

    private func assertRedacts(_ line: String, value: String,
                               file: StaticString = #filePath, line lineNo: UInt = #line) {
        let hits = detected(line)
        XCTAssertTrue(hits.contains { $0.text == value },
                      "\(line) — expected to redact \(value), got "
                      + "\(hits.map { "\($0.category):\($0.text)" })",
                      file: file, line: lineNo)
    }

    private func assertIgnores(_ line: String,
                               file: StaticString = #filePath, line lineNo: UInt = #line) {
        let hits = detected(line)
        XCTAssertTrue(hits.isEmpty,
                      "\(line) — expected no detection, got "
                      + "\(hits.map { "\($0.category):\($0.text)" })",
                      file: file, line: lineNo)
    }

    /// The exact lines from the reported screenshot that went unboxed.
    func testJSONSecrets_areRedacted() {
        assertRedacts(#""pin": "482913","#, value: "482913")
        assertRedacts(#""cvv": "123","#, value: "123")
        assertRedacts(#""security_answer": "Bluewood","#, value: "Bluewood")
        assertRedacts(#""vpn_password": "FakeVPN!Password2026""#, value: "FakeVPN!Password2026")
        assertRedacts(#""client_secret": "client_secret_fake_4b825dc642cb","#,
                      value: "client_secret_fake_4b825dc642cb")
        assertRedacts(#""webhook_secret": "whsec_FAKE2aBc4DeF6GhI8JkL0Mn""#,
                      value: "whsec_FAKE2aBc4DeF6GhI8JkL0Mn")
        assertRedacts(#""recovery_code": "ABCD-EFGH-IJKL-MNOP""#, value: "ABCD-EFGH-IJKL-MNOP")
        assertRedacts(#""swift_bic": "BOFAUS3NXXX""#, value: "BOFAUS3NXXX")
        assertRedacts(#""tax_id": "12-3456789","#, value: "12-3456789")
        assertRedacts(#""employee_id": "EMP-009184","#, value: "EMP-009184")
        assertRedacts(#""postal_code": "02110","#, value: "02110")
        assertRedacts(#""username": "jordan.example","#, value: "jordan.example")
    }

    /// The value is captured EXACTLY — no surrounding quotes, no trailing
    /// comma. A sloppy capture also out-ranks the precise rules in overlap
    /// resolution, which is how a redaction stops being labelled "OpenAI key".
    func testQuotedValue_isCapturedWithoutItsSyntax() {
        let hits = detected(#""password": "FakeP@ssw0rd-OnlyForTesting!","#)
        XCTAssertEqual(hits.first?.text, "FakeP@ssw0rd-OnlyForTesting!")
    }

    /// A named pattern still wins over the generic labeled-field match when
    /// both cover the same value, so the review panel keeps saying what the
    /// secret IS.
    func testNamedPatternsKeepTheirCategory() {
        let slack = detected(#""slack_token": "xoxb-000000000000-000000000000-FAKEtoken","#)
        XCTAssertEqual(slack.first?.category, .slackToken)
    }

    /// `snake_case` keys must match the same vocabulary as their spaced prose
    /// forms — `\b` cannot see a label that begins after `_`.
    func testSnakeCaseKeys_matchTheProseVocabulary() {
        assertRedacts("passport_number: X12345678", value: "X12345678")
        assertRedacts("medical_record_number: MRN-48392017", value: "MRN-48392017")
        assertRedacts("bank_account_number: 000123456789", value: "000123456789")
    }

    /// Other structured syntaxes reach the same vocabulary.
    func testOtherStructuredSyntaxes() {
        assertRedacts("'api_key' => 'sk_live_abcdef123456'", value: "sk_live_abcdef123456")
        assertRedacts("DB_PASSWORD=hunter2trombone", value: "hunter2trombone")
    }

    // MARK: False-positive guards
    //
    // The reach of the label rules widened considerably, so these pin the
    // boundary: a label needs a separator AND a value beside it.

    func testBareLabelsInProse_areNotRedacted() {
        assertIgnores("The username column is sortable")
        assertIgnores("Enter your PIN at the terminal")
        assertIgnores("Postal code lookup failed")
        assertIgnores("Reset password")
    }

    /// A column HEADER has no value beside it on the same line — boxing it
    /// would black out a UI label rather than data.
    func testColumnHeaders_areNotRedacted() {
        assertIgnores("Username")
        assertIgnores("Employee ID")
        assertIgnores("Tax ID")
    }

    // MARK: IPv6 (OCR mangles long colon runs)

    /// The exact string Vision produced from the reported screenshot: spaces
    /// inserted after colons, splitting the `::` into `: :`.
    func testIPv6_survivesOCRSpacesInTheColonRun() {
        assertRedacts(#""ipv6": "2001:db8: 85a3: :8a2e:370:7334""#,
                      value: "2001:db8: 85a3: :8a2e:370:7334")
    }

    func testIPv6_cleanFormStillMatches() {
        let hits = detected("Peer address fe80::1 is unreachable")
        XCTAssertTrue(hits.contains { $0.category == .ipAddress && $0.text == "fe80::1" },
                      "the WHOLE address, not fe80:: with the last hextet left visible")
    }

    /// Tolerating spaces must not turn a clock into an IP address. What keeps
    /// this safe is the `::` requirement, which a timestamp never has.
    func testTimestamps_areNotIPv6() {
        assertIgnores("Duration 10:30:45 elapsed")
        assertIgnores("Meeting at 14: 30: 00 today")
    }
}
