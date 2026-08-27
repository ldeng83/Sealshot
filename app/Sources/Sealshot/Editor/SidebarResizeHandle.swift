import AppKit

/// Thin draggable bar on the right sidebar's leading edge. Dragging it
/// horizontally resizes the sidebar: the sidebar's trailing edge is pinned, so
/// dragging **left** widens it. The proposed width is reported live via
/// `onDrag`; `onCommit` fires once on mouse-up so the controller can persist.
/// Clamping lives in the controller / `SidebarWidthPreference`.
///
/// This deliberately drives a width constraint directly rather than relying on
/// the `NSSplitView` divider, which does not resize reliably when its panes are
/// governed by autolayout width constraints.
final class SidebarResizeHandle: NSView {

    /// Sidebar width at drag start. Supplied by the controller.
    var currentWidth: (() -> CGFloat)?
    /// Proposed (unclamped) sidebar width during the drag.
    var onDrag: ((CGFloat) -> Void)?
    /// Fired once when the drag ends.
    var onCommit: (() -> Void)?

    /// Hit-test (clickable/draggable) thickness of the bar. Wider than the
    /// drawn grabber so the edge is easy to grab; the visible grabber line stays
    /// thin and centered. Sits within the sidebar's leading margin, so it never
    /// overlaps panel content.
    static let thickness: CGFloat = 12

    private var startWidth: CGFloat = 0
    private var startX: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: Self.thickness).isActive = true
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not implemented") }

    // Horizontal-resize cursor over the whole bar.
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // A short centered grabber hints the leading edge is draggable.
        let lineHeight: CGFloat = 28
        let rect = NSRect(
            x: (bounds.width - 2) / 2,
            y: (bounds.height - lineHeight) / 2,
            width: 2,
            height: lineHeight
        )
        NSColor.tertiaryLabelColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
    }

    override func mouseDown(with event: NSEvent) {
        startWidth = currentWidth?() ?? 0
        startX = event.locationInWindow.x
    }

    override func mouseDragged(with event: NSEvent) {
        // Window coordinates so the math is immune to the handle moving as the
        // sidebar resizes mid-drag. Left (x decreases) → wider sidebar.
        let delta = startX - event.locationInWindow.x
        onDrag?(startWidth + delta)
    }

    override func mouseUp(with event: NSEvent) {
        onCommit?()
    }
}
