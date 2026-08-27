import XCTest
import AppKit
@testable import Sealshot

final class AnnotationPasteboardTests: XCTestCase {

    private func rectAnnotation() -> Annotation {
        Annotation(geometry: .rectangle(rect: CGRect(x: 1, y: 2, width: 3, height: 4)),
                   style: Style(strokeColor: SerializableColor(.red), strokeWidth: 3))
    }

    func testRoundTrip_writeThenRead() {
        let pb = NSPasteboard(name: NSPasteboard.Name(rawValue: "AnnotationPasteboardTests.roundtrip"))
        pb.clearContents()
        let original = [rectAnnotation(), rectAnnotation()]
        AnnotationPasteboard.write(AnnotationClipboardPayload(annotations: original), to: pb)
        let back = AnnotationPasteboard.read(from: pb)
        XCTAssertEqual(back?.annotations, original)
        XCTAssertEqual(back?.assets, [:])
    }

    func testRead_absentType_returnsNil() {
        let pb = NSPasteboard(name: NSPasteboard.Name(rawValue: "AnnotationPasteboardTests.empty"))
        pb.clearContents()
        XCTAssertNil(AnnotationPasteboard.read(from: pb))
    }

    func testCopyTarget_nonEmptySelection_objects() {
        XCTAssertEqual(copyTarget(selectionCount: 2), .objects)
    }

    func testCopyTarget_emptySelection_wholeImage() {
        XCTAssertEqual(copyTarget(selectionCount: 0), .wholeImage)
    }
}
