import AppKit
import XCTest
@testable import Sealshot

final class DragPeekStateTests: XCTestCase {

    func test_holdingModifierHides_releasingRestores() {
        var s = DragPeekState()
        s.begin(windowWasVisible: true)
        XCTAssertEqual(s.update(modifierHeld: true, anyMouseButtonDown: true), .hide)
        XCTAssertTrue(s.isHidden)
        XCTAssertEqual(s.update(modifierHeld: false, anyMouseButtonDown: true), .restore)
        XCTAssertFalse(s.isHidden)
    }

    /// Only TRANSITIONS act. A steady state must not re-issue the action every
    /// 50ms tick, or the window is re-ordered 20 times a second.
    func test_steadyStateIssuesNoAction() {
        var s = DragPeekState()
        s.begin(windowWasVisible: true)
        XCTAssertEqual(s.update(modifierHeld: true, anyMouseButtonDown: true), .hide)
        XCTAssertEqual(s.update(modifierHeld: true, anyMouseButtonDown: true), .none)
        XCTAssertEqual(s.update(modifierHeld: true, anyMouseButtonDown: true), .none)
    }

    /// Guard 1: a window that was already closed must never be summoned.
    func test_windowNotVisibleAtStart_neverHides() {
        var s = DragPeekState()
        s.begin(windowWasVisible: false)
        XCTAssertEqual(s.update(modifierHeld: true, anyMouseButtonDown: true), .none)
        XCTAssertFalse(s.isHidden)
        XCTAssertEqual(s.end(), .none)
    }

    /// Guard 2: end() restores only what we actually hid.
    func test_endRestoresOnlyWhenHidden() {
        var s = DragPeekState()
        s.begin(windowWasVisible: true)
        XCTAssertEqual(s.end(), .none)

        var t = DragPeekState()
        t.begin(windowWasVisible: true)
        _ = t.update(modifierHeld: true, anyMouseButtonDown: true)
        XCTAssertEqual(t.end(), .restore)
    }

    /// The watchdog: the button coming up means the drag ended without endedAt
    /// reaching us. A hidden window must come back.
    func test_mouseButtonUpWhileHidden_restores() {
        var s = DragPeekState()
        s.begin(windowWasVisible: true)
        _ = s.update(modifierHeld: true, anyMouseButtonDown: true)
        XCTAssertEqual(s.update(modifierHeld: true, anyMouseButtonDown: false), .restore)
        XCTAssertFalse(s.isHidden)
    }

    /// After the watchdog fires the session is over — later ticks do nothing,
    /// even if the modifier is still held.
    func test_afterWatchdog_updatesAreInert() {
        var s = DragPeekState()
        s.begin(windowWasVisible: true)
        _ = s.update(modifierHeld: true, anyMouseButtonDown: true)
        _ = s.update(modifierHeld: true, anyMouseButtonDown: false)
        XCTAssertEqual(s.update(modifierHeld: true, anyMouseButtonDown: true), .none)
    }

    /// Nothing happens before begin().
    func test_updateBeforeBeginIsInert() {
        var s = DragPeekState()
        XCTAssertEqual(s.update(modifierHeld: true, anyMouseButtonDown: true), .none)
    }

    /// The app-activation failsafe: forceVisible() must undo a hide without
    /// ending the session, so a later ⌃ press in the same drag can hide again.
    func test_forceVisible_restoresAndAllowsPeekToResume() {
        var s = DragPeekState()
        s.begin(windowWasVisible: true)
        XCTAssertEqual(s.update(modifierHeld: true, anyMouseButtonDown: true), .hide)
        XCTAssertTrue(s.isHidden)

        XCTAssertEqual(s.forceVisible(), .restore)
        XCTAssertFalse(s.isHidden)

        // Idempotent — nothing left to restore.
        XCTAssertEqual(s.forceVisible(), .none)

        // The session is still active: ⌃ still held can hide it again.
        XCTAssertEqual(s.update(modifierHeld: true, anyMouseButtonDown: true), .hide)
        XCTAssertTrue(s.isHidden)
    }
}

@MainActor
final class DragPeekControllerTests: XCTestCase {

    private func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
                         styleMask: [.titled], backing: .buffered, defer: false)
        w.alphaValue = 1
        w.ignoresMouseEvents = false
        return w
    }

    func test_hideMakesWindowInvisibleAndClickThrough() {
        let w = makeWindow()
        DragPeekController.shared.applyForTesting(.hide, to: w)
        XCTAssertEqual(w.alphaValue, 0)
        XCTAssertTrue(w.ignoresMouseEvents)
    }

    /// Restore must undo BOTH properties. Alpha alone leaves the window
    /// click-through and invisible to the user's mouse.
    func test_restoreUndoesBothProperties() {
        let w = makeWindow()
        DragPeekController.shared.applyForTesting(.hide, to: w)
        DragPeekController.shared.applyForTesting(.restore, to: w)
        XCTAssertEqual(w.alphaValue, 1)
        XCTAssertFalse(w.ignoresMouseEvents)
    }

    func test_restoreIsIdempotent() {
        let w = makeWindow()
        DragPeekController.shared.applyForTesting(.restore, to: w)
        DragPeekController.shared.applyForTesting(.restore, to: w)
        XCTAssertEqual(w.alphaValue, 1)
        XCTAssertFalse(w.ignoresMouseEvents)
    }

    /// begin(hiding: nil) must be a true no-op: it must not disturb whatever
    /// session/window the controller is already tracking. (Rewritten from a
    /// version that never passed its window into begin() at all, and so
    /// proved nothing.)
    func test_beginWithNilWindowLeavesActiveSessionUntouched() {
        let a = makeWindow()
        DragPeekController.shared.begin(hiding: a)
        DragPeekController.shared.applyForTesting(.hide, to: a) // simulate a's hidden state
        DragPeekController.shared.begin(hiding: nil)
        // nil must not have restored `a` via the reentrancy path.
        XCTAssertEqual(a.alphaValue, 0)
        XCTAssertTrue(a.ignoresMouseEvents)

        // Clean up: restore the window's visual state directly (end() only
        // restores what the internal model believes it hid, and the model
        // never learned about the applyForTesting-simulated hide above), then
        // clear the controller's session so it can't leak into later tests.
        DragPeekController.shared.applyForTesting(.restore, to: a)
        DragPeekController.shared.end()
    }

    /// Reentrancy guard (Finding 1 fix): if begin() is called again for a new
    /// window while a previous window is still hidden from an unterminated
    /// session (e.g. a missed endedAt), the previous window must be restored,
    /// not stranded invisible and click-through forever.
    func test_reentrantBeginRestoresPreviouslyHiddenWindow() {
        let a = makeWindow()
        DragPeekController.shared.begin(hiding: a)
        DragPeekController.shared.applyForTesting(.hide, to: a) // simulate a's hidden state

        let b = makeWindow()
        DragPeekController.shared.begin(hiding: b)

        XCTAssertEqual(a.alphaValue, 1)
        XCTAssertFalse(a.ignoresMouseEvents)

        DragPeekController.shared.end()
    }

    /// Same-window reentrancy (Finding 1, round 2): the editor window is
    /// usually the SAME NSWindow across consecutive drags, so identity
    /// comparison must not be used to skip the restore. `NSWindow.isVisible`
    /// reflects order state, not our alpha-based hide, so without a physical
    /// restore first, re-adopting the same still-hidden window would let
    /// `state.begin(windowWasVisible:)` read `true` and silently reset
    /// `isHidden` to false while the window is still alpha 0 and
    /// click-through — stranding it with no reference left to recover it.
    func test_reentrantBeginWithSameWindowRestoresIt() {
        let a = makeWindow()
        DragPeekController.shared.begin(hiding: a)
        DragPeekController.shared.applyForTesting(.hide, to: a) // simulate a's hidden state

        DragPeekController.shared.begin(hiding: a) // same window, second drag

        XCTAssertEqual(a.alphaValue, 1)
        XCTAssertFalse(a.ignoresMouseEvents)

        DragPeekController.shared.end()
    }

    // NOTE: no unit test for the full-screen guard in `begin(hiding:)`.
    // Simulating `.fullScreen` on an off-screen test NSWindow via
    // `styleMask.insert(.fullScreen)` was tried and is NOT viable in this
    // test environment: AppKit raises "NSWindowStyleMaskFullScreen set on a
    // window outside of a full screen transition" as an NSGenericException
    // the moment the style mask is written outside a real
    // `toggleFullScreen(_:)` transition, which XCTest surfaces as a test
    // failure. Driving a genuine full-screen transition needs a live window
    // server round trip that isn't available here. The guard itself
    // (`guard !window.styleMask.contains(.fullScreen) else { return }` in
    // `begin(hiding:)`) is covered only by build-time review, not a test.
}
