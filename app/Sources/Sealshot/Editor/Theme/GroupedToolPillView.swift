import AppKit

/// A toolbar pill that fronts a small group of related tools (Line / Arrow).
///
/// It mirrors the last-used sub-tool's icon (driven by the builder via
/// `setBaseSymbol`) and draws a downward chevron affordance in the bottom-right
/// corner to signal "more inside". Interaction:
///   • a plain click anywhere → `onActivateCurrent` (re-arm the last sub-tool),
///   • a click on the chevron corner, or a long-press anywhere → `onOpenMenu`
///     (show the Line/Arrow chooser).
/// Subclassed by `DelayedCapturePill` (reuses the chevron chooser), so not final.
class GroupedToolPillView: ActiveToolPillView {

    /// Side length (pts) of the bottom-right hit zone reserved for the chevron.
    private static let menuZone: CGFloat = 13
    private static let longPressDelay: TimeInterval = 0.4

    var onActivateCurrent: (() -> Void)?
    var onOpenMenu: (() -> Void)?

    private var longPressWork: DispatchWorkItem?
    /// Set once a press has been handled as a menu open, so the matching
    /// `mouseUp` doesn't also fire `onActivateCurrent`.
    private var menuHandled = false

    /// True when `point` (view coordinates) falls in the chevron affordance
    /// zone. The view is unflipped, so the corner sits at low y / high x.
    static func isMenuRegion(_ point: NSPoint, in bounds: NSRect) -> Bool {
        point.x >= bounds.maxX - menuZone && point.y <= bounds.minY + menuZone
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)   // active-state background, if any
        drawChevron()
    }

    /// Extra downward nudge for the chevron so it clears the tool icon.
    /// Subclasses with larger glyphs (DelayedCapturePill) push it further.
    var chevronDownNudge: CGFloat { 2 }

    private func drawChevron() {
        let half: CGFloat = 3.2          // half-width of the chevron
        let inset: CGFloat = 4.5
        let cx = bounds.maxX - inset - half
        let cy = bounds.minY + inset - chevronDownNudge
        let path = NSBezierPath()
        path.move(to: NSPoint(x: cx - half, y: cy + half * 0.85))
        path.line(to: NSPoint(x: cx, y: cy))
        path.line(to: NSPoint(x: cx + half, y: cy + half * 0.85))
        path.lineWidth = 1.3
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        (isActive ? Theme.accentColor : NSColor.secondaryLabelColor).setStroke()
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        InstantTooltip.shared.hide()
        menuHandled = false
        let point = convert(event.locationInWindow, from: nil)
        if Self.isMenuRegion(point, in: bounds) {
            menuHandled = true
            onOpenMenu?()
            return
        }
        // Long-press anywhere on the pill also opens the chooser.
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.menuHandled = true
            self.onOpenMenu?()
        }
        longPressWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.longPressDelay, execute: work)
    }

    override func mouseUp(with event: NSEvent) {
        longPressWork?.cancel()
        longPressWork = nil
        if menuHandled {
            menuHandled = false
            return
        }
        onActivateCurrent?()
    }
}
