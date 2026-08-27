import XCTest
import CoreGraphics
@testable import Sealshot

@MainActor
final class ExtractionRecordTests: XCTestCase {

    func test_matches_focusRectAndVersion() {
        let r = ExtractionRecord(items: StructuredItems(), markdown: "x",
                                 focusRect: RectDTO(CGRect(x: 0, y: 0, width: 10, height: 10)),
                                 version: ExtractionRecord.currentVersion)
        XCTAssertTrue(r.matches(focusRect: RectDTO(CGRect(x: 0.1, y: 0, width: 10, height: 10))),
                      "sub-pixel difference should still match")
        XCTAssertFalse(r.matches(focusRect: RectDTO(CGRect(x: 50, y: 0, width: 10, height: 10))))
        XCTAssertFalse(r.matches(focusRect: nil))
    }

    func test_matches_versionMismatch() {
        let r = ExtractionRecord(items: StructuredItems(), markdown: "x", focusRect: nil,
                                 version: ExtractionRecord.currentVersion + 1)
        XCTAssertFalse(r.matches(focusRect: nil))
    }

    func test_matches_wholeImage() {
        let r = ExtractionRecord(items: StructuredItems(), markdown: "x", focusRect: nil,
                                 version: ExtractionRecord.currentVersion)
        XCTAssertTrue(r.matches(focusRect: nil))
    }

    func test_codableRoundTrip() throws {
        var items = StructuredItems(); items.emails = ["a@b.com"]
        let r = ExtractionRecord(items: items, markdown: "# H", focusRect: nil, version: 1)
        XCTAssertEqual(try JSONDecoder().decode(ExtractionRecord.self,
            from: try JSONEncoder().encode(r)), r)
    }

    func test_setExtraction_roundTripPreservesFields() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ext-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("shot.seal")
        let img = makeImg()
        try writeSealPackage(to: url, source: img, composite: img, annotations: [], crop: nil,
                             crypto: SealPackageCryptoContext(publicKey: nil, identity: nil))

        var items = StructuredItems(); items.tables = [StructuredTable(headers: ["A"], rows: [["1"]])]
        let rec = ExtractionRecord(items: items, markdown: "## md",
                                   focusRect: RectDTO(CGRect(x: 1, y: 2, width: 3, height: 4)), version: 1)
        try SealMetadataStore.setExtraction(rec, to: url)

        let read = try SealMetadataStore.readManifest(at: url)
        XCTAssertEqual(read.extraction, rec)
        XCTAssertEqual(read.sourceSize.width, img.width, "other manifest fields preserved")
    }

    private func makeImg() -> CGImage {
        let ctx = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }
}
