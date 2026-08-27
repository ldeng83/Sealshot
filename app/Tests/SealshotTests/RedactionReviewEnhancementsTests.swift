import XCTest
import AppKit
@testable import Sealshot

@MainActor
final class RedactionSelectAllTests: XCTestCase {
    private func makeImage() -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8,
                            bytesPerRow: 400, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }
    private func det(_ c: SensitiveCategory, _ conf: Double) -> Detection {
        Detection(category: c, snippet: "x", confidence: conf,
                  rects: [CGRect(x: 0, y: 0, width: 10, height: 10)])
    }

    func testDeselectAll_unchecksEveryProposal() {
        let state = EditorState(sourceImage: makeImage(), sourceURL: nil)
        state.presentRedactionProposals([det(.email, 0.9), det(.phone, 0.75)])
        state.setAllRedactionProposals(kept: false)
        guard case .found(let p) = state.redactionScan else { return XCTFail() }
        XCTAssertTrue(p.allSatisfy { !$0.isKept })
    }

    func testSelectAll_checksEveryProposal_includingLowConfidence() {
        let state = EditorState(sourceImage: makeImage(), sourceURL: nil)
        state.presentRedactionProposals([det(.email, 0.9), det(.personName, 0.45)])
        // personName starts unchecked (low confidence)
        state.setAllRedactionProposals(kept: true)
        guard case .found(let p) = state.redactionScan else { return XCTFail() }
        XCTAssertTrue(p.allSatisfy(\.isKept))
    }

    func testSetAll_noProposals_isNoOp() {
        let state = EditorState(sourceImage: makeImage(), sourceURL: nil)
        state.setAllRedactionProposals(kept: false)
        XCTAssertEqual(state.redactionScan, .idle)
    }
}
