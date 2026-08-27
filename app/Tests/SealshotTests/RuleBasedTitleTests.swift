import XCTest
@testable import Sealshot

final class RuleBasedTitleTests: XCTestCase {

    private let gen = RuleBasedMetadataGenerator()
    private let date = Date(timeIntervalSince1970: 1_700_000_000)

    private func signals(ocr: String = "", app: String? = nil, title: String? = nil) -> MetadataSignals {
        MetadataSignals(ocrText: ocr, sourceApp: app, windowTitle: title,
                        captureDate: date, imageWidth: 800, imageHeight: 600)
    }

    func testWindowTitle_winsAndStripsAppNoise() {
        let m = gen.generate(signals(app: "Google Chrome",
                                     title: "Stripe Dashboard - Payments - Google Chrome"))
        XCTAssertEqual(m.generatedTitle, "Stripe Dashboard \u{2013} Payments")
    }

    func testSalientOcrLine_usedWhenNoWindowTitle() {
        let ocr = "12:34\nPayment failed\nYour card was declined"
        let m = gen.generate(signals(ocr: ocr))
        XCTAssertEqual(m.generatedTitle, "Payment Failed")
    }

    func testFallback_neverUntitled() {
        let m = gen.generate(signals(app: "Figma"))
        XCTAssertFalse(m.generatedTitle.isEmpty)
        XCTAssertNotEqual(m.generatedTitle.lowercased(), "untitled")
    }

    func testFallback_noSignals_returnsScreenshot() {
        XCTAssertEqual(gen.generate(signals()).generatedTitle, "Screenshot")
    }
}
