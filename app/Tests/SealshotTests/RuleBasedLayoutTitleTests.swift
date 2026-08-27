import XCTest
import CoreGraphics
@testable import Sealshot

/// Layout-aware OCR title selection: pick by text size (box height), promote a
/// dominant top heading to the displayed (high) tier, otherwise stay medium.
final class RuleBasedLayoutTitleTests: XCTestCase {

    private let gen = RuleBasedMetadataGenerator()
    private let date = Date(timeIntervalSince1970: 1_700_000_000)

    /// box: normalized [0,1], top-left origin. `y` is the top edge.
    private func line(_ text: String, y: CGFloat, h: CGFloat) -> OCRLine {
        OCRLine(text: text, box: CGRect(x: 0.1, y: y, width: 0.5, height: h))
    }

    private func signals(_ lines: [OCRLine]) -> MetadataSignals {
        MetadataSignals(ocrText: lines.map(\.text).joined(separator: "\n"),
                        ocrLines: lines, sourceApp: nil, windowTitle: nil,
                        captureDate: date, imageWidth: 1000, imageHeight: 1000)
    }

    func testDominantTopHeading_promotedAndUsed() {
        let m = gen.generate(signals([
            line("Billing Settings", y: 0.05, h: 0.10),   // tall, top
            line("Payment method", y: 0.30, h: 0.04),
            line("Save changes", y: 0.40, h: 0.04),
        ]))
        XCTAssertEqual(m.generatedTitle, "Billing Settings")
        XCTAssertEqual(m.confidence, 0.78, accuracy: 0.0001)
    }

    func testTallHeadingInLowerHalf_notPromoted() {
        let m = gen.generate(signals([
            line("Small label", y: 0.05, h: 0.04),
            line("Big But Low", y: 0.70, h: 0.10),         // tall but below top 40%
            line("more body text", y: 0.85, h: 0.04),
        ]))
        XCTAssertEqual(m.confidence, 0.55, accuracy: 0.0001)
    }

    func testBarelyTallerThanBody_notPromoted() {
        let m = gen.generate(signals([
            line("Slightly Bigger", y: 0.05, h: 0.048),    // only 1.2x of 0.04
            line("body line one", y: 0.30, h: 0.04),
            line("body line two", y: 0.40, h: 0.04),
        ]))
        XCTAssertEqual(m.confidence, 0.55, accuracy: 0.0001)
    }

    func testPicksTallestTitleLikeLine_notFirst() {
        let m = gen.generate(signals([
            line("first in reading order", y: 0.05, h: 0.04),
            line("The Real Heading", y: 0.20, h: 0.10),     // tallest
            line("footer", y: 0.50, h: 0.04),
        ]))
        XCTAssertEqual(m.generatedTitle, "The Real Heading")
    }

    func testEmptyOcrLines_fallsBackToTextPath() {
        // No layout — same behavior as before (first salient line, 0.55).
        let m = gen.generate(MetadataSignals(
            ocrText: "12:34\nPayment failed\nYour card was declined",
            sourceApp: nil, windowTitle: nil, captureDate: date,
            imageWidth: 800, imageHeight: 600))
        XCTAssertEqual(m.generatedTitle, "Payment Failed")
        XCTAssertEqual(m.confidence, 0.55, accuracy: 0.0001)
    }
}
