import AppKit

/// Draws the magnifier loupe: a circular, nearest-neighbor zoom of the frozen
/// frame around the cursor, with faint center guides, a hovered-pixel tick,
/// and a white ring. Pixel mapping reuses `FrozenFrameCrop` so the loupe shows
/// exactly the pixels a capture would take.
@MainActor
enum LoupeRenderer {

    /// `frame` is the loupe's circle bounding box (view coords); `focus` the
    /// cursor position the loupe magnifies. Near screen edges the magnified
    /// region shifts to stay on-image (`loupeSourceViewRect`), so the focus
    /// pixel can sit slightly off the loupe center there — accepted for v1.
    static func draw(source: CGImage, in frame: CGRect, focus: CGPoint, viewBounds: CGRect) {
        let sourceView = CrosshairGeometry.loupeSourceViewRect(
            center: focus, zoom: CrosshairRender.loupeZoom,
            diameter: frame.width, in: viewBounds)
        guard let crop = FrozenFrameCrop.crop(source, viewLocal: sourceView,
                                              viewSize: viewBounds.size),
              let ctx = NSGraphicsContext.current?.cgContext else { return }

        ctx.saveGState()
        NSBezierPath(ovalIn: frame).addClip()
        ctx.interpolationQuality = .none
        ctx.draw(crop, in: frame)

        // Faint guides through the loupe center + the hovered-pixel tick.
        let guide = NSColor.white.withAlphaComponent(0.35)
        guide.setFill()
        CGRect(x: frame.minX, y: frame.midY - 0.5, width: frame.width, height: 1).fill()
        CGRect(x: frame.midX - 0.5, y: frame.minY, width: 1, height: frame.height).fill()
        let tick = CGRect(x: frame.midX - 2.5, y: frame.midY - 2.5, width: 5, height: 5)
        let tickPath = NSBezierPath(rect: tick)
        NSColor.black.withAlphaComponent(0.6).setStroke()
        tickPath.lineWidth = 3
        tickPath.stroke()
        NSColor.white.setStroke()
        tickPath.lineWidth = 1
        tickPath.stroke()
        ctx.restoreGState()

        // White ring with a dark outer hairline so the loupe edge reads on
        // light and dark content alike.
        let ring = NSBezierPath(ovalIn: frame.insetBy(dx: 1, dy: 1))
        NSColor.white.withAlphaComponent(0.9).setStroke()
        ring.lineWidth = 2
        ring.stroke()
        let outer = NSBezierPath(ovalIn: frame)
        NSColor.black.withAlphaComponent(0.5).setStroke()
        outer.lineWidth = 1
        outer.stroke()
    }
}
