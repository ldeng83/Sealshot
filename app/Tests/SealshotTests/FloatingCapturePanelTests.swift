import AppKit
import XCTest
@testable import Sealshot

@MainActor
final class FloatingCapturePanelTests: XCTestCase {

    /// Clicking the panel must not activate Sealshot: several capture paths
    /// record the FRONTMOST application as the capture's source, so a panel
    /// that stole focus would corrupt the metadata of the captures it starts.
    func testPanel_isNonActivatingAndNeverBecomesKey() {
        let panel = FloatingCapturePanel()
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
    }

    func testPanel_floatsAboveOrdinaryWindows() {
        XCTAssertEqual(FloatingCapturePanel().level, .floating)
    }

    /// It has to stay reachable wherever the user is working, and stay put
    /// when Spaces switch.
    func testPanel_joinsAllSpacesAndSurvivesFullScreen() {
        let behavior = FloatingCapturePanel().collectionBehavior
        XCTAssertTrue(behavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(behavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(behavior.contains(.stationary))
    }

    /// The panel outlives losing focus and outlives being closed — either
    /// would otherwise make it vanish mid-run.
    func testPanel_staysVisibleOnDeactivateAndIsNotReleasedOnClose() {
        let panel = FloatingCapturePanel()
        XCTAssertFalse(panel.hidesOnDeactivate)
        XCTAssertFalse(panel.isReleasedWhenClosed)
    }

    /// Dragging is handled manually so the RELEASE can snap to a corner;
    /// window-background dragging would move it with no release hook.
    func testPanel_doesNotUseBuiltInBackgroundDragging() {
        XCTAssertFalse(FloatingCapturePanel().isMovableByWindowBackground)
    }

    // MARK: Solid on hover

    /// Raising the window's alpha alone still let the desktop show through the
    /// vibrancy, so the panel you were about to click was the hardest thing on
    /// screen to read. Hovering makes it properly opaque.
    func testHover_fadesInAnOpaqueBackdrop() {
        let view = FloatingCaptureContentView()
        let panel = FloatingCapturePanel()
        panel.contentView = view

        view.setSolidBackground(false, animated: false)
        XCTAssertEqual(view.backdropAlphaForTesting, 0, accuracy: 0.001)
        view.setSolidBackground(true, animated: false)
        XCTAssertEqual(view.backdropAlphaForTesting, 1, accuracy: 0.001)
    }

    /// The backdrop sits UNDER the controls — going solid must not cover them.
    func testBackdrop_sitsBelowTheControls() {
        let view = FloatingCaptureContentView()
        let panel = FloatingCapturePanel()
        let control = NSView()
        view.addSubview(control)
        panel.contentView = view
        XCTAssertEqual(view.subviews.first, view.backdropForTesting)
    }

    // MARK: Drag

    /// The drag anchors to SCREEN coordinates. The first implementation used a
    /// pan recognizer's `translation(in: nil)`, which reports movement in the
    /// window's own coordinate space — so each frame moved the window, which
    /// moved the space the next translation was measured in. The panel jittered
    /// and drifted away from the pointer. This pins the invariant that makes
    /// that impossible: the grab offset is fixed at mouse-down, so the window's
    /// position is a pure function of the pointer, never of its own last
    /// position.
    func testDrag_windowOriginIsAPureFunctionOfThePointer() {
        let view = FloatingCaptureContentView()
        let panel = FloatingCapturePanel()
        panel.contentView = view
        panel.setFrameOrigin(NSPoint(x: 100, y: 100))

        // Grab 20pt right and 15pt up from the window's origin.
        view.beginDragForTesting(pointer: NSPoint(x: 120, y: 115))

        view.dragForTesting(pointer: NSPoint(x: 300, y: 400))
        XCTAssertEqual(panel.frame.origin, NSPoint(x: 280, y: 385))

        // Same pointer twice must land in the same place — the defining
        // property a feedback loop would break.
        view.dragForTesting(pointer: NSPoint(x: 300, y: 400))
        XCTAssertEqual(panel.frame.origin, NSPoint(x: 280, y: 385))

        // And moving back to the start returns exactly to the start.
        view.dragForTesting(pointer: NSPoint(x: 120, y: 115))
        XCTAssertEqual(panel.frame.origin, NSPoint(x: 100, y: 100))
    }

    /// The grab offset is what keeps the panel under the cursor rather than
    /// jumping so its corner meets the pointer.
    func testDrag_preservesWhereInThePanelYouGrabbedIt() {
        let view = FloatingCaptureContentView()
        let panel = FloatingCapturePanel()
        panel.contentView = view
        panel.setFrameOrigin(NSPoint(x: 500, y: 300))

        view.beginDragForTesting(pointer: NSPoint(x: 560, y: 340))   // 60,40 into the panel
        view.dragForTesting(pointer: NSPoint(x: 561, y: 341))        // nudge 1pt
        XCTAssertEqual(panel.frame.origin, NSPoint(x: 501, y: 301))
    }

    /// A drag that never began must not move the window — otherwise a stray
    /// mouse-dragged after a click on a button would fling the panel.
    func testDrag_withoutAMouseDown_doesNothing() {
        let view = FloatingCaptureContentView()
        let panel = FloatingCapturePanel()
        panel.contentView = view
        panel.setFrameOrigin(NSPoint(x: 200, y: 200))

        view.dragForTesting(pointer: NSPoint(x: 900, y: 900))
        XCTAssertEqual(panel.frame.origin, NSPoint(x: 200, y: 200))
    }

    /// A press that travels is a drag (settles); one that doesn't is a CLICK —
    /// the docked line restores from clicks, so the two must stay distinct.
    func testDragEnd_distinguishesClicksFromDrags() {
        let view = FloatingCaptureContentView()
        let panel = FloatingCapturePanel()
        panel.contentView = view
        var settles = 0, clicks = 0
        view.onDragEnded = { settles += 1 }
        view.onClick = { clicks += 1 }

        view.endDragForTesting()
        XCTAssertEqual(settles + clicks, 0, "a mouse-up with no press does nothing")

        // Press and release without travel: click, no settle.
        view.beginDragForTesting(pointer: NSPoint(x: 10, y: 10))
        view.endDragForTesting()
        XCTAssertEqual(clicks, 1)
        XCTAssertEqual(settles, 0)

        // Press, travel past the threshold, release: drag, no click.
        view.beginDragForTesting(pointer: NSPoint(x: 10, y: 10))
        view.dragForTesting(pointer: NSPoint(x: 40, y: 10))
        view.endDragForTesting()
        XCTAssertEqual(clicks, 1)
        XCTAssertEqual(settles, 1)
    }
}
