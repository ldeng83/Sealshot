import XCTest
import CoreGraphics
@testable import Sealshot

@MainActor
final class ExtractionProgressTests: XCTestCase {

    private func img() -> CGImage {
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    func test_emitsReadingStageFirst() async {
        var labels: [String] = []
        _ = await StructuredExtractionCoordinator.extract(image: img()) { _, l in labels.append(l) }
        XCTAssertEqual(labels.first, ExtractionStage.reading.label, "got \(labels)")
    }

    func test_emitsStagesInOrder() async {
        var labels: [String] = []
        _ = await StructuredExtractionCoordinator.extract(image: img()) { _, l in labels.append(l) }
        // Reading first, then the later tiers.
        XCTAssertEqual(labels.first, ExtractionStage.reading.label, "got \(labels)")
        XCTAssertTrue(labels.contains(ExtractionStage.tables.label), "got \(labels)")
    }
}
