import XCTest
import AppKit
@testable import Sealshot

final class GroupedToolPillViewTests: XCTestCase {

    private let bounds = NSRect(x: 0, y: 0, width: 28, height: 28)

    func testMenuRegion_bottomRightCorner_isHit() {
        // Bottom-right corner (chevron affordance) — note the view is unflipped,
        // so the chevron sits at low y, high x.
        XCTAssertTrue(GroupedToolPillView.isMenuRegion(NSPoint(x: 25, y: 3), in: bounds))
    }

    func testMenuRegion_center_isMiss() {
        XCTAssertFalse(GroupedToolPillView.isMenuRegion(NSPoint(x: 14, y: 14), in: bounds))
    }

    func testMenuRegion_topLeft_isMiss() {
        XCTAssertFalse(GroupedToolPillView.isMenuRegion(NSPoint(x: 3, y: 25), in: bounds))
    }

    func testMenuRegion_bottomLeft_isMiss() {
        XCTAssertFalse(GroupedToolPillView.isMenuRegion(NSPoint(x: 3, y: 3), in: bounds))
    }
}
