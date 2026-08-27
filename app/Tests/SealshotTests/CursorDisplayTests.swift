import XCTest
@testable import Sealshot

final class CursorDisplayTests: XCTestCase {

    func testPointInsidePrimaryDisplay() {
        let primary = DisplayBounds(id: 1, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let secondary = DisplayBounds(id: 2, frame: CGRect(x: 1920, y: 0, width: 1920, height: 1080))
        let result = displayContainingPoint(CGPoint(x: 500, y: 500), in: [primary, secondary])
        XCTAssertEqual(result?.id, 1)
    }

    func testPointInsideSecondaryDisplay() {
        let primary = DisplayBounds(id: 1, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let secondary = DisplayBounds(id: 2, frame: CGRect(x: 1920, y: 0, width: 1920, height: 1080))
        let result = displayContainingPoint(CGPoint(x: 2500, y: 500), in: [primary, secondary])
        XCTAssertEqual(result?.id, 2)
    }

    func testPointInsideDisplayBelowOrigin() {
        // Display laid out below the primary (negative y in AppKit global coords).
        let primary = DisplayBounds(id: 1, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let below = DisplayBounds(id: 2, frame: CGRect(x: 0, y: -1080, width: 1920, height: 1080))
        let result = displayContainingPoint(CGPoint(x: 500, y: -500), in: [primary, below])
        XCTAssertEqual(result?.id, 2)
    }

    func testPointOutsideAllDisplaysReturnsNil() {
        let primary = DisplayBounds(id: 1, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let result = displayContainingPoint(CGPoint(x: 5000, y: 5000), in: [primary])
        XCTAssertNil(result)
    }
}
