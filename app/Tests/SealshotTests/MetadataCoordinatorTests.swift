import XCTest
import CoreGraphics
@testable import Sealshot

@MainActor
final class MetadataCoordinatorTests: XCTestCase {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("seal-\(UUID().uuidString).seal")
    }
    private func img() -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    func testGenerate_patchesManifestAndPostsNotification() async throws {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        try writeSealPackage(to: url, source: img(), composite: img(), annotations: [], crop: nil,
                             crypto: SealPackageCryptoContext(publicKey: nil, identity: nil))

        // Inject OCR that returns known lines, bypassing Vision; pin the
        // rule-based generator so the assertions are deterministic (the model
        // isn't available on the build machine anyway).
        let coordinator = MetadataCoordinator(ocr: { _ in [
            OCRLine(text: "Payment failed", box: CGRect(x: 0, y: 0.1, width: 0.5, height: 0.04)),
            OCRLine(text: "Card declined", box: CGRect(x: 0, y: 0.2, width: 0.5, height: 0.04)),
        ] }, metadataGenerator: { RuleBasedMetadataGenerator() })

        let exp = expectation(forNotification: .captureMetadataDidChange, object: nil)

        await coordinator.generate(for: url, sourceApp: "Safari", windowTitle: nil,
                                   captureDate: Date(timeIntervalSince1970: 1_700_000_000))

        await fulfillment(of: [exp], timeout: 2)
        let read = try readSealPackage(at: url, crypto: SealPackageCryptoContext(publicKey: nil, identity: nil))
        XCTAssertEqual(read.manifest.metadata?.generatedTitle, "Payment Failed")
        XCTAssertEqual(read.manifest.metadata?.category, .error)
        XCTAssertEqual(read.manifest.sourceApp, "Safari")
    }

    func testApplyingVisualTagsMergesAndStampsVersion() {
        let meta = CaptureMetadata(generatedTitle: "T", userTitle: nil, tags: [],
                                   smartKeywords: ["error"],
                                   category: .error, confidence: 0.8, generatorVersion: 2)
        let visual = VisualTags(structural: ["qr-code"], scene: ["photo"])
        let out = MetadataCoordinator.applyingVisualTags(to: meta, visual: visual)
        XCTAssertEqual(out.smartKeywords, ["qr-code", "error", "photo"])  // structural > generated > scene
        XCTAssertTrue(out.tags.isEmpty)                          // user tags untouched
        XCTAssertEqual(out.visualTagVersion, VisionTagger.version)
        XCTAssertEqual(out.category, .error)                     // other fields untouched
    }

    /// Auto-tagging disabled: no generated tags/title/category, but the OCR
    /// text and source app are still recorded so search and the Info pane's
    /// metadata keep working.
    func testGenerate_autoTaggingDisabled_writesOCRAndSourceAppButNoMetadata() async throws {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        try writeSealPackage(to: url, source: img(), composite: img(), annotations: [], crop: nil,
                             crypto: SealPackageCryptoContext(publicKey: nil, identity: nil))

        let coordinator = MetadataCoordinator(
            ocr: { _ in [OCRLine(text: "Hello world", box: CGRect(x: 0, y: 0.1, width: 0.5, height: 0.04))] },
            metadataGenerator: { nil })

        await coordinator.generate(for: url, sourceApp: "Safari", windowTitle: nil,
                                   captureDate: Date(timeIntervalSince1970: 1_700_000_000))

        let read = try readSealPackage(at: url, crypto: SealPackageCryptoContext(publicKey: nil, identity: nil))
        XCTAssertNil(read.manifest.metadata, "auto-tagging off must write no tags/title/category")
        XCTAssertEqual(read.manifest.sourceApp, "Safari", "source app is still recorded")
        XCTAssertEqual(read.manifest.ocrText, "Hello world", "OCR text still extracted for search")
    }
}
