import AppKit

/// Compact color swatch shown in a panel row. Click opens the color palette in
/// a popover. `color == nil` shows a "None" state (used by fill). Reports the
/// chosen color via `onPick` (nil = no color); also keeps its own swatch in
/// sync. `onSessionStart` fires once when the popover opens (for undo grouping).
final class ColorChipButton: NSView {
    var color: NSColor? { didSet { needsDisplay = true } }
    var allowsNoColor = false
    var onPick: ((NSColor?) -> Void)?
    var onSessionStart: (() -> Void)?

    /// Number of color palettes currently open (app-wide). The sidebar skips
    /// rebuilds while > 0 so a color/property change inside the palette doesn't
    /// tear down the chip that anchors the popover (which would dismiss it). In
    /// practice only ever 0 or 1 — a transient popover closes when another opens.
    static private(set) var openPaletteCount = 0

    private var popover: NSPopover?

    init(color: NSColor?, allowsNoColor: Bool) {
        self.color = color
        self.allowsNoColor = allowsNoColor
        super.init(frame: NSRect(x: 0, y: 0, width: 44, height: 24))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 44).isActive = true
        heightAnchor.constraint(equalToConstant: 24).isActive = true
        toolTip = "Choose color"
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
        if let color = color {
            color.setFill(); path.fill()
        } else {
            NSColor(white: 0.23, alpha: 1).setFill(); path.fill()
            let slash = NSBezierPath()
            slash.move(to: NSPoint(x: r.minX + 6, y: r.minY + 6))
            slash.line(to: NSPoint(x: r.maxX - 6, y: r.maxY - 6))
            NSColor.systemRed.setStroke(); slash.lineWidth = 2; slash.stroke()
        }
        // Border that CONTRASTS with the panel (labelColor is dark in light mode,
        // light in dark mode), so a white/near-panel swatch still reads as a
        // button instead of blending into the background.
        NSColor.labelColor.withAlphaComponent(0.35).setStroke(); path.lineWidth = 1; path.stroke()
    }

    override func mouseDown(with event: NSEvent) { openPopover() }

    private func openPopover() {
        guard popover == nil else { return }
        onSessionStart?()
        let controller = ColorPalettePopoverController(
            allowsNoColor: allowsNoColor, current: color
        ) { [weak self] picked in
            self?.color = picked
            self?.onPick?(picked)
        }
        controller.onDismiss = { [weak self] in self?.popover?.close() }
        let pop = NSPopover()
        pop.behavior = .transient
        pop.delegate = self
        pop.contentViewController = controller
        ColorChipButton.openPaletteCount += 1
        pop.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
        popover = pop
    }
}

extension ColorChipButton: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        guard popover != nil else { return }
        popover = nil
        ColorChipButton.openPaletteCount = max(0, ColorChipButton.openPaletteCount - 1)
        // Suppression is lifted — rebuild the sidebar once so it reflects any
        // changes made while the palette was open (the chip's own color already
        // updated live). Walk up to the sidebar that hosts this chip.
        var v: NSView? = superview
        while let cur = v {
            if let sidebar = cur as? EditorSidebarView { sidebar.rebuildAfterPaletteClose(); break }
            v = cur.superview
        }
    }
}
