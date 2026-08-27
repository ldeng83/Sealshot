import XCTest
import CoreGraphics
@testable import Sealshot

/// SCWindow frames are Quartz-global (top-left origin); the selection rect is
/// AppKit-global (bottom-left origin). Overlap math needs them in one space.
final class WindowFrameConversionTests: XCTestCase {

    func testTopOfPrimary_mapsToTopInAppKit() {
        // A window flush with the top of a 1000pt-tall primary display.
        let appkit = quartzToAppKit(CGRect(x: 0, y: 0, width: 100, height: 50), primaryHeight: 1000)
        XCTAssertEqual(appkit, CGRect(x: 0, y: 950, width: 100, height: 50))
    }

    func testBottomOfPrimary_mapsToOriginInAppKit() {
        let appkit = quartzToAppKit(CGRect(x: 200, y: 900, width: 100, height: 100), primaryHeight: 1000)
        XCTAssertEqual(appkit, CGRect(x: 200, y: 0, width: 100, height: 100))
    }

    func testXAndSizeUnchanged() {
        let appkit = quartzToAppKit(CGRect(x: 37, y: 120, width: 64, height: 48), primaryHeight: 1000)
        XCTAssertEqual(appkit.origin.x, 37)
        XCTAssertEqual(appkit.size.width, 64)
        XCTAssertEqual(appkit.size.height, 48)
    }

    func testSecondaryDisplayAbovePrimary_yGoesPositive() {
        // A window on a display stacked above the primary sits at negative
        // Quartz-ish... here modeled as y far above: quartz y = -200 height 100
        // -> appkit y = 1000 - (-200 + 100) = 1100 (above the primary's top).
        let appkit = quartzToAppKit(CGRect(x: 0, y: -200, width: 50, height: 100), primaryHeight: 1000)
        XCTAssertEqual(appkit.origin.y, 1100)
    }
}
