import AppKit

final class SelectionView: NSView {
    /// Called once when the user completes or cancels the selection.
    /// `nil` means cancel (Esc, right-click, zero-area, click-without-drag).
    var onComplete: ((CGRect?) -> Void)?

    /// Called when the user presses spacebar to cycle to the next capture
    /// mode. Fires whether or not a drag is in progress — any active drag
    /// is cancelled by the time this callback runs.
    var onSpacebarCycle: (() -> Void)?

    /// Per-mode hint lines for the crosshair badge (scroll vs. region vs.
    /// save-as), set by the controller before the panel shows.
    var hintLines: [String] = CrosshairRender.Hints.region

    /// Frozen pixels feeding the loupe; nil hides the loupe (grab still
    /// pending or failed — never blocks the session).
    var loupeImage: CGImage? {
        didSet { needsDisplay = true }
    }

    private var dragStart: CGPoint?
    private var currentRect: CGRect = .zero
    /// Latest cursor location (view-local) for the crosshair; nil when the
    /// cursor is on another display's panel.
    private var mousePoint: CGPoint?
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    /// Capture is often triggered by a global hotkey while another app is
    /// active — without this, AppKit withholds the first click as an
    /// activation click and the user's first drag selects nothing.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.3).setFill()
        bounds.fill()

        if !currentRect.isEmpty {
            // Cut a transparent hole for the selected region.
            NSGraphicsContext.current?.compositingOperation = .clear
            currentRect.fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver

            // Crisp border.
            NSColor.white.setStroke()
            let path = NSBezierPath(rect: currentRect)
            path.lineWidth = 2
            path.stroke()
        }

        guard let point = mousePoint, bounds.contains(point) else { return }
        // The overlay uses NSScreen.backingScaleFactor because no SCContentFilter
        // (whose pointPixelScale the capture core uses) exists until capture time;
        // on a single display the two agree, so the shown size matches the PNG.
        let scale = window?.backingScaleFactor ?? 1.0
        let primary: String
        let hints: [String]
        if dragStart != nil, !currentRect.isEmpty {
            let ppi = window?.screen.map(DisplayMetrics.ppi(of:)) ?? 0
            primary = CrosshairRender.dimensionsText(rect: currentRect, scale: scale, ppi: ppi)
            hints = []
        } else {
            primary = CrosshairRender.coordsText(
                point: point, viewHeight: bounds.height, scale: scale)
            hints = hintLines
        }
        CrosshairRender.draw(at: point, in: bounds,
                             primary: primary, hints: hints, loupeImage: loupeImage)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        dragStart = point
        mousePoint = point
        currentRect = .zero
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let current = convert(event.locationInWindow, from: nil)
        mousePoint = current
        let raw = CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
        currentRect = CoordinateMath.clampToBounds(raw, bounds: bounds)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStart != nil else { return }
        dragStart = nil

        if currentRect.isEmpty {
            onComplete?(nil)
            return
        }
        let windowRect = convert(currentRect, to: nil)
        let globalRect = window?.convertToScreen(windowRect) ?? .zero
        onComplete?(globalRect)
    }

    override func rightMouseDown(with event: NSEvent) {
        onComplete?(nil)
    }

    override func keyDown(with event: NSEvent) {
        // keyCode 53 = Esc, keyCode 49 = Space
        if event.keyCode == 53 {
            onComplete?(nil)
        } else if event.keyCode == 49 {
            // Space — cycle to next mode. Cancel any in-progress drag.
            dragStart = nil
            currentRect = .zero
            needsDisplay = true
            onSpacebarCycle?()
        } else {
            super.keyDown(with: event)
        }
    }

    // MARK: - Cursor + crosshair tracking (same pattern as UnifiedSelectionView)

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { CrosshairRender.transparentCursor.set() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .cursorUpdate],
            owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingArea = t
    }

    override func mouseMoved(with event: NSEvent) {
        mousePoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func cursorUpdate(with event: NSEvent) {
        CrosshairRender.transparentCursor.set()
    }

    override func mouseExited(with event: NSEvent) {
        guard mousePoint != nil else { return }
        mousePoint = nil
        needsDisplay = true
    }
}
