import XCTest
@testable import Sealshot

final class RecordingHUDStateTests: XCTestCase {

    func testDefault_isCollapsedRedZero() {
        let s = RecordingHUDState()
        XCTAssertFalse(s.isExpanded)
        XCTAssertFalse(s.isPaused)
        XCTAssertFalse(s.isAmber)
        XCTAssertEqual(s.timeText, "0:00")
    }

    func testHover_expands_thenCollapsesOnLeave() {
        var s = RecordingHUDState()
        s.setHovering(true)
        XCTAssertTrue(s.isExpanded)
        s.setHovering(false)
        XCTAssertFalse(s.isExpanded, "unpinned: leaving hover collapses")
    }

    func testPin_keepsExpandedAfterHoverLeaves() {
        var s = RecordingHUDState()
        s.setHovering(true)
        s.togglePin()                 // pin while hovering
        s.setHovering(false)
        XCTAssertTrue(s.isExpanded, "pinned stays expanded without hover")
    }

    func testTogglePin_twice_returnsToCollapsed() {
        var s = RecordingHUDState()
        s.togglePin()
        XCTAssertTrue(s.isExpanded)
        s.togglePin()
        XCTAssertFalse(s.isExpanded)
    }

    func testPaused_isAmber() {
        var s = RecordingHUDState()
        s.isPaused = true
        XCTAssertTrue(s.isAmber)
    }

    func testElapsedFormatting() {
        var s = RecordingHUDState()
        s.elapsedSeconds = 0;   XCTAssertEqual(s.timeText, "0:00")
        s.elapsedSeconds = 5;   XCTAssertEqual(s.timeText, "0:05")
        s.elapsedSeconds = 65;  XCTAssertEqual(s.timeText, "1:05")
        s.elapsedSeconds = 600; XCTAssertEqual(s.timeText, "10:00")
    }

    func testGrace_expandsUntilCleared() {
        var s = RecordingHUDState()
        s.setGraceExpanded(true)
        XCTAssertTrue(s.isExpanded, "start-of-recording grace shows the expanded pill")
        s.setGraceExpanded(false)
        XCTAssertFalse(s.isExpanded, "grace over: collapses when not hovered/pinned")
    }

    func testGraceEnd_keepsExpansionWhileHovering() {
        var s = RecordingHUDState()
        s.setGraceExpanded(true)
        s.setHovering(true)
        s.setGraceExpanded(false)
        XCTAssertTrue(s.isExpanded, "hover outlives the grace window")
    }

    func testGraceEnd_keepsExpansionWhilePinned() {
        var s = RecordingHUDState()
        s.setGraceExpanded(true)
        s.togglePin()
        s.setGraceExpanded(false)
        XCTAssertTrue(s.isExpanded, "pin outlives the grace window")
    }

    func testEntranceStack_flipsBelowWhenHUDParkedNearTop() {
        // Plenty of headroom → caption+chevron sit above the pill.
        XCTAssertTrue(RecordingHUDController.entranceStackAbove(
            hudMaxY: 200, stackHeight: 70, screenTopY: 900))
        // Pill dragged near the top: the stack wouldn't fit → flips below.
        XCTAssertFalse(RecordingHUDController.entranceStackAbove(
            hudMaxY: 860, stackHeight: 70, screenTopY: 900))
        // Exactly fits stays above.
        XCTAssertTrue(RecordingHUDController.entranceStackAbove(
            hudMaxY: 830, stackHeight: 70, screenTopY: 900))
    }

    func testClampedOrigin_appliesOffsetWithinScreen() {
        let screen = NSRect(x: 1000, y: 500, width: 1600, height: 900)
        let origin = RecordingHUDController.clampedOrigin(
            offset: NSPoint(x: 200, y: 60), screenFrame: screen,
            size: NSSize(width: 180, height: 40))
        XCTAssertEqual(origin, NSPoint(x: 1200, y: 560))
    }

    func testClampedOrigin_clampsOffsetsThatOverflowASmallerScreen() {
        // Saved on a big monitor, replayed on a smaller one: stays fully on it.
        let screen = NSRect(x: 0, y: 0, width: 800, height: 600)
        let origin = RecordingHUDController.clampedOrigin(
            offset: NSPoint(x: 3000, y: 2000), screenFrame: screen,
            size: NSSize(width: 180, height: 40))
        XCTAssertEqual(origin, NSPoint(x: 800 - 180, y: 600 - 40))
        // Negative offsets pin to the screen origin.
        let low = RecordingHUDController.clampedOrigin(
            offset: NSPoint(x: -50, y: -50), screenFrame: screen,
            size: NSSize(width: 180, height: 40))
        XCTAssertEqual(low, NSPoint(x: 0, y: 0))
    }
}
