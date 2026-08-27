import XCTest
@testable import Sealshot

/// The rule that decides whether a mouse-down over the Library arms a file
/// drag. It has to satisfy four things at once, each of which has broken in a
/// real build:
///   1. a click on a visible tile arms it (drag-out was dead entirely),
///   2. it arms the tile UNDER THE POINTER, not some other registrant
///      (a multi-select dragged a capture the user hadn't selected),
///   3. a click in the gaps between tiles arms nothing (else the monitor
///      swallows the drag and the marquee can't start),
///   4. a click on the editor canvas arms nothing even when a stale off-screen
///      tile's frame overlaps it (that turned rectangle drawing into a
///      drag-out).
final class LibraryDragHitPolicyTests: XCTestCase {
    /// Two tiles laid out side by side, inside a grid clip that spans both —
    /// mirrors the measured geometry, where every registrant reports the SAME
    /// clip as its visible rect.
    private let clip = NSRect(x: 0, y: 0, width: 1000, height: 800)
    private let tileA = NSRect(x: 100, y: 100, width: 178, height: 162)
    private let tileB = NSRect(x: 300, y: 100, width: 178, height: 162)

    private func arms(tile: NSRect, at point: NSPoint,
                      clip: NSRect? = nil, isHidden: Bool = false,
                      sameWindow: Bool = true) -> Bool {
        LibraryDragHitPolicy.shouldArm(
            boundsInWindow: tile, visibleRectInWindow: clip ?? self.clip,
            point: point, isHidden: isHidden, sameWindow: sameWindow)
    }

    func testArmsTheTileUnderThePointer() {
        XCTAssertTrue(arms(tile: tileA, at: NSPoint(x: 150, y: 150)))
    }

    /// THE WRONG-TILE GUARD: the click is inside tile A, and every registrant
    /// shares the same clip rect. Tile B must NOT answer for it — matching on
    /// the shared clip alone armed an arbitrary tile and dragged out a capture
    /// the user never selected.
    func testDoesNotArmATileThePointerIsNotOver() {
        let pointInA = NSPoint(x: 150, y: 150)
        XCTAssertTrue(arms(tile: tileA, at: pointInA))
        XCTAssertFalse(arms(tile: tileB, at: pointInA))
    }

    /// THE MARQUEE GUARD: the gap between tiles belongs to the marquee. If a
    /// registrant claims it, the monitor consumes the drag and rubber-band
    /// selection stops working.
    func testDoesNotArmInTheGapBetweenTiles() {
        let gap = NSPoint(x: 290, y: 150)   // right of A, left of B
        XCTAssertFalse(arms(tile: tileA, at: gap))
        XCTAssertFalse(arms(tile: tileB, at: gap))
    }

    /// THE EDITOR GUARD: Editor and Library are tabs in ONE window and the
    /// monitor is app-wide. With the Library off screen its clip collapses, so
    /// a tile whose stale frame still covers the click can't answer.
    func testDoesNotArmWhenTheLibraryClipIsCollapsed() {
        XCTAssertFalse(arms(tile: tileA, at: NSPoint(x: 150, y: 150), clip: .zero))
    }

    /// Scrolled out of the clip: inside the tile's own frame, outside what's
    /// actually on screen.
    func testDoesNotArmOutsideTheVisibleClip() {
        let tileBelowFold = NSRect(x: 100, y: 900, width: 178, height: 162)
        XCTAssertFalse(arms(tile: tileBelowFold, at: NSPoint(x: 150, y: 950)))
    }

    func testIgnoresHiddenTiles() {
        XCTAssertFalse(arms(tile: tileA, at: NSPoint(x: 150, y: 150), isHidden: true))
    }

    /// The monitor sees every window's clicks; a tile in another window must
    /// not answer for this one.
    func testIgnoresTilesInAnotherWindow() {
        XCTAssertFalse(arms(tile: tileA, at: NSPoint(x: 150, y: 150), sameWindow: false))
    }
}
