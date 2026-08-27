import XCTest
@testable import Sealshot

final class RuleBasedCategoryTests: XCTestCase {

    private let gen = RuleBasedMetadataGenerator()
    private let date = Date(timeIntervalSince1970: 1_700_000_000)

    private func cat(ocr: String = "", app: String? = nil, title: String? = nil) -> ScreenshotCategory {
        gen.generate(MetadataSignals(ocrText: ocr, sourceApp: app, windowTitle: title,
                                     captureDate: date, imageWidth: 1, imageHeight: 1)).category
    }

    func testError() { XCTAssertEqual(cat(ocr: "403 Forbidden\nrequest failed"), .error) }
    func testCode() { XCTAssertEqual(cat(ocr: "Pull Request #421 merged"), .code) }
    func testDesign() { XCTAssertEqual(cat(app: "Figma"), .design) }
    func testReceipt() { XCTAssertEqual(cat(ocr: "Subtotal $40\nTotal due"), .receipt) }
    func testDefaultsToOther() { XCTAssertEqual(cat(ocr: "hello world"), .other) }
    func testErrorBeatsCode_mostSpecificFirst() {
        XCTAssertEqual(cat(ocr: "github actions build failed: error"), .error)
    }
}
