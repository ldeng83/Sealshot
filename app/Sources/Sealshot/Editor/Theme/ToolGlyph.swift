import AppKit

/// Glyph images for editor toolbar tools. Most tools use SF Symbols by name;
/// the Free Arrow uses a custom-drawn loop-de-loop (no stock symbol matches), so
/// callers route through here instead of `NSImage(systemSymbolName:)` directly.
enum ToolGlyph {

    /// Sentinel "symbol" name that maps to the drawn Free-Arrow loop instead of
    /// an SF Symbol. Stored as a `ToolGroup.Member.symbol` like any other name.
    static let freeArrow = "sealshot.freeArrow"

    /// The glyph for a tool `symbol` at `pointSize`/`weight`: the drawn Free-Arrow
    /// loop for the sentinel, otherwise the named SF Symbol. Both come back as
    /// template images that tint to the image view's `contentTintColor`.
    static func image(_ symbol: String, pointSize: CGFloat,
                      weight: NSFont.Weight = .medium) -> NSImage? {
        if symbol == freeArrow {
            return freeArrowImage(pointSize: pointSize, bold: weight == .semibold)
        }
        let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        return NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
    }

    /// A template image of the Free-Arrow icon: a flowing loop-de-loop whose arrow
    /// flings out to the upper-right (~38°). Sized to sit like an SF Symbol of
    /// `pointSize`.
    static func freeArrowImage(pointSize: CGFloat, bold: Bool = false) -> NSImage {
        let side = max(12, (pointSize * 1.34).rounded())
        let img = NSImage(size: NSSize(width: side, height: side))
        img.lockFocus()

        let pts = loopPoints()
        // Fit to the box (padding), flipping y so "up" in the design points up in
        // the bottom-left NSImage space (arrow ends upper-right).
        let pad = side * 0.15
        let xs = pts.map(\.x), ys = pts.map(\.y)
        let minx = xs.min()!, maxx = xs.max()!, miny = ys.min()!, maxy = ys.max()!
        let w = maxx - minx, h = maxy - miny
        let s = (side - 2 * pad) / max(w, h)
        let ox = (side - w * s) / 2 - minx * s
        let oy = (side - h * s) / 2 - miny * s
        let mapped = pts.map { CGPoint(x: $0.x * s + ox, y: side - ($0.y * s + oy)) }

        let stroke = max(1.3, pointSize * (bold ? 0.10 : 0.082))
        NSColor.black.setStroke()
        NSColor.black.setFill()

        let path = NSBezierPath()
        path.lineWidth = stroke
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: mapped[0])
        for p in mapped.dropFirst() { path.line(to: p) }
        path.stroke()

        drawArrowhead(tip: mapped[mapped.count - 1], back: mapped[mapped.count - 7], width: stroke)

        img.unlockFocus()
        img.isTemplate = true
        return img
    }

    /// Prolate-cycloid loop (option E: d=2.2, rotated −60°, long lead-in tail).
    /// Screen convention (y grows downward) — the caller flips y when drawing.
    private static func loopPoints() -> [CGPoint] {
        let R = 1.0, d = 2.2, t0 = -3.4, t1 = 2.8
        let rot = -60.0 * Double.pi / 180
        let cR = cos(rot), sR = sin(rot)
        let steps = 120
        var pts: [CGPoint] = []
        for i in 0...steps {
            let t = t0 + (t1 - t0) * Double(i) / Double(steps)
            let x = R * t - d * sin(t)
            let y = -d * cos(t)
            pts.append(CGPoint(x: x * cR - y * sR, y: x * sR + y * cR))
        }
        return pts
    }

    /// A filled triangle head at `tip`, pointing along `tip − back`.
    private static func drawArrowhead(tip: CGPoint, back: CGPoint, width: CGFloat) {
        let dx = tip.x - back.x, dy = tip.y - back.y
        let len = max(hypot(dx, dy), 0.001)
        let dir = CGVector(dx: dx / len, dy: dy / len)
        let perp = CGVector(dx: -dir.dy, dy: dir.dx)
        let headLen = max(width * 2.8, 4.0)
        let halfW = max(width * 1.7, 2.4)
        let base = CGPoint(x: tip.x - dir.dx * headLen, y: tip.y - dir.dy * headLen)
        let a = CGPoint(x: base.x + perp.dx * halfW, y: base.y + perp.dy * halfW)
        let b = CGPoint(x: base.x - perp.dx * halfW, y: base.y - perp.dy * halfW)
        let tri = NSBezierPath()
        tri.move(to: tip); tri.line(to: a); tri.line(to: b); tri.close()
        tri.fill()
    }
}
