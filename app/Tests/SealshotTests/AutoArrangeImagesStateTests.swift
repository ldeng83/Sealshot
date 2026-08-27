import XCTest
import AppKit
@testable import Sealshot

@MainActor
final class AutoArrangeImagesStateTests: XCTestCase {

    private func image(_ w: Int, _ h: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }
    private func imageAnn(_ rect: CGRect, _ id: String) -> Annotation {
        Annotation(geometry: .image(rect: rect, assetID: id),
                   style: Style(strokeColor: SerializableColor(NSColor.black), strokeWidth: 0))
    }

    func testArrange_deoverlapsImagesKeepsSizesAndNonImage() {
        let state = EditorState(sourceImage: image(1000, 1000), sourceURL: nil)
        // Three overlapping image objects + one non-image annotation.
        let a = imageAnn(CGRect(x: 0, y: 0, width: 300, height: 200), "a")
        let b = imageAnn(CGRect(x: 10, y: 10, width: 150, height: 250), "b")
        let c = imageAnn(CGRect(x: 20, y: 20, width: 220, height: 160), "c")
        let rectAnn = Annotation(geometry: .rectangle(rect: CGRect(x: 5, y: 5, width: 40, height: 40)),
                                 style: Style(strokeColor: SerializableColor(NSColor.red), strokeWidth: 2))
        state.annotations = [a, b, c, rectAnn]

        state.autoArrangeImages(order: .largestFirst, gap: 10)

        // Same count, non-image unchanged.
        XCTAssertEqual(state.annotations.count, 4)
        XCTAssertEqual(state.annotations[3], rectAnn, "non-image annotation untouched")

        // Collect the image rects; sizes preserved (no scaling), no overlap.
        var imageRects: [CGRect] = []
        var ids: [String] = []
        for ann in state.annotations {
            if case let .image(rect, id) = ann.geometry { imageRects.append(rect); ids.append(id) }
        }
        XCTAssertEqual(Set(ids), ["a", "b", "c"], "assetIDs preserved")
        // sizes preserved
        XCTAssertEqual(imageRects.map(\.size).sorted { $0.width < $1.width },
                       [CGSize(width: 150, height: 250), CGSize(width: 220, height: 160),
                        CGSize(width: 300, height: 200)].sorted { $0.width < $1.width })
        // no overlap
        for i in 0..<imageRects.count {
            for j in (i + 1)..<imageRects.count {
                XCTAssertFalse(imageRects[i].insetBy(dx: 0.5, dy: 0.5)
                    .intersects(imageRects[j].insetBy(dx: 0.5, dy: 0.5)),
                    "images \(i),\(j) overlap")
            }
        }
    }

    func testArrange_noOpBelowTwoImages() {
        let state = EditorState(sourceImage: image(500, 500), sourceURL: nil)
        let only = imageAnn(CGRect(x: 3, y: 4, width: 100, height: 80), "solo")
        state.annotations = [only]
        state.autoArrangeImages(order: .auto)
        XCTAssertEqual(state.annotations, [only], "no-op with <2 image objects")
    }
}
