import XCTest
@testable import Sealshot

final class CaptureCrosshairGeometryTests: XCTestCase {

    private let bounds = CGRect(x: 0, y: 0, width: 1000, height: 600)

    // MARK: - Hairlines

    func testHairlinesMidBounds() {
        let h = CrosshairGeometry.hairlines(
            at: CGPoint(x: 400, y: 300), in: bounds, gap: 7, thickness: 1)
        // Vertical segments centered on x, stopping `gap` short of the point.
        XCTAssertEqual(h.above, CGRect(x: 399.5, y: 307, width: 1, height: 293))
        XCTAssertEqual(h.below, CGRect(x: 399.5, y: 0, width: 1, height: 293))
        // Horizontal segments centered on y.
        XCTAssertEqual(h.left, CGRect(x: 0, y: 299.5, width: 393, height: 1))
        XCTAssertEqual(h.right, CGRect(x: 407, y: 299.5, width: 593, height: 1))
    }

    func testHairlinesNearLeftEdgeCollapseLeftSegment() {
        let h = CrosshairGeometry.hairlines(
            at: CGPoint(x: 3, y: 300), in: bounds, gap: 7, thickness: 1)
        XCTAssertEqual(h.left.width, 0)
        XCTAssertEqual(h.right.minX, 10)
    }

    func testHairlinesNearTopEdgeCollapseAboveSegment() {
        let h = CrosshairGeometry.hairlines(
            at: CGPoint(x: 400, y: 598), in: bounds, gap: 7, thickness: 1)
        XCTAssertEqual(h.above.height, 0)
        XCTAssertEqual(h.below.height, 591)
    }

    // MARK: - Badge placement

    func testBadgePrefersBelowRight() {
        let origin = CrosshairGeometry.badgeOrigin(
            near: CGPoint(x: 100, y: 500), size: CGSize(width: 120, height: 40),
            in: bounds, offset: 18)
        XCTAssertEqual(origin, CGPoint(x: 118, y: 442))
    }

    func testBadgeFlipsLeftNearRightEdge() {
        let origin = CrosshairGeometry.badgeOrigin(
            near: CGPoint(x: 950, y: 500), size: CGSize(width: 120, height: 40),
            in: bounds, offset: 18)
        XCTAssertEqual(origin.x, 950 - 18 - 120)
    }

    func testBadgeFlipsUpNearBottomEdge() {
        let origin = CrosshairGeometry.badgeOrigin(
            near: CGPoint(x: 100, y: 30), size: CGSize(width: 120, height: 40),
            in: bounds, offset: 18)
        XCTAssertEqual(origin.y, 30 + 18)
    }

    // MARK: - Loupe placement

    func testLoupePrefersBelowRight() {
        let origin = CrosshairGeometry.loupeOrigin(
            near: CGPoint(x: 100, y: 500), diameter: 130, in: bounds, offset: 24)
        XCTAssertEqual(origin, CGPoint(x: 124, y: 346))
    }

    func testLoupeFlipsBothNearBottomRightCorner() {
        let origin = CrosshairGeometry.loupeOrigin(
            near: CGPoint(x: 980, y: 20), diameter: 130, in: bounds, offset: 24)
        XCTAssertEqual(origin, CGPoint(x: 980 - 24 - 130, y: 20 + 24))
    }

    // MARK: - Loupe source rect (view coords; pixel mapping is FrozenFrameCrop's job)

    func testLoupeSourceCenteredWithZoomedDownSize() {
        let rect = CrosshairGeometry.loupeSourceViewRect(
            center: CGPoint(x: 400, y: 300), zoom: 3, diameter: 130, in: bounds)
        // 130 / 3 ≈ 43.33 pts of content fill the loupe.
        XCTAssertEqual(rect.width, 130.0 / 3.0, accuracy: 0.001)
        XCTAssertEqual(rect.height, 130.0 / 3.0, accuracy: 0.001)
        XCTAssertEqual(rect.midX, 400, accuracy: 0.001)
        XCTAssertEqual(rect.midY, 300, accuracy: 0.001)
    }

    func testLoupeSourceShiftsToStayInsideBoundsAtCorner() {
        let rect = CrosshairGeometry.loupeSourceViewRect(
            center: CGPoint(x: 2, y: 2), zoom: 3, diameter: 130, in: bounds)
        XCTAssertEqual(rect.minX, 0, accuracy: 0.001)
        XCTAssertEqual(rect.minY, 0, accuracy: 0.001)
        XCTAssertEqual(rect.width, 130.0 / 3.0, accuracy: 0.001)  // size preserved
    }
}
