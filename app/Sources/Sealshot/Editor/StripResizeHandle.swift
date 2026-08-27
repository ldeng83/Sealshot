import AppKit

/// Thin draggable bar between the zoom/meta row and the recent strip. Dragging
/// it vertically resizes the strip below it: the strip's bottom is pinned, so
/// dragging **up** grows the strip (and scales its thumbnails). The proposed
/// height is reported live via `onDrag`; `onCommit` fires once on mouse-up so
/// the controller can persist. All clamping lives in the controller /
/// `StripHeightPreference`.
final class StripResizeHandle: NSView {

    /// Strip height at drag start. Supplied by the controller.
    var currentHeight: (() -> CGFloat)?
    /// Proposed (unclamped) strip height during the drag.
    var onDrag: ((CGFloat) -> Void)?
    /// Fired once when the drag ends.
    var onCommit: (() -> Void)?

    /// Visual thickness of the bar.
    static let thickness: CGFloat = 7

    private var startHeight: CGFloat = 0
    private var startY: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: Self.thickness).isActive = true
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not implemented") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.thickness)
    }

    // Vertical-resize cursor over the whole bar.
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // Soft gray boundary line across the strip's top edge, matching the
        // sidebar's split-view divider (same system separator color) so the
        // strip reads as a distinct pane. Drawn at the vertical center; the
        // grabber pill sits on top of it, mirroring the sidebar.
        let lineY = (bounds.height - 1) / 2
        NSColor.separatorColor.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: lineY, width: bounds.width, height: 1)).fill()

        // A short centered grabber line hints the bar is draggable.
        let lineWidth: CGFloat = 28
        let rect = NSRect(
            x: (bounds.width - lineWidth) / 2,
            y: (bounds.height - 2) / 2,
            width: lineWidth,
            height: 2
        )
        NSColor.tertiaryLabelColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
    }

    override func mouseDown(with event: NSEvent) {
        startHeight = currentHeight?() ?? 0
        startY = event.locationInWindow.y
    }

    override func mouseDragged(with event: NSEvent) {
        // Window coordinates so the math is immune to the handle moving as the
        // strip resizes mid-drag. Up (y increases) → taller strip.
        let delta = event.locationInWindow.y - startY
        onDrag?(startHeight + delta)
    }

    override func mouseUp(with event: NSEvent) {
        onCommit?()
    }
}
