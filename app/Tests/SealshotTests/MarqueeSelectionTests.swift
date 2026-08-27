import XCTest
import CoreGraphics
@testable import Sealshot

final class MarqueeSelectionTests: XCTestCase {

    private func url(_ n: Int) -> URL { URL(fileURLWithPath: "/save/\(n).seal") }

    // MARK: rect normalization

    func test_rect_downRight() {
        let r = MarqueeSelection.rect(from: CGPoint(x: 1, y: 2), to: CGPoint(x: 11, y: 22))
        XCTAssertEqual(r, CGRect(x: 1, y: 2, width: 10, height: 20))
    }

    func test_rect_upLeft_normalizesOrigin() {
        let r = MarqueeSelection.rect(from: CGPoint(x: 11, y: 22), to: CGPoint(x: 1, y: 2))
        XCTAssertEqual(r, CGRect(x: 1, y: 2, width: 10, height: 20))
    }

    func test_rect_mixedDirection() {
        let r = MarqueeSelection.rect(from: CGPoint(x: 11, y: 2), to: CGPoint(x: 1, y: 22))
        XCTAssertEqual(r, CGRect(x: 1, y: 2, width: 10, height: 20))
    }

    // MARK: drag threshold

    func test_threshold_smallMoveIsClick() {
        XCTAssertFalse(MarqueeSelection.exceedsDragThreshold(.zero, CGPoint(x: 2, y: 2)))
    }

    func test_threshold_largeMoveStartsMarquee() {
        XCTAssertTrue(MarqueeSelection.exceedsDragThreshold(.zero, CGPoint(x: 10, y: 0)))
    }

    // MARK: touched

    private let frames: [URL: CGRect] = [
        URL(fileURLWithPath: "/save/0.seal"): CGRect(x: 0, y: 0, width: 50, height: 50),
        URL(fileURLWithPath: "/save/1.seal"): CGRect(x: 100, y: 0, width: 50, height: 50),
        URL(fileURLWithPath: "/save/2.seal"): CGRect(x: 200, y: 0, width: 50, height: 50),
    ]

    func test_touched_overlappingFramesAreSelected() {
        let band = CGRect(x: 25, y: 10, width: 100, height: 20) // overlaps 0 and 1
        XCTAssertEqual(MarqueeSelection.touched(rect: band, frames: frames), [url(0), url(1)])
    }

    func test_touched_disjointBandSelectsNothing() {
        let band = CGRect(x: 60, y: 0, width: 30, height: 10) // in the gap between 0 and 1
        XCTAssertTrue(MarqueeSelection.touched(rect: band, frames: frames).isEmpty)
    }

    func test_touched_bandCoveringAllSelectsAll() {
        let band = CGRect(x: 0, y: 0, width: 250, height: 50)
        XCTAssertEqual(MarqueeSelection.touched(rect: band, frames: frames), [url(0), url(1), url(2)])
    }

    // MARK: combine

    func test_combine_plainReplacesViaEmptyBase() {
        let result = MarqueeSelection.combine(touched: [url(1)], base: [])
        XCTAssertEqual(result, [url(1)])
    }

    func test_combine_additiveUnionsWithBase() {
        let result = MarqueeSelection.combine(touched: [url(1), url(2)], base: [url(0)])
        XCTAssertEqual(result, [url(0), url(1), url(2)])
    }
}
