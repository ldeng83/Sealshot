import AppKit

/// Hold ⌃ during a drag and the editor window gets out of the way; release and
/// it comes back.
///
/// Why a TIMER and not `draggingSession(_:movedTo:)`: `movedTo` only fires while
/// the pointer moves, so releasing ⌃ while holding still would strand the window
/// hidden until the next nudge.
///
/// Why POLLING and not a key handler: keyboard events do not reach the app
/// during a drag. They are QUEUED and flush the moment the drag ends — measured:
/// a global hotkey fired 0 times mid-drag, then delivered ten presses in the
/// same millisecond as `endedAt`. `NSEvent.modifierFlags` is a live hardware
/// poll and does work mid-drag.
@MainActor
final class DragPeekController {

    static let shared = DragPeekController()

    private var state = DragPeekState()
    private weak var window: NSWindow?
    private var timer: Timer?

    private init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { DragPeekController.shared.forceRestore() }
            }
    }

    /// Call from `draggingSession(_:willBeginAt:)`.
    func begin(hiding window: NSWindow?) {
        guard let window else { return }
        // Reentrancy guard: if a prior session never reached end() (e.g. a
        // missed endedAt with the button-watchdog also failing to fire),
        // restore whatever window it left behind before adopting this one.
        // Otherwise that window can be stranded — alphaValue 0, click-through,
        // forever — with no reference left to recover it.
        //
        // Unconditional: NOT gated on `state.isHidden` (the model may never
        // have learned about the hide) and NOT skipped when `previous ===
        // window` (the common case — the editor window is usually the SAME
        // NSWindow across consecutive drags). Identity is not a safe basis
        // for skipping: `NSWindow.isVisible` reflects ORDER state, not our
        // alpha-based hide, so `state.begin(windowWasVisible: window.isVisible)`
        // below would read `true` on a window that is still alpha 0 and
        // click-through, silently resetting `isHidden` to false as a lie.
        // Physically restoring first makes that reset true instead of a lie.
        // `apply(.restore:)` is idempotent, so restoring an already-visible
        // window costs nothing but one harmless `orderFrontRegardless()`.
        if let previous = self.window {
            apply(.restore, to: previous)
        }
        // Full-screen windows live in their own Space. Setting alphaValue 0 on
        // one reveals the empty Space behind it, not the app the user is
        // dragging to — the intended drop target lives in a DIFFERENT Space
        // entirely, so the gesture cannot work, and the editor appears to have
        // vanished (reads as a crash). Skip arming a peek session for it. This
        // must come after the reentrancy restore above (so a stranded prior
        // window still gets cleaned up) but before adopting the new window.
        guard !window.styleMask.contains(.fullScreen) else { return }
        self.window = window
        state.begin(windowWasVisible: window.isVisible)
        timer?.invalidate()
        // .common mode so it keeps firing inside the drag tracking loop.
        let t = Timer(timeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated { DragPeekController.shared.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Call from `draggingSession(_:endedAt:operation:)`. Runs on EVERY
    /// termination — dropped, refused, or Esc-cancelled — which is why Esc needs
    /// no handling of its own.
    func end() {
        timer?.invalidate()
        timer = nil
        let action = state.end()
        if let window { apply(action, to: window) }
        window = nil
    }

    private func tick() {
        guard let window else { return }
        let held = NSEvent.modifierFlags.contains(.control)
        let buttonDown = NSEvent.pressedMouseButtons != 0
        let action = state.update(modifierHeld: held, anyMouseButtonDown: buttonDown)
        apply(action, to: window)
        // Tear down whenever the button is up, regardless of what action came
        // back. `state.update` returns `.none` (not `.restore`) whenever the
        // window was never hidden in the first place — e.g. the button comes
        // up without the modifier ever having been held, or (unverified but
        // possible) `NSEvent.pressedMouseButtons` reads 0 mid-drag. Gating
        // teardown on `.restore` left the timer firing at 20Hz forever and
        // `self.window` stranded set, which made the NEXT begin() take the
        // reentrancy path and raise the editor unexpectedly at drag start.
        if !buttonDown {
            timer?.invalidate()
            timer = nil
            self.window = nil
        }
    }

    /// Belt and braces: activation can never leave an invisible main window.
    /// Goes through `state.forceVisible()` (not a blind `apply(.restore:)`) so
    /// the model stays in sync — otherwise `state.isHidden` would still read
    /// true after this, and the next tick's steady-state check would refuse
    /// to re-hide the window even with ⌃ still held.
    private func forceRestore() {
        guard let window else { return }
        let action = state.forceVisible()
        apply(action, to: window)
    }

    private func apply(_ action: DragPeekState.Action, to window: NSWindow) {
        switch action {
        case .none:
            return
        case .hide:
            window.alphaValue = 0
            window.ignoresMouseEvents = true    // let drops fall through
        case .restore:
            window.alphaValue = 1
            window.ignoresMouseEvents = false
            // REQUIRED. While hidden the pointer falls through, the app beneath
            // takes activation, and its window rises above ours. Restoring alpha
            // alone brings the editor back BURIED — measured occluded for 4+
            // seconds with no recovery. Mirrors restoreAfterCapture().
            window.orderFrontRegardless()
        }
    }

    /// Test seam — exercises `apply` without a drag session.
    func applyForTesting(_ action: DragPeekState.Action, to window: NSWindow) {
        apply(action, to: window)
    }
}
