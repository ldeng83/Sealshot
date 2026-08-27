import XCTest
@testable import Sealshot

/// Private keys in screenshots.
///
/// Reported from the field: a JSON screenshot whose `private_key` value sat
/// completely unredacted while its neighbours were boxed. Two independent
/// causes, both visible in the OCR dump for that image:
///
///   1. the rule demanded exactly `-----BEGIN … PRIVATE KEY-----`, and Vision
///      recognized the dash run as two dashes — `--BEGIN PRIVATE KEY-`;
///   2. even with the markers matched, the KEY MATERIAL is a separate OCR
///      fragment, so boxing only the markers would leave the secret on screen.
@MainActor
final class PrivateKeyBlockDetectionTests: XCTestCase {

    private func layout(_ rows: [(String, CGFloat, CGFloat, CGFloat, CGFloat)]) -> RecognizedTextLayout {
        let lines = rows.map { (t, x, y, w, h) -> RecognizedLine in
            let n = max(t.count, 1)
            let boxes = (0..<t.count).map {
                CGRect(x: x + CGFloat($0) / CGFloat(n) * w, y: y, width: w / CGFloat(n), height: h)
            }
            return RecognizedLine(text: t, box: CGRect(x: x, y: y, width: w, height: h), charBoxes: boxes)
        }
        return RecognizedTextLayout(lines: lines)
    }
    private let tile = CGRect(x: 0, y: 0, width: 1000, height: 1000)

    private func matched(_ line: String) -> [SensitiveMatch] {
        SensitiveTextRules.matches(in: line)
    }

    // MARK: Markers

    func testStandardPEMMarkers_stillMatch() {
        XCTAssertTrue(matched("-----BEGIN PRIVATE KEY-----")
            .contains { $0.category == .privateKeyBlock })
        XCTAssertTrue(matched("-----BEGIN RSA PRIVATE KEY-----")
            .contains { $0.category == .privateKeyBlock })
    }

    /// The exact strings Vision produced from the reported screenshot.
    func testDashManglingByOCR_stillMatches() {
        XCTAssertTrue(matched("--BEGIN PRIVATE KEY-")
            .contains { $0.category == .privateKeyBlock },
            "OCR eats dash runs; the phrase has to carry the rule")
        XCTAssertTrue(matched("--END PRIVATE KEY-.")
            .contains { $0.category == .privateKeyBlock },
            "the closing marker is its own OCR line")
    }

    func testOrdinaryProse_isNotAPrivateKey() {
        XCTAssertTrue(matched("Begin by opening the private key settings page").isEmpty)
    }

    // MARK: The material between the markers

    /// The reported case: one source line, five OCR fragments on ONE row.
    /// "Between" therefore has to mean reading order, not line index.
    func testKeyMaterialOnTheSameRow_isRedacted() {
        let l = layout([
            ("\"private_key\": \"", 0.03, 0.90, 0.12, 0.01),
            ("--BEGIN PRIVATE KEY-", 0.18, 0.90, 0.14, 0.01),
            ("-\\nFAKE_TEST_KEY_MATERIAL_DO_NOT_USE_1234567890\\n-", 0.35, 0.90, 0.37, 0.01),
            ("--END PRIVATE KEY-.", 0.74, 0.90, 0.13, 0.01),
        ])
        let found = SmartRedactionAnalyzer.privateKeyBlockDetections(in: l, tile: tile)
        XCTAssertEqual(found.count, 1, "the key material, once")
        XCTAssertEqual(found.first?.customLabel, "private key")
        XCTAssertFalse(found.first?.rects.isEmpty ?? true)
    }

    /// The classic wrapped PEM block: material on its own rows.
    func testWrappedPEMBlock_redactsEveryBodyLine() {
        let l = layout([
            ("-----BEGIN PRIVATE KEY-----", 0.1, 0.10, 0.4, 0.01),
            ("MIIEvQIBADANBgkqhkiG9w0BAQEFAASC", 0.1, 0.12, 0.4, 0.01),
            ("BKcwggSjAgEAAoIBAQDBJ8yZ0uKQrLLm", 0.1, 0.14, 0.4, 0.01),
            ("-----END PRIVATE KEY-----", 0.1, 0.16, 0.4, 0.01),
        ])
        let found = SmartRedactionAnalyzer.privateKeyBlockDetections(in: l, tile: tile)
        XCTAssertEqual(found.count, 2, "both body lines")
    }

    /// No END marker: nothing is bracketed, so unrelated text below a stray
    /// "BEGIN PRIVATE KEY" is never swept up.
    func testUnterminatedBlock_redactsNothingBetween() {
        let l = layout([
            ("-----BEGIN PRIVATE KEY-----", 0.1, 0.10, 0.4, 0.01),
            ("Some ordinary paragraph text here", 0.1, 0.12, 0.4, 0.01),
        ])
        XCTAssertTrue(SmartRedactionAnalyzer.privateKeyBlockDetections(in: l, tile: tile).isEmpty)
    }

    // MARK: Wrapped values (a narrow window soft-wraps long values)

    /// Reported from the field: in a narrow window an access token wrapped and
    /// only its first half was redacted — a JWT whose second half is legible
    /// is not redacted in any useful sense.
    func testWrappedValue_redactsTheContinuationRow() {
        let l = layout([
            ("\"access", 0.06, 0.25, 0.10, 0.008),
            ("token\": \"eyJhbGciOiJIUzI1NiJ9.", 0.16, 0.25, 0.39, 0.008),
            ("eyJzdWIiOiJmYWtlLXVzZXIifQ.fake-signature\",", 0.06, 0.262, 0.82, 0.008),
            ("\"refresh_token\": \"rt_test_7Xq9\",", 0.06, 0.274, 0.40, 0.008),
        ])
        let found = SmartRedactionAnalyzer.wrappedValueDetections(in: l, tile: tile)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.customLabel, "wrapped value")
        XCTAssertGreaterThanOrEqual(found.first?.rects.count ?? 0, 2,
                                    "the opening row's tail AND the continuation")
    }

    /// A row whose value is complete has nothing to continue. Without this a
    /// heading row claimed the field below it, and its detection displaced the
    /// AWS-key match underneath.
    func testCompleteRow_doesNotSwallowTheNextField() {
        let l = layout([
            ("\"cloud_credentials\": {", 0.06, 0.10, 0.20, 0.008),
            ("\"aws_access_key_id\": \"AKIAFAKE1234567890AB\"", 0.06, 0.112, 0.55, 0.008),
        ])
        XCTAssertTrue(SmartRedactionAnalyzer.wrappedValueDetections(in: l, tile: tile).isEmpty)
    }

    /// The row below a field in a UI screenshot is not its continuation —
    /// button text must never be blacked out.
    func testProseBelowAField_isNotTreatedAsAContinuation() {
        let l = layout([
            ("\"date_time\": DOB 1975-12-17 https://bridge.internal/INC-2174", 0.06, 0.10, 0.6, 0.008),
            ("Cancel Unlock", 0.06, 0.112, 0.15, 0.008),
        ])
        XCTAssertTrue(SmartRedactionAnalyzer.wrappedValueDetections(in: l, tile: tile).isEmpty)
    }

    /// A field with no sensitive label is left alone however it wraps.
    func testUnlabelledFieldThatWraps_isNotRedacted() {
        let l = layout([
            ("\"description\": \"a long sentence that carries on", 0.06, 0.10, 0.5, 0.008),
            ("onto the next line 12345\",", 0.06, 0.112, 0.3, 0.008),
        ])
        XCTAssertTrue(SmartRedactionAnalyzer.wrappedValueDetections(in: l, tile: tile).isEmpty)
    }
}
