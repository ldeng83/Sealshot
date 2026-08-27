import XCTest
import CoreGraphics
@testable import Sealshot

final class UnifiedGestureTests: XCTestCase {

    // MARK: isAreaDrag

    func testIsAreaDrag_belowThreshold_isFalse() {
        XCTAssertFalse(UnifiedGesture.isAreaDrag(from: CGPoint(x: 100, y: 100),
                                                 to: CGPoint(x: 103, y: 101)))   // ~3.16pt
    }

    func testIsAreaDrag_atThreshold_isTrue() {
        XCTAssertTrue(UnifiedGesture.isAreaDrag(from: CGPoint(x: 0, y: 0),
                                                to: CGPoint(x: 5, y: 0)))         // exactly 5pt
    }

    func testIsAreaDrag_diagonalBeyondThreshold_isTrue() {
        XCTAssertTrue(UnifiedGesture.isAreaDrag(from: CGPoint(x: 10, y: 10),
                                                to: CGPoint(x: 14, y: 14)))       // ~5.66pt
    }

    // MARK: outcome

    func testOutcome_areaMode_isRegion() {
        XCTAssertEqual(UnifiedGesture.outcome(enteredAreaMode: true, hasHighlightedWindow: true), .region)
        XCTAssertEqual(UnifiedGesture.outcome(enteredAreaMode: true, hasHighlightedWindow: false), .region)
    }

    func testOutcome_clickWithWindow_isWindow() {
        XCTAssertEqual(UnifiedGesture.outcome(enteredAreaMode: false, hasHighlightedWindow: true), .window)
    }

    func testOutcome_clickEmptyDesktop_isNone() {
        XCTAssertEqual(UnifiedGesture.outcome(enteredAreaMode: false, hasHighlightedWindow: false), .none)
    }
}

final class WindowHitTestMathTests: XCTestCase {

    func testAppKitToQuartz_flipsYAboutPrimaryHeight() {
        // AppKit bottom-left origin → Quartz top-left origin on a 900-tall display.
        XCTAssertEqual(appKitToQuartz(CGPoint(x: 100, y: 0), primaryHeight: 900),
                       CGPoint(x: 100, y: 900))
        XCTAssertEqual(appKitToQuartz(CGPoint(x: 100, y: 900), primaryHeight: 900),
                       CGPoint(x: 100, y: 0))
        XCTAssertEqual(appKitToQuartz(CGPoint(x: 250, y: 300), primaryHeight: 900),
                       CGPoint(x: 250, y: 600))
    }
}
