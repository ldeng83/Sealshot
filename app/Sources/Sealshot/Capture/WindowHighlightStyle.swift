import AppKit

/// Shared visual treatment for the "window under the cursor" highlight used by
/// both capture modes — the unified overlay (⌘⇧C) and the window picker (⌘⇧W).
///
/// Draws a bold accent border with a soft accent-colored glow halo around the
/// window rect. No fill and no screen dim: callers are responsible for any dim
/// or cutout drawn beneath (the picker dims + cuts a hole; the unified hover
/// leaves the live desktop bright). Centralizing the ring keeps the two modes
/// visually identical.
enum WindowHighlightStyle {
    /// Bright capture-blue (#4A9EFF) used for the border and the glow.
    static let accentColor = NSColor(red: 0x4A/255.0, green: 0x9E/255.0, blue: 0xFF/255.0, alpha: 1.0)

    /// Border thickness. Bold enough to read clearly against any wallpaper.
    static let borderWidth: CGFloat = 4

    /// Stroke a bold accent border + glow halo around `rect` (a view-local
    /// window frame). Saves/restores graphics state so the glow shadow doesn't
    /// leak into later drawing.
    static func strokeHighlight(_ rect: CGRect) {
        guard let ctx = NSGraphicsContext.current else { return }
        ctx.saveGraphicsState()

        // Soft halo, drawn behind the crisp stroke in the same pass.
        let glow = NSShadow()
        glow.shadowColor = accentColor.withAlphaComponent(0.9)
        glow.shadowBlurRadius = 12
        glow.shadowOffset = .zero
        glow.set()

        accentColor.setStroke()
        // Inset by half the line width so the stroke sits centered on the
        // window edge rather than straddling outside it.
        let path = NSBezierPath(rect: rect.insetBy(dx: borderWidth / 2, dy: borderWidth / 2))
        path.lineWidth = borderWidth
        path.stroke()

        ctx.restoreGraphicsState()
    }
}
