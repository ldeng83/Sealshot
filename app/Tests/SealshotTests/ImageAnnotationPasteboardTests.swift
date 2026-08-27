import XCTest
@testable import Sealshot

final class ImageAnnotationPasteboardTests: XCTestCase {

    func testPayload_roundTripsAnnotationsAndAssets() throws {
        let a = Annotation(
            geometry: .image(rect: CGRect(x: 0, y: 0, width: 10, height: 10),
                             assetID: "X"),
            style: Style(strokeColor: SerializableColor(NSColor.black), strokeWidth: 0))
        let payload = AnnotationClipboardPayload(
            annotations: [a], assets: ["X": Data([1, 2, 3])])
        let pb = NSPasteboard(name: NSPasteboard.Name("test-\(UUID().uuidString)"))
        AnnotationPasteboard.write(payload, to: pb)
        let back = try XCTUnwrap(AnnotationPasteboard.read(from: pb))
        XCTAssertEqual(back.annotations, [a])
        XCTAssertEqual(back.assets["X"], Data([1, 2, 3]))
    }

    func testRead_legacyBareAnnotationArray_stillDecodes() throws {
        let a = Annotation(geometry: .rectangle(rect: CGRect(x: 0, y: 0, width: 5, height: 5)),
                           style: Style(strokeColor: SerializableColor(NSColor.black), strokeWidth: 2))
        let pb = NSPasteboard(name: NSPasteboard.Name("test-\(UUID().uuidString)"))
        pb.clearContents()
        pb.setData(try JSONEncoder().encode([a]), forType: AnnotationPasteboard.type)
        let back = try XCTUnwrap(AnnotationPasteboard.read(from: pb))
        XCTAssertEqual(back.annotations, [a])
        XCTAssertTrue(back.assets.isEmpty)
    }
}
