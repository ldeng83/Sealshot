import XCTest
@testable import Sealshot

@MainActor
final class ImageOverlayStateTests: XCTestCase {

    private func makeImage(width: Int = 40, height: Int = 30) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height,
                            bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    private func makeState() -> EditorState {
        EditorState(sourceImage: makeImage(width: 800, height: 600), sourceURL: nil)
    }

    func testInsertImageAnnotation_appendsSelectedImageAnnotation_withAsset() throws {
        let state = makeState()
        let h = TimelineTestHarness(state)
        state.insertImageAnnotation(makeImage(), at: nil)

        XCTAssertEqual(state.annotations.count, 1)
        guard case let .image(rect, assetID) = state.annotations[0].geometry else {
            return XCTFail("expected image geometry")
        }
        XCTAssertEqual(rect.size, CGSize(width: 40, height: 30)) // natural, under cap
        XCTAssertNotNil(state.imageAssets[assetID])
        XCTAssertNotNil(state.assetImage(assetID))               // decodable
        XCTAssertEqual(state.selectedAnnotationID, state.annotations[0].id)
        XCTAssertTrue(h.canUndo)                              // one checkpoint
    }

    func testInsertImageAnnotation_downscalesOversizedAsset() throws {
        let state = makeState()   // 800x600 canvas
        state.insertImageAnnotation(makeImage(width: 1600, height: 1200), at: nil)
        guard case let .image(_, assetID) = state.annotations[0].geometry else {
            return XCTFail("expected image geometry")
        }
        let stored = try XCTUnwrap(state.assetImage(assetID))
        XCTAssertEqual(stored.width, 800)
        XCTAssertEqual(stored.height, 600)
    }

    func testReplaceImageAsset_swapsAssetAndRefits_oneUndo() throws {
        let state = makeState()
        let h = TimelineTestHarness(state)
        state.insertImageAnnotation(makeImage(), at: nil)
        let id = state.annotations[0].id
        guard case let .image(_, oldAsset) = state.annotations[0].geometry else {
            return XCTFail()
        }
        state.replaceImageAsset(annotationID: id, with: makeImage(width: 30, height: 60))
        guard case let .image(rect, newAsset) = state.annotations[0].geometry else {
            return XCTFail()
        }
        XCTAssertNotEqual(oldAsset, newAsset)
        XCTAssertEqual(rect.width / rect.height, 0.5, accuracy: 0.01)
        h.undo()
        guard case let .image(_, backAsset) = state.annotations[0].geometry else {
            return XCTFail()
        }
        XCTAssertEqual(backAsset, oldAsset)
        XCTAssertNotNil(state.imageAssets[oldAsset], "old asset bytes must survive undo")
    }
}
