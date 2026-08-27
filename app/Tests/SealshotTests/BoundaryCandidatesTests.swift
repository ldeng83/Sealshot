import XCTest
import CoreGraphics
@testable import Sealshot

final class BoundaryCandidatesTests: XCTestCase {

    // Nested: button inside card inside panel; one window behind everything.
    private let button = CGRect(x: 100, y: 100, width: 60, height: 24)
    private let card = CGRect(x: 80, y: 80, width: 200, height: 120)
    private let panel = CGRect(x: 40, y: 40, width: 400, height: 300)
    private let windowRect = CGRect(x: 0, y: 0, width: 800, height: 600)

    private func makeCandidates() -> BoundaryCandidates {
        BoundaryCandidates(
            boundaryRects: [panel, button, card],          // unsorted on purpose
            windowRects: [(1, windowRect)])
    }

    func testStack_insideAll_isSmallestFirstThenWindow() {
        let stack = makeCandidates().stack(at: CGPoint(x: 110, y: 110))
        XCTAssertEqual(stack.map(\.rect), [button, card, panel, windowRect])
        XCTAssertEqual(stack.last?.kind, .window(1))
    }

    func testStack_insideCardOnly_skipsButton() {
        let stack = makeCandidates().stack(at: CGPoint(x: 250, y: 150))
        XCTAssertEqual(stack.map(\.rect), [card, panel, windowRect])
    }

    func testStack_outsideEverything_isEmpty() {
        let stack = makeCandidates().stack(at: CGPoint(x: 700, y: 700))
        XCTAssertTrue(stack.isEmpty)
    }

    func testStack_windowOnly() {
        let stack = makeCandidates().stack(at: CGPoint(x: 600, y: 500))
        XCTAssertEqual(stack.map(\.rect), [windowRect])
    }

    func testBoundaryKind_isBoundary() {
        let stack = makeCandidates().stack(at: CGPoint(x: 110, y: 110))
        XCTAssertEqual(stack.first?.kind, .boundary)
    }

    // MARK: - Top-bar demotion (tab/menu/toolbar strips shouldn't win the hover)

    // View-local coords: bottom-left origin, so a window spanning y 0–600 has
    // its top edge at maxY = 600. A tab-bar strip hugs that top edge.
    private let browserWindow = CGRect(x: 0, y: 0, width: 800, height: 600)
    private let tabBar = CGRect(x: 0, y: 560, width: 800, height: 40)

    func testStack_hoverInTopBar_prefersWindow() {
        let candidates = BoundaryCandidates(
            boundaryRects: [tabBar],
            windowRects: [(7, browserWindow)])
        let stack = candidates.stack(at: CGPoint(x: 400, y: 580))
        XCTAssertEqual(stack.map(\.rect), [browserWindow, tabBar],
                       "the whole window should highlight first; the strip stays cyclable")
    }

    func testStack_topBarOfDetectedPanel_prefersPanel() {
        // The container can be a detected boundary too, not just a window.
        let panelTop = CGRect(x: 40, y: 472, width: 400, height: 32)   // flush with panel top (504)
        let stack = BoundaryCandidates(
            boundaryRects: [panelTop, CGRect(x: 40, y: 40, width: 400, height: 464)],
            windowRects: []).stack(at: CGPoint(x: 200, y: 480))
        XCTAssertEqual(stack.first?.rect, CGRect(x: 40, y: 40, width: 400, height: 464))
    }

    func testStack_smallButtonNearTop_isNotDemoted() {
        // Narrow rect near the top (e.g. a toolbar button) is NOT a top bar.
        let button = CGRect(x: 10, y: 565, width: 80, height: 30)
        let stack = BoundaryCandidates(
            boundaryRects: [button],
            windowRects: [(7, browserWindow)]).stack(at: CGPoint(x: 50, y: 575))
        XCTAssertEqual(stack.first?.rect, button)
    }

    func testStack_wideRectInMiddle_isNotDemoted() {
        // Wide and thin but NOT at the container's top (e.g. a list row).
        let row = CGRect(x: 0, y: 300, width: 800, height: 40)
        let stack = BoundaryCandidates(
            boundaryRects: [row],
            windowRects: [(7, browserWindow)]).stack(at: CGPoint(x: 400, y: 320))
        XCTAssertEqual(stack.first?.rect, row)
    }

    // MARK: - Window-scale filter (detection serves window/app areas only)

    func testWindowScaleRects_dropsSmallElements() {
        let button = CGRect(x: 0, y: 0, width: 80, height: 30)
        let tabBar = CGRect(x: 0, y: 560, width: 800, height: 40)     // wide but short
        let sidebar = CGRect(x: 0, y: 0, width: 180, height: 900)    // tall but narrow
        let appArea = CGRect(x: 100, y: 100, width: 640, height: 480)
        let filtered = BoundaryCandidates.windowScaleRects([button, tabBar, sidebar, appArea])
        XCTAssertEqual(filtered, [appArea])
    }

    func testWindowScaleRects_keepsSmallDialogSizedAreas() {
        let dialog = CGRect(x: 200, y: 200, width: 260, height: 180)
        XCTAssertEqual(BoundaryCandidates.windowScaleRects([dialog]), [dialog])
    }

    func testStack_tallTopPane_isNotDemoted() {
        // Flush with the top but tall (half the window) — a real pane, not a bar.
        let pane = CGRect(x: 0, y: 300, width: 800, height: 300)
        let stack = BoundaryCandidates(
            boundaryRects: [pane],
            windowRects: [(7, browserWindow)]).stack(at: CGPoint(x: 400, y: 500))
        XCTAssertEqual(stack.first?.rect, pane)
    }
}
