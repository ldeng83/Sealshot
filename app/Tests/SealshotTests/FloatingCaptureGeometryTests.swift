import XCTest
@testable import Sealshot

final class FloatingCaptureGeometryTests: XCTestCase {

    /// A screen whose visible frame excludes a 25pt menu bar at the top — the
    /// realistic case, and the one a naive `frame`-based snap gets wrong.
    private let visible = CGRect(x: 0, y: 0, width: 1000, height: 775)
    private let panel = CGSize(width: 120, height: 70)

    private func snap(_ origin: CGPoint) -> CGRect {
        settle(origin).frame
    }

    private func settle(_ origin: CGPoint) -> (frame: CGRect, corner: FloatingCaptureGeometry.Corner) {
        FloatingCaptureGeometry.snapped(
            CGRect(origin: origin, size: panel), in: visible,
            threshold: FloatingCaptureGeometry.snapThreshold,
            margin: FloatingCaptureGeometry.margin)
    }

    // MARK: Sizes

    // MARK: Both axes

    /// Dragged into a corner, BOTH axes snap. They are decided independently,
    /// so neither can preempt the other.
    func testSnap_intoACorner_snapsBothAxes() {
        let (frame, corner) = settle(CGPoint(x: 20, y: 22))
        XCTAssertEqual(frame.minX, 14, accuracy: 0.001)
        XCTAssertEqual(frame.minY, 14, accuracy: 0.001)
        XCTAssertEqual(corner, FloatingCaptureGeometry.Corner(horizontal: .left, vertical: .bottom))
        XCTAssertTrue(corner.isCorner)
    }

    /// A panel shoved PAST a corner sits further than the threshold from the
    /// margin on the axis it overshot — which is why the first version appeared
    /// to snap only one axis. Overshoot always comes back.
    func testSnap_pastACorner_stillSnapsBothAxes() {
        let (frame, corner) = settle(CGPoint(x: -120, y: -90))
        XCTAssertEqual(frame.minX, 14, accuracy: 0.001)
        XCTAssertEqual(frame.minY, 14, accuracy: 0.001)
        XCTAssertEqual(corner, FloatingCaptureGeometry.Corner(horizontal: .left, vertical: .bottom))
    }

    func testSnap_pastTheOppositeCorner_comesBackToo() {
        let (frame, corner) = settle(CGPoint(x: 1400, y: 1200))
        XCTAssertEqual(frame.maxX, visible.maxX - 14, accuracy: 0.001)
        XCTAssertEqual(frame.maxY, visible.maxY - 14, accuracy: 0.001)
        XCTAssertEqual(corner, FloatingCaptureGeometry.Corner(horizontal: .right, vertical: .top))
    }

    /// Overshooting one axis only pulls that axis back; the other stays put.
    func testSnap_overshootOnOneAxis_leavesTheOtherAlone() {
        let (frame, corner) = settle(CGPoint(x: -50, y: 380))
        XCTAssertEqual(frame.minX, 14, accuracy: 0.001)
        XCTAssertEqual(frame.minY, 380, accuracy: 0.001)
        XCTAssertEqual(corner.horizontal, .left)
        XCTAssertNil(corner.vertical)
        XCTAssertFalse(corner.isCorner, "one edge is not a corner — it must not follow the pointer")
    }

    // MARK: Carrying a corner to another display

    func testOrigin_forCorner_placesThePanelOnAnotherDisplay() {
        let other = CGRect(x: 2000, y: 500, width: 1512, height: 945)
        let topRight = FloatingCaptureGeometry.Corner(horizontal: .right, vertical: .top)
        let origin = FloatingCaptureGeometry.origin(for: topRight, size: panel, in: other)
        XCTAssertEqual(origin.x, other.maxX - 14 - panel.width, accuracy: 0.001)
        XCTAssertEqual(origin.y, other.maxY - 14 - panel.height, accuracy: 0.001)
    }

    /// The same corner on displays of different sizes — the panel keeps its
    /// relationship to the corner, not its absolute coordinates.
    func testOrigin_forCorner_isRelativeToEachDisplaysVisibleFrame() {
        let bottomLeft = FloatingCaptureGeometry.Corner(horizontal: .left, vertical: .bottom)
        let small = CGRect(x: -1000, y: -200, width: 800, height: 600)
        let origin = FloatingCaptureGeometry.origin(for: bottomLeft, size: panel, in: small)
        XCTAssertEqual(origin.x, small.minX + 14, accuracy: 0.001)
        XCTAssertEqual(origin.y, small.minY + 14, accuracy: 0.001)
    }

    /// Tile COUNT is width-derived now; the preset only decides whether the
    /// strip shows at all.
    func testSizes_onlyCompactHidesTheStrip() {
        XCTAssertFalse(FloatingPanelSize.compact.showsThumbnails)
        XCTAssertTrue(FloatingPanelSize.standard.showsThumbnails)
        XCTAssertTrue(FloatingPanelSize.strip.showsThumbnails)
    }

    // MARK: Snapping

    func testSnap_nearBottomLeft_snapsFlushWithMargin() {
        let r = snap(CGPoint(x: 20, y: 22))
        XCTAssertEqual(r.minX, 14, accuracy: 0.001)
        XCTAssertEqual(r.minY, 14, accuracy: 0.001)
    }

    func testSnap_nearTopRight_snapsInsideTheVisibleFrame() {
        let r = snap(CGPoint(x: 860, y: 690))
        XCTAssertEqual(r.maxX, visible.maxX - 14, accuracy: 0.001)
        XCTAssertEqual(r.maxY, visible.maxY - 14, accuracy: 0.001)
        // The whole panel stays inside the visible frame — never under the menu bar.
        XCTAssertTrue(visible.contains(r))
    }

    func testSnap_farFromEveryCorner_doesNotMove() {
        let origin = CGPoint(x: 400, y: 380)
        XCTAssertEqual(snap(origin).origin, origin)
    }

    /// Axes snap independently: near the left edge but vertically centred
    /// should pull sideways only.
    func testSnap_nearOneAxisOnly_snapsThatAxisAlone() {
        let r = snap(CGPoint(x: 18, y: 380))
        XCTAssertEqual(r.minX, 14, accuracy: 0.001)
        XCTAssertEqual(r.minY, 380, accuracy: 0.001)
    }

    func testSnap_justOutsideThreshold_doesNotMove() {
        let outside = FloatingCaptureGeometry.margin + FloatingCaptureGeometry.snapThreshold + 1
        let r = snap(CGPoint(x: outside, y: 380))
        XCTAssertEqual(r.minX, outside, accuracy: 0.001)
    }

    /// The panel keeps its size through a snap — snapping repositions, it must
    /// never resize.
    func testSnap_preservesTheSize() {
        XCTAssertEqual(snap(CGPoint(x: 20, y: 22)).size, panel)
    }
}


/// Edge-docking geometry: past-the-edge detection, the line's frame, and the
/// restore placement — all pure, so a two-monitor desk isn't a prerequisite.
final class FloatingDockGeometryTests: XCTestCase {

    private let visible = CGRect(x: 0, y: 0, width: 1000, height: 775)
    private let panel = CGRect(x: 100, y: 100, width: 240, height: 90)

    func testDockEdge_requiresARealOvershoot() {
        // 20pt past the left edge: below the 24pt trigger → snap-back, not dock.
        XCTAssertNil(FloatingCaptureGeometry.dockEdge(
            for: CGRect(x: -20, y: 100, width: 240, height: 90), in: visible))
        XCTAssertEqual(FloatingCaptureGeometry.dockEdge(
            for: CGRect(x: -25, y: 100, width: 240, height: 90), in: visible), .left)
    }

    func testDockEdge_detectsAllFourEdges() {
        XCTAssertEqual(FloatingCaptureGeometry.dockEdge(
            for: CGRect(x: 790, y: 100, width: 240, height: 90), in: visible), .right)
        XCTAssertEqual(FloatingCaptureGeometry.dockEdge(
            for: CGRect(x: 100, y: 715, width: 240, height: 90), in: visible), .top)
        XCTAssertEqual(FloatingCaptureGeometry.dockEdge(
            for: CGRect(x: 100, y: -25, width: 240, height: 90), in: visible), .bottom)
        XCTAssertNil(FloatingCaptureGeometry.dockEdge(for: panel, in: visible))
    }

    /// What a released line-drag does: dropped near an edge it re-parks
    /// against that edge (its center's closest, horizontal winning ties like
    /// `dockEdge`); pulled clearly away from every edge, the drag reads as
    /// the restore gesture.
    func testLineRelease_reParksNearAnEdgeAndUndocksInTheOpen() {
        func release(_ x: CGFloat, _ y: CGFloat) -> FloatingCaptureGeometry.LineRelease {
            FloatingCaptureGeometry.lineRelease(
                for: CGRect(x: x, y: y, width: 64, height: 18), in: visible)
        }
        XCTAssertEqual(release(10, 380), .repark(.left))
        XCTAssertEqual(release(930, 380), .repark(.right))
        XCTAssertEqual(release(470, 20), .repark(.bottom))
        XCTAssertEqual(release(470, 730), .repark(.top))
        // Well clear of every edge — pulled into the open → undock.
        XCTAssertEqual(release(470, 380), .undock)
        // Just inside vs just past the threshold from the left edge.
        let d = FloatingCaptureGeometry.undockDragDistance
        XCTAssertEqual(release(d - 40, 380), .repark(.left))
        XCTAssertEqual(release(d - 20, 380), .undock,
                       "center sits 12pt past the threshold")
    }

    func testDockedLineFrame_hugsTheEdgeInsideTheScreen() {
        let line = FloatingCaptureGeometry.dockedLineFrame(
            edge: .left, near: CGRect(x: -60, y: 300, width: 240, height: 90), in: visible)
        XCTAssertEqual(line.minX, visible.minX, accuracy: 0.001)
        XCTAssertEqual(line.width, FloatingCaptureGeometry.dockedLineThickness)
        XCTAssertEqual(line.midY, 345, accuracy: 0.001, "centred where the panel was")
        XCTAssertTrue(visible.contains(line))
    }

    func testDockedLineFrame_clampsToTheScreen() {
        let line = FloatingCaptureGeometry.dockedLineFrame(
            edge: .right, near: CGRect(x: 1100, y: 760, width: 240, height: 90), in: visible)
        XCTAssertTrue(visible.contains(line), "a line near a corner must stay on-screen")
    }

    func testRestoredFrame_sitsBesideTheEdgeAtTheMargin() {
        let line = CGRect(x: 0, y: 300, width: 8, height: 64)
        let restored = FloatingCaptureGeometry.restoredFrame(
            from: line, edge: .left, size: CGSize(width: 240, height: 90), in: visible)
        XCTAssertEqual(restored.minX, visible.minX + FloatingCaptureGeometry.margin,
                       accuracy: 0.001)
        XCTAssertEqual(restored.midY, line.midY, accuracy: 0.001)
        XCTAssertTrue(visible.contains(restored))
    }

    func testRestoredFrame_neverLandsOffScreen() {
        let line = CGRect(x: 992, y: 760, width: 8, height: 64)
        let restored = FloatingCaptureGeometry.restoredFrame(
            from: line, edge: .right, size: CGSize(width: 240, height: 90), in: visible)
        XCTAssertTrue(visible.contains(restored))
    }

    // MARK: Carrying the docked line to another display

    /// Same edge, same RELATIVE position: a raw coordinate from one screen may
    /// not exist on another, and displays differ in size.
    func testDockedLineMovedToAnotherScreen_keepsItsEdgeAndProportion() {
        let from = CGRect(x: 0, y: 0, width: 1000, height: 800)
        // Two-thirds of the way down the left edge.
        let line = CGRect(x: 0, y: 800 * 2 / 3 - 32, width: 18, height: 64)
        let other = CGRect(x: 2000, y: 100, width: 1600, height: 1200)

        let moved = FloatingCaptureGeometry.dockedLine(line, movedFrom: from,
                                                       to: other, edge: .left)
        XCTAssertEqual(moved.minX, other.minX, accuracy: 0.001, "still the LEFT edge")
        XCTAssertEqual(moved.width, FloatingCaptureGeometry.dockedLineThickness)
        let fraction = (moved.midY - other.minY) / other.height
        XCTAssertEqual(fraction, 2.0 / 3, accuracy: 0.01,
                       "the same proportion down the new screen")
    }

    func testDockedLineMovedToAnotherScreen_handlesHorizontalEdges() {
        let from = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let line = CGRect(x: 250 - 32, y: 0, width: 64, height: 18)
        let other = CGRect(x: -1600, y: 0, width: 1600, height: 900)

        let moved = FloatingCaptureGeometry.dockedLine(line, movedFrom: from,
                                                       to: other, edge: .bottom)
        XCTAssertEqual(moved.minY, other.minY, accuracy: 0.001, "still the BOTTOM edge")
        XCTAssertEqual(moved.height, FloatingCaptureGeometry.dockedLineThickness)
        XCTAssertEqual((moved.midX - other.minX) / other.width, 0.25, accuracy: 0.01)
    }

    /// A line near a corner of a much smaller screen must still land wholly on
    /// the new one.
    func testDockedLineMovedToAnotherScreen_staysOnScreen() {
        let from = CGRect(x: 0, y: 0, width: 3000, height: 2000)
        let line = CGRect(x: 0, y: 1990, width: 18, height: 64)
        let other = CGRect(x: 0, y: 0, width: 800, height: 600)

        let moved = FloatingCaptureGeometry.dockedLine(line, movedFrom: from,
                                                       to: other, edge: .left)
        XCTAssertTrue(other.contains(moved), "clamped fully onto the new display")
    }
}
