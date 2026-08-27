import XCTest
@testable import Sealshot

/// Confidence is graded by which signal won the title, so the display layer
/// can gate low-confidence guesses behind a neutral fallback.
final class RuleBasedConfidenceTests: XCTestCase {

    private let gen = RuleBasedMetadataGenerator()
    private let date = Date(timeIntervalSince1970: 1_700_000_000)

    private func signals(ocr: String = "", app: String? = nil, title: String? = nil) -> MetadataSignals {
        MetadataSignals(ocrText: ocr, sourceApp: app, windowTitle: title,
                        captureDate: date, imageWidth: 800, imageHeight: 600)
    }

    func testWindowTitle_highConfidence() {
        let m = gen.generate(signals(app: "Google Chrome", title: "Stripe Dashboard - Google Chrome"))
        XCTAssertEqual(m.confidence, 0.85, accuracy: 0.0001)
    }

    func testSalientOcrLine_mediumConfidence() {
        let m = gen.generate(signals(ocr: "12:34\nPayment failed\nYour card was declined"))
        XCTAssertEqual(m.confidence, 0.55, accuracy: 0.0001)
    }

    func testAppNameOnly_lowMediumConfidence() {
        let m = gen.generate(signals(app: "Figma"))
        XCTAssertEqual(m.confidence, 0.40, accuracy: 0.0001)
    }

    func testNoSignals_lowConfidence() {
        let m = gen.generate(signals())
        XCTAssertEqual(m.confidence, 0.20, accuracy: 0.0001)
    }
}
