import AppKit
import ScreenCaptureKit
import os.log

private let pickerDebugLog = OSLog(subsystem: "com.seal-shot.sealshot", category: "picker-debug")

/// One per `WindowPickerPanel`. Draws a 3pt outline around the window under
/// the cursor and reports user actions (click, Esc, right-click) via
/// callbacks. The controller owns the SCK fetch and pushes the current
/// candidate list to all views via `setCandidates(_:)`.
final class WindowHighlightView: NSView {
    /// Fires once on left-click with the highlighted window, or `nil` if the
    /// cursor isn't over any candidate (in which case the picker stays up —
    /// the controller decides what to do).
    var onClick: ((SCWindow?) -> Void)?

    /// Fires on Esc or right-click. Picker session ends.
    var onCancel: (() -> Void)?

    /// Fires when the user presses spacebar to cycle back to the region overlay.
    var onSpacebar: (() -> Void)?

    private var candidates: [SCWindow] = []
    private var highlighted: SCWindow?
    /// Latest cursor location (view-local) for the crosshair; nil when the
    /// cursor is on another display's panel.
    private var mousePoint: CGPoint?

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    /// Capture is often triggered by a global hotkey while another app is
    /// active — without this, AppKit withholds the first click as an
    /// activation click and the user's first drag selects nothing.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func setCandidates(_ windows: [SCWindow]) {
        self.candidates = windows
        recomputeHighlight()
    }

    /// Called by the controller's local `.mouseMoved` event monitor.
    /// `mouseMoved(with:)` requires a tracking area + active-window status
    /// that a borderless nonactivating panel can't reliably provide.
    func handleMouseMoved() {
        recomputeHighlight()
    }

    private func drawDimAndHighlight() {
        // Heavy dim so the cutout over the highlighted window is sharply
        // contrasted against the rest of the screen.
        NSColor.black.withAlphaComponent(0.5).setFill()
        bounds.fill()

        guard let target = highlighted, let win = window, let screen = win.screen else { return }

        // Convert SCWindow frame (global, top-left origin) to view-local
        // (window-local, bottom-left origin since isFlipped=false).
        let global = target.frame
        let viewLocalY = screen.frame.height - (global.origin.y - screen.frame.origin.y) - global.height
        let local = CGRect(
            x: global.origin.x - screen.frame.origin.x,
            y: viewLocalY,
            width: global.width,
            height: global.height
        )

        // Cut a transparent hole so users can see the highlighted window cleanly.
        NSGraphicsContext.current?.compositingOperation = .clear
        local.fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver

        // Bold glowing border (shared with the ⌘⇧C unified hover so both
        // capture modes show an identical highlight ring).
        WindowHighlightStyle.strokeHighlight(local)
    }

    override func draw(_ dirtyRect: NSRect) {
        drawDimAndHighlight()
        if let p = mousePoint, bounds.contains(p) {
            let scale = window?.backingScaleFactor ?? 1.0
            CrosshairRender.draw(
                at: p, in: bounds,
                primary: CrosshairRender.coordsText(
                    point: p, viewHeight: bounds.height, scale: scale),
                hints: CrosshairRender.Hints.windowPick,
                loupeImage: nil)   // click target is a whole window — no loupe
        }
    }

    override func mouseMoved(with event: NSEvent) {
        recomputeHighlight()
    }

    override func mouseDown(with event: NSEvent) {
        onClick?(highlighted)
    }

    override func rightMouseDown(with event: NSEvent) {
        onCancel?()
    }

    override func keyDown(with event: NSEvent) {
        // keyCode 49 = Space
        if event.keyCode == 49 {
            onSpacebar?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func resetCursorRects() {
        // The view draws its own crosshair; hide the system cursor.
        addCursorRect(bounds, cursor: CrosshairRender.transparentCursor)
    }

    private func recomputeHighlight() {
        let mouseGlobal = NSEvent.mouseLocation

        // Track the cursor for the crosshair (view-local; nil off-screen).
        if let screen = window?.screen {
            let local = CGPoint(x: mouseGlobal.x - screen.frame.minX,
                                y: mouseGlobal.y - screen.frame.minY)
            mousePoint = bounds.contains(local) ? local : nil
            needsDisplay = true
        }
        // SCWindow.frame is in global coords, top-left origin (Quartz).
        // NSEvent.mouseLocation is global, bottom-left origin (AppKit).
        // The y-flip anchor is the screen whose origin is (0,0) — i.e., the
        // display defining the global coordinate origin.
        let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero })
            ?? NSScreen.screens.first
        guard let primary else {
            highlighted = nil
            needsDisplay = true
            return
        }
        let mouseQuartz = CGPoint(
            x: mouseGlobal.x,
            y: primary.frame.height - mouseGlobal.y
        )
        // Topmost-first: rely on SCK's z-order (front to back).
        let hit = candidates.first(where: { $0.frame.contains(mouseQuartz) })
        if hit?.windowID != highlighted?.windowID {
            // Debug logging — captures the cursor position, the chosen
            // window's title/app/frame, plus every candidate that contained
            // the cursor (so we can see why z-order picked what it did).
            let containing = candidates.filter { $0.frame.contains(mouseQuartz) }
            os_log(
                "picker hit @ (%.0f,%.0f) → chose '%{public}@' (%{public}@) frame=%{public}@ layer=%d. %d candidates contain cursor:",
                log: pickerDebugLog, type: .info,
                mouseQuartz.x, mouseQuartz.y,
                hit?.title ?? "<nil>",
                hit?.owningApplication?.bundleIdentifier ?? "<nil>",
                String(describing: hit?.frame ?? .zero),
                hit?.windowLayer ?? -1,
                containing.count
            )
            for (idx, w) in containing.enumerated() {
                os_log(
                    "  [%d] '%{public}@' app=%{public}@ frame=%{public}@ layer=%d onScreen=%d",
                    log: pickerDebugLog, type: .info,
                    idx,
                    w.title ?? "<nil>",
                    w.owningApplication?.bundleIdentifier ?? "<nil>",
                    String(describing: w.frame),
                    w.windowLayer,
                    w.isOnScreen ? 1 : 0
                )
            }
            highlighted = hit
            needsDisplay = true
        }
    }
}
