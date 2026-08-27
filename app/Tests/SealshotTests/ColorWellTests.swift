import XCTest
import AppKit
@testable import Sealshot

final class ColorWellTests: XCTestCase {

    func test_opaqueSRGB_forcesAlphaAndPreservesRGB() {
        let translucent = NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 0.3)
        let result = opaqueSRGB(translucent).usingColorSpace(.sRGB)!
        XCTAssertEqual(result.alphaComponent, 1.0, accuracy: 0.0001)
        XCTAssertEqual(result.redComponent, 0.2, accuracy: 0.0001)
        XCTAssertEqual(result.greenComponent, 0.4, accuracy: 0.0001)
        XCTAssertEqual(result.blueComponent, 0.6, accuracy: 0.0001)
    }

    func test_opaqueSRGB_alreadyOpaqueUnchanged() {
        let opaque = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        let result = opaqueSRGB(opaque).usingColorSpace(.sRGB)!
        XCTAssertEqual(result.alphaComponent, 1.0, accuracy: 0.0001)
        XCTAssertEqual(result.redComponent, 1.0, accuracy: 0.0001)
    }

    private func makeImage(width: Int = 10, height: Int = 10) -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 4 * width, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    @MainActor
    func test_styleColorApplier_recordsOneCheckpointPerSession() {
        let state = EditorState(sourceImage: makeImage(), sourceURL: nil)
        let anno = Annotation(geometry: .rectangle(rect: CGRect(x: 0, y: 0, width: 10, height: 10)),
                              style: Style(strokeColor: SerializableColor(.red), strokeWidth: 3))
        state.annotations = [anno]
        state.selectedAnnotationID = anno.id

        let h = TimelineTestHarness(state)
        let applier = StyleColorApplier(state: state, id: anno.id) { style, color in
            if let color = color { style.strokeColor = SerializableColor(color) }
        }
        let baseline = state.historyEpoch

        // One session, three picks → exactly one checkpoint.
        applier.begin()
        applier.pick(.blue)
        applier.pick(.green)
        applier.pick(.yellow)
        XCTAssertEqual(state.historyEpoch, baseline + 1)
        XCTAssertTrue(h.canUndo)

        // A new session → one more checkpoint.
        applier.begin()
        applier.pick(.systemTeal)
        XCTAssertEqual(state.historyEpoch, baseline + 2)
    }

    @MainActor
    func test_styleColorApplier_noPick_noCheckpoint() {
        let state = EditorState(sourceImage: makeImage(), sourceURL: nil)
        let h = TimelineTestHarness(state)
        let applier = StyleColorApplier(state: state, id: UUID()) { _, _ in }
        let baseline = state.historyEpoch
        applier.begin()      // opened popover, no color chosen
        XCTAssertEqual(state.historyEpoch, baseline)
        XCTAssertFalse(h.canUndo)
    }

}
