import XCTest
import CoreGraphics
@testable import Sealshot

/// Pixel-based browser chrome/page split — the permission-free fallback for
/// the page-body hover candidate when the AX probe yields nothing.
final class BrowserChromeSplitTests: XCTestCase {

    /// Synthetic browser-window image: `chrome` points of chrome-gray at the
    /// top, page-gray below, with an optional divider line at the boundary.
    /// Top-left origin (row 0 = window top), like FrozenFrameCrop output.
    private func browserImage(
        w: Int = 1200, h: Int = 800, scale: CGFloat = 1,
        chrome: CGFloat, chromeGray: CGFloat, pageGray: CGFloat,
        dividerGray: CGFloat? = nil,
        extraEdge: (y: CGFloat, gray: CGFloat, widthFraction: CGFloat)? = nil
    ) -> CGImage {
        let pw = Int(CGFloat(w) * scale), ph = Int(CGFloat(h) * scale)
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        func fillTopLeft(_ rect: CGRect, gray: CGFloat) {
            // Context is bottom-left origin; our rects are top-left origin.
            let flipped = CGRect(x: rect.minX * scale,
                                 y: CGFloat(ph) - (rect.maxY * scale),
                                 width: rect.width * scale,
                                 height: rect.height * scale)
            ctx.setFillColor(CGColor(gray: gray, alpha: 1))
            ctx.fill(flipped)
        }
        fillTopLeft(CGRect(x: 0, y: 0, width: CGFloat(w), height: chrome), gray: chromeGray)
        fillTopLeft(CGRect(x: 0, y: chrome, width: CGFloat(w), height: CGFloat(h) - chrome),
                    gray: pageGray)
        if let dividerGray {
            fillTopLeft(CGRect(x: 0, y: chrome, width: CGFloat(w), height: 2), gray: dividerGray)
        }
        if let e = extraEdge {
            fillTopLeft(CGRect(x: 0, y: e.y, width: CGFloat(w) * e.widthFraction,
                               height: CGFloat(h) - e.y), gray: e.gray)
        }
        return ctx.makeImage()!
    }

    func test_clearChromeSplit_detected() {
        let img = browserImage(chrome: 90, chromeGray: 0.95, pageGray: 0.60)
        let split = BrowserChromeSplit.chromeHeight(in: img, pixelsPerPoint: 1)
        XCTAssertNotNil(split)
        XCTAssertEqual(split ?? -1, 90, accuracy: 3)
    }

    func test_uniformImage_noSplit() {
        let img = browserImage(chrome: 90, chromeGray: 0.95, pageGray: 0.95)
        XCTAssertNil(BrowserChromeSplit.chromeHeight(in: img, pixelsPerPoint: 1))
    }

    func test_faintDividerOnMatchingBackgrounds_detected() {
        // Chrome and page are the same tone; only a subtle divider line marks
        // the boundary — the common light-theme case.
        let img = browserImage(chrome: 110, chromeGray: 0.95, pageGray: 0.95,
                               dividerGray: 0.82)
        let split = BrowserChromeSplit.chromeHeight(in: img, pixelsPerPoint: 1)
        XCTAssertEqual(split ?? -1, 110, accuracy: 3)
    }

    func test_edgeBelowBand_ignored() {
        // A full-width edge at 300pt is outside any plausible chrome height.
        let img = browserImage(chrome: 300, chromeGray: 0.95, pageGray: 0.60)
        XCTAssertNil(BrowserChromeSplit.chromeHeight(in: img, pixelsPerPoint: 1))
    }

    func test_edgeAboveBand_ignored() {
        // 15pt is inside the window's own title/tab strip territory — too
        // shallow to be the chrome/page boundary.
        let img = browserImage(chrome: 15, chromeGray: 0.95, pageGray: 0.60)
        XCTAssertNil(BrowserChromeSplit.chromeHeight(in: img, pixelsPerPoint: 1))
    }

    func test_topmostQualifyingEdgeWins() {
        // Chrome boundary at 80pt (moderate contrast) plus a much stronger
        // full-width page edge at 180pt (e.g. a hero section) — the topmost
        // qualifying edge is the chrome one.
        let img = browserImage(chrome: 80, chromeGray: 0.95, pageGray: 0.85,
                               extraEdge: (y: 180, gray: 0.20, widthFraction: 1.0))
        let split = BrowserChromeSplit.chromeHeight(in: img, pixelsPerPoint: 1)
        XCTAssertEqual(split ?? -1, 80, accuracy: 3)
    }

    func test_partialWidthEdge_rejected() {
        // A 55%-width block edge is page content, not a chrome boundary.
        let img = browserImage(chrome: 100, chromeGray: 0.95, pageGray: 0.95,
                               extraEdge: (y: 100, gray: 0.30, widthFraction: 0.55))
        XCTAssertNil(BrowserChromeSplit.chromeHeight(in: img, pixelsPerPoint: 1))
    }

    func test_retinaScale_returnsPoints() {
        let img = browserImage(scale: 2, chrome: 100, chromeGray: 0.95, pageGray: 0.60)
        let split = BrowserChromeSplit.chromeHeight(in: img, pixelsPerPoint: 2)
        XCTAssertEqual(split ?? -1, 100, accuracy: 3)
    }

    func test_tinyContentBelowSplit_rejected() {
        // Split so low that the "page" sliver couldn't be real content.
        let img = browserImage(h: 260, chrome: 230, chromeGray: 0.95, pageGray: 0.60)
        XCTAssertNil(BrowserChromeSplit.chromeHeight(in: img, pixelsPerPoint: 1))
    }
}
