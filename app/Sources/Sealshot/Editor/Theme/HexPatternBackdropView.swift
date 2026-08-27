import AppKit

/// Fills its bounds with `Theme.backdropColor` and draws a faint hex
/// grid on top. Placed behind the canvas scroll view to create the
/// "warm-gray with hexes" backdrop from the reference.
final class HexPatternBackdropView: NSView {

    /// Distance between hex centers along the horizontal axis. The hex
    /// side length is derived from this.
    static let hexCellSize: CGFloat = 24

    override var isFlipped: Bool { false }

    // Repaint the whole grid on resize (window resize / sidebar toggle) so the
    // bounds-relative pattern stays correct, including when hosted in SwiftUI.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Background fill
        Theme.backdropColor.setFill()
        ctx.fill(bounds)

        // Hex grid stroke
        Theme.hexPatternColor.setStroke()
        ctx.setLineWidth(1.0)

        let s = Self.hexCellSize / 2.0    // hex side length (half the cell size)
        let w = sqrt(3.0) * s              // hex flat-width (point-to-point would be 2s)
        let h = 2.0 * s                    // hex height (point-to-point vertical)
        let rowStep = h * 0.75             // vertical distance between row centers

        var row = 0
        var y = -h
        while y < bounds.height + h {
            let xOffset: CGFloat = (row.isMultiple(of: 2)) ? 0 : w / 2.0
            var x = -w + xOffset
            while x < bounds.width + w {
                drawHex(in: ctx, centerX: x, centerY: y, side: s)
                x += w
            }
            y += rowStep
            row += 1
        }
    }

    /// Draw a single flat-top hexagon centered at (centerX, centerY) with
    /// the given side length.
    private func drawHex(in ctx: CGContext, centerX: CGFloat, centerY: CGFloat, side s: CGFloat) {
        let path = CGMutablePath()
        for i in 0..<6 {
            let angle = (.pi / 3.0) * Double(i) - (.pi / 2.0)   // start at top, go clockwise
            let px = centerX + s * CGFloat(cos(angle))
            let py = centerY + s * CGFloat(sin(angle))
            if i == 0 {
                path.move(to: CGPoint(x: px, y: py))
            } else {
                path.addLine(to: CGPoint(x: px, y: py))
            }
        }
        path.closeSubpath()
        ctx.addPath(path)
        ctx.strokePath()
    }
}
