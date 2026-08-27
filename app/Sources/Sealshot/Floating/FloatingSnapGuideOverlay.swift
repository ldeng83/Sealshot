import AppKit

/// Draws the guide lines. Full-bleed across the screen so the edge the panel is
/// about to align to is obvious at a glance, rather than a hint you have to be
/// looking at the panel to notice.
final class FloatingSnapGuideView: NSView {

    static let lineWidth: CGFloat = 2

    /// Screen-local positions. Nil means that axis will not snap.
    var verticalX: CGFloat?
    var horizontalY: CGFloat?

    override var isFlipped: Bool { false }

    /// The overlay must never intercept the drag it is describing.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemGreen.withAlphaComponent(0.9).setFill()
        let half = Self.lineWidth / 2
        if let x = verticalX {
            NSRect(x: x - half, y: bounds.minY, width: Self.lineWidth, height: bounds.height)
                .fill()
        }
        if let y = horizontalY {
            NSRect(x: bounds.minX, y: y - half, width: bounds.width, height: Self.lineWidth)
                .fill()
        }
    }
}

/// A click-through overlay that previews where the floating panel will land
/// while it is being dragged: a vertical line on the edge it will snap to
/// sideways, a horizontal line on the edge it will snap to vertically, and both
/// when it is heading for a corner.
///
/// Its own window rather than something drawn inside the panel, because the
/// lines have to span the whole screen — far outside the panel's ~120pt bounds.
@MainActor
final class FloatingSnapGuideOverlay {

    private let window: NSPanel
    private let view = FloatingSnapGuideView()

    init() {
        window = NSPanel(contentRect: .zero,
                         styleMask: [.nonactivatingPanel, .borderless],
                         backing: .buffered,
                         defer: false)
        // Above the floating panel, so a guide crossing it stays visible.
        window.level = .floating + 1
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        // Click-through: the pointer is mid-drag on the panel underneath, and
        // this window sits directly under the cursor for most of that drag.
        window.ignoresMouseEvents = true
        window.contentView = view
    }

    /// Show the guides for `screen`. Positions are global; the view converts to
    /// screen-local. Passing neither axis hides the overlay, so callers can
    /// simply forward whatever the snap calculation produced.
    func show(on screen: NSScreen, verticalX: CGFloat?, horizontalY: CGFloat?) {
        guard verticalX != nil || horizontalY != nil else {
            hide()
            return
        }
        let frame = screen.frame
        window.setFrame(frame, display: false)
        view.verticalX = verticalX.map { $0 - frame.minX }
        view.horizontalY = horizontalY.map { $0 - frame.minY }
        view.needsDisplay = true
        window.orderFrontRegardless()
    }

    func hide() {
        window.orderOut(nil)
    }

    var isVisible: Bool { window.isVisible }

    // Test hooks: the drawn positions are the whole behaviour.
    var verticalXForTesting: CGFloat? { view.verticalX }
    var horizontalYForTesting: CGFloat? { view.horizontalY }
}
