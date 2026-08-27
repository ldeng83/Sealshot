import AppKit
import CoreGraphics
import Foundation

/// Shared geometry + drawing for line/arrow "connectors", used by both the
/// saved-image renderer (`AnnotationRenderer`) and the live drag preview
/// (`EditorCanvasView`) so what you drag is exactly what gets committed.
///
/// This file holds the pure, unit-tested geometry (`dashPattern`, `capGeometry`).
/// The AppKit drawing entry point (`drawConnector`) lives alongside it.

// MARK: - Dash patterns

/// The `[on, off, …]` dash array for a shaft `style` at `width`, or `nil` for a
/// solid (undashed) stroke. Lengths scale with the stroke width so the rhythm
/// looks consistent at any thickness. Dotted styles are meant to be stroked with
/// a round line cap (decided by the caller) so the short on-segments read as dots.
func dashPattern(_ style: DashStyle, width: CGFloat) -> [CGFloat]? {
    let w = max(width, 0.5)
    switch style {
    case .solid:        return nil
    case .dashed:       return [3 * w, 3 * w]
    case .dotted:       return [w, 2 * w]
    case .sparseDotted: return [w, 5 * w]
    }
}

// MARK: - End caps

/// The drawable shape of one arrow terminator, resolved in the same coordinate
/// space as the connector's endpoints.
enum CapShape: Equatable {
    /// Bare end — nothing to draw.
    case none
    /// Solid triangle; the points are `[apex, baseCornerA, baseCornerB]`, filled.
    case filledTriangle([CGPoint])
    /// Stroked V (barbs): two segments `apex→left` and `apex→right`.
    case openBarbs(apex: CGPoint, left: CGPoint, right: CGPoint)
    /// Filled disc centred on the tip.
    case dot(center: CGPoint, radius: CGFloat)
    /// Stroked perpendicular tee between the two points.
    case bar(CGPoint, CGPoint)
}

/// The cap shape for `cap` placed at `tip`, where `direction` points *outward*
/// along the shaft toward the tip (need not be unit length). Sizes scale with
/// the stroke `width` and mirror the head proportions used historically.
func capGeometry(_ cap: ArrowCap, tip: CGPoint,
                 direction: CGVector, width: CGFloat) -> CapShape {
    if cap == .none { return .none }

    let len = max(hypot(direction.dx, direction.dy), 0.0001)
    let dir = CGVector(dx: direction.dx / len, dy: direction.dy / len)
    let perp = CGVector(dx: -dir.dy, dy: dir.dx)

    let headLen = max(14, width * 2.6)
    let halfW = max(7, width * 1.7)
    let dotRadius = max(4, width * 1.5)

    func point(_ base: CGPoint, _ v: CGVector, _ s: CGFloat) -> CGPoint {
        CGPoint(x: base.x + v.dx * s, y: base.y + v.dy * s)
    }
    let baseCenter = point(tip, dir, -headLen)
    let cornerA = point(baseCenter, perp, halfW)
    let cornerB = point(baseCenter, perp, -halfW)

    switch cap {
    case .none:   return .none
    case .filled: return .filledTriangle([tip, cornerA, cornerB])
    case .open:   return .openBarbs(apex: tip, left: cornerA, right: cornerB)
    case .dot:    return .dot(center: tip, radius: dotRadius)
    case .bar:    return .bar(point(tip, perp, halfW), point(tip, perp, -halfW))
    }
}

/// How far the shaft retreats from an endpoint so a filled head doesn't show a
/// notch where the line pokes through it. Only `.filled` consumes shaft length.
func capShaftInset(_ cap: ArrowCap, width: CGFloat) -> CGFloat {
    cap == .filled ? max(14, width * 2.6) * 0.6 : 0
}


// MARK: - Tapered shaft

/// Full widths at the two endpoints of a tapered shaft. The wide end is the
/// one carrying the arrow's single cap; with both ends capped (or neither),
/// the START is wide — the user-chosen rule for double-headed arrows. The wide
/// end draws at 1.5× the nominal stroke width so a tapered arrow keeps the
/// visual weight of its uniform sibling; the narrow end is 30% of that,
/// floored so thin arrows don't vanish.
func taperedWidths(nominalWidth: CGFloat, startCap: ArrowCap,
                   endCap: ArrowCap) -> (atStart: CGFloat, atEnd: CGFloat) {
    let wide = nominalWidth * 1.5
    let narrow = max(1.5, wide * 0.3)
    let wideAtEnd = endCap != .none && startCap == .none
    return wideAtEnd ? (narrow, wide) : (wide, narrow)
}

/// The filled quads of a tapered shaft: one trapezoid when solid, one per dash
/// on-run when dashed. The width interpolates linearly over the FULL start→end
/// axis, so cap insets trim length without changing the profile, and dashed
/// segments are genuinely tapered trapezoids rather than uniform dashes.
func taperedShaftQuads(from start: CGPoint, to end: CGPoint,
                       widthAtStart: CGFloat, widthAtEnd: CGFloat,
                       insetStart: CGFloat, insetEnd: CGFloat,
                       dash: [CGFloat]?) -> [[CGPoint]] {
    let dxv = end.x - start.x, dyv = end.y - start.y
    let len = hypot(dxv, dyv)
    guard len > 0.01 else { return [] }
    let dir = CGVector(dx: dxv / len, dy: dyv / len)
    let perp = CGVector(dx: -dir.dy, dy: dir.dx)
    let lo = min(max(0, insetStart), len)
    let hi = max(lo, len - max(0, insetEnd))
    guard hi - lo > 0.01 else { return [] }

    func halfWidth(_ t: CGFloat) -> CGFloat {
        (widthAtStart + (widthAtEnd - widthAtStart) * (t / len)) / 2
    }
    func station(_ t: CGFloat, _ side: CGFloat) -> CGPoint {
        let w = halfWidth(t) * side
        return CGPoint(x: start.x + dir.dx * t + perp.dx * w,
                       y: start.y + dir.dy * t + perp.dy * w)
    }

    var runs: [(CGFloat, CGFloat)] = []
    if let dash, dash.count >= 2 {
        var t = lo, i = 0
        while t < hi {
            let t2 = min(t + dash[i % dash.count], hi)
            if i % 2 == 0, t2 - t > 0.01 { runs.append((t, t2)) }
            t = t2
            i += 1
        }
    } else {
        runs = [(lo, hi)]
    }
    return runs.map { a, b in
        [station(a, 1), station(b, 1), station(b, -1), station(a, -1)]
    }
}

/// Draw a tapered connector: filled shaft quads plus caps sized to the LOCAL
/// shaft width at their end — so a single head sits on the wide end at full
/// size, and a double-headed arrow gets a large head at the wide start and a
/// smaller one at the narrow end.
private func drawTaperedConnector(from start: CGPoint, to end: CGPoint,
                                  width: CGFloat, color: NSColor, dash: DashStyle,
                                  startCap: ArrowCap, endCap: ArrowCap,
                                  outlineColor: NSColor?, outlineWidth: CGFloat) {
    let dxv = end.x - start.x, dyv = end.y - start.y
    let len = hypot(dxv, dyv)
    guard len > 0.01 else { return }
    let dir = CGVector(dx: dxv / len, dy: dyv / len)
    let outAtStart = CGVector(dx: -dir.dx, dy: -dir.dy)

    let (wS, wE) = taperedWidths(nominalWidth: width, startCap: startCap, endCap: endCap)
    let quads = taperedShaftQuads(
        from: start, to: end, widthAtStart: wS, widthAtEnd: wE,
        insetStart: capShaftInset(startCap, width: wS),
        insetEnd: capShaftInset(endCap, width: wE),
        dash: dashPattern(dash, width: width))

    func quadPath(_ q: [CGPoint]) -> NSBezierPath {
        let p = NSBezierPath()
        p.move(to: q[0]); p.line(to: q[1]); p.line(to: q[2]); p.line(to: q[3])
        p.close()
        return p
    }

    // Casing beneath: stroke + fill each quad in the outline colour — a centred
    // stroke of 2× the outline width leaves a uniform border once the colour
    // lands on top. Heads mirror drawConnector's casing rules.
    if let oc = outlineColor, outlineWidth > 0 {
        oc.setStroke(); oc.setFill()
        for q in quads {
            let p = quadPath(q)
            p.lineWidth = outlineWidth * 2
            p.lineJoinStyle = .round
            p.stroke(); p.fill()
        }
        if startCap == .filled {
            drawFilledHeadOutline(tip: start, direction: outAtStart, width: wS,
                                  color: oc, outlineWidth: outlineWidth)
        } else {
            drawCap(capGeometry(startCap, tip: start, direction: outAtStart,
                                width: wS + 2 * outlineWidth), width: wS + 2 * outlineWidth)
        }
        if endCap == .filled {
            drawFilledHeadOutline(tip: end, direction: dir, width: wE,
                                  color: oc, outlineWidth: outlineWidth)
        } else {
            drawCap(capGeometry(endCap, tip: end, direction: dir,
                                width: wE + 2 * outlineWidth), width: wE + 2 * outlineWidth)
        }
    }

    // The shaft quad deliberately reaches INTO a filled head (the inset stops
    // the notch, not the overlap), so a translucent colour stacked alpha where
    // they met — a darker band at the head base. Draw everything OPAQUE inside
    // a transparency layer and composite the layer once at the colour's alpha:
    // overlap becomes invisible for every cap type, strokes included.
    let alpha = color.alphaComponent
    let opaque = alpha < 1 ? color.withAlphaComponent(1) : color
    drawingAsOneObject(alpha: alpha) {
        opaque.setStroke(); opaque.setFill()
        for q in quads { quadPath(q).fill() }
        drawCap(capGeometry(startCap, tip: start, direction: outAtStart, width: wS), width: wS)
        drawCap(capGeometry(endCap, tip: end, direction: dir, width: wE), width: wE)
    }
}

// MARK: - Drawing

/// Stroke a line/arrow connector from `start` to `end` in the current graphics
/// context. The shaft honours `dash`; each end draws its cap. The shaft retreats
/// from a filled head so there's no poke-through, and caps always render solid
/// even when the shaft is dashed. Used by both the export renderer and the live
/// canvas/preview so they can never diverge.

/// Run `body` so that everything it draws casts ONE shadow, from the composite
/// silhouette, instead of each piece stamping its own.
///
/// A connector is several overlapping pieces — shaft, two caps, and an optional
/// wider casing beneath them — and `CGContext`'s shadow is applied per drawing
/// operation. Without grouping, the shaft's shadow lands on the head and the
/// head's lands back on the shaft, which shows as a grey smudge exactly where
/// they meet. `drawShapeAsOneObject` already does this for fill+stroke shapes,
/// for the same reason.
///
/// Also carries the alpha trick the tapered shaft needed: the shaft reaches
/// INTO a filled head, so a translucent colour stacked alpha where they
/// overlapped. Drawing opaque inside the layer and compositing the layer once
/// at the real alpha removes that too. That grouping used to happen ONLY when
/// alpha < 1, which is why an opaque arrow still showed the shadow artefact.
func drawingAsOneObject<T>(alpha: CGFloat, _ body: () -> T) -> T {
    guard let cg = NSGraphicsContext.current?.cgContext else { return body() }
    cg.saveGState()
    if alpha < 1 { cg.setAlpha(alpha) }
    cg.beginTransparencyLayer(auxiliaryInfo: nil)
    defer { cg.endTransparencyLayer(); cg.restoreGState() }
    return body()
}

func drawConnector(from start: CGPoint, to end: CGPoint, width: CGFloat, color: NSColor,
                   dash: DashStyle, startCap: ArrowCap, endCap: ArrowCap,
                   shaft: ShaftStyle = .uniform,
                   outlineColor: NSColor? = nil, outlineWidth: CGFloat = 0) {
    guard width > 0 else { return }
    if shaft == .tapered {
        drawTaperedConnector(from: start, to: end, width: width, color: color,
                             dash: dash, startCap: startCap, endCap: endCap,
                             outlineColor: outlineColor, outlineWidth: outlineWidth)
        return
    }
    let dx = end.x - start.x, dy = end.y - start.y
    let len = hypot(dx, dy)
    guard len > 0.01 else { return }
    let dir = CGVector(dx: dx / len, dy: dy / len)            // start → end
    let outAtStart = CGVector(dx: -dir.dx, dy: -dir.dy)       // outward at start
    let outAtEnd = dir                                        // outward at end
    let casingWidth = width + 2 * outlineWidth

    // Contrasting casing, drawn BENEATH the stroke so it reads as a uniform
    // border. The shaft is a wider line; a filled head gets a uniform outline
    // (an outward-offset copy of the stroke head — scaling the head with the
    // casing width would balloon it, since head geometry scales with width).
    // One shadow for the whole connector, not one per piece — see
    // `drawingAsOneObject`. The casing must be INSIDE the group too, or the
    // wider outline stroke stamps its own shadow onto the fill above it.
    drawingAsOneObject(alpha: color.alphaComponent) {
    let color = color.alphaComponent < 1 ? color.withAlphaComponent(1) : color
    if let oc = outlineColor, outlineWidth > 0 {
        let oc = oc.alphaComponent < 1 ? oc.withAlphaComponent(1) : oc
        oc.setStroke()
        oc.setFill()
        let sInset = capShaftInset(startCap, width: width)
        let eInset = capShaftInset(endCap, width: width)
        let shaftStart = CGPoint(x: start.x + dir.dx * sInset, y: start.y + dir.dy * sInset)
        let shaftEnd = CGPoint(x: end.x - dir.dx * eInset, y: end.y - dir.dy * eInset)
        let shaft = NSBezierPath()
        shaft.lineWidth = casingWidth
        shaft.lineCapStyle = .round
        if let pattern = dashPattern(dash, width: casingWidth) {
            shaft.setLineDash(pattern, count: pattern.count, phase: 0)
        }
        shaft.move(to: shaftStart)
        shaft.line(to: shaftEnd)
        shaft.stroke()
        // Head casing: filled heads get a uniform border; other caps get the
        // wider version of themselves (dot/bar/open scale acceptably).
        if startCap == .filled {
            drawFilledHeadOutline(tip: start, direction: outAtStart, width: width,
                                  color: oc, outlineWidth: outlineWidth)
        } else {
            drawCap(capGeometry(startCap, tip: start, direction: outAtStart, width: casingWidth),
                    width: casingWidth)
        }
        if endCap == .filled {
            drawFilledHeadOutline(tip: end, direction: outAtEnd, width: width,
                                  color: oc, outlineWidth: outlineWidth)
        } else {
            drawCap(capGeometry(endCap, tip: end, direction: outAtEnd, width: casingWidth),
                    width: casingWidth)
        }
    }

    color.setStroke()
    color.setFill()

    // Shaft, inset at each end so a filled head doesn't poke through.
    let sInset = capShaftInset(startCap, width: width)
    let eInset = capShaftInset(endCap, width: width)
    let shaftStart = CGPoint(x: start.x + dir.dx * sInset, y: start.y + dir.dy * sInset)
    let shaftEnd = CGPoint(x: end.x - dir.dx * eInset, y: end.y - dir.dy * eInset)

    let shaft = NSBezierPath()
    shaft.lineWidth = width
    shaft.lineCapStyle = .round
    if let pattern = dashPattern(dash, width: width) {
        shaft.setLineDash(pattern, count: pattern.count, phase: 0)
    }
    shaft.move(to: shaftStart)
    shaft.line(to: shaftEnd)
    shaft.stroke()

    drawCap(capGeometry(startCap, tip: start, direction: outAtStart, width: width), width: width)
    drawCap(capGeometry(endCap, tip: end, direction: outAtEnd, width: width), width: width)
    }
}

/// The `filled` arrowhead from `capGeometry`, expanded outward by
/// `outlineWidth` as a true border (offset triangle), so the head's outline
/// thickness matches the shaft's casing instead of ballooning with the wider
/// casing width. Fills the outset triangle in `color` (beneath the stroke head).
func drawFilledHeadOutline(tip: CGPoint, direction: CGVector, width: CGFloat,
                           color: NSColor, outlineWidth: CGFloat) {
    guard outlineWidth > 0,
          case let .filledTriangle(tri) = capGeometry(.filled, tip: tip,
                                                      direction: direction, width: width)
    else { return }
    color.setFill()
    let o = outsetTriangle(tri, by: outlineWidth)
    let p = NSBezierPath()
    p.move(to: o[0])
    p.line(to: o[1])
    p.line(to: o[2])
    p.close()
    p.fill()
}

/// Outset (expand) a convex triangle outward by `outline`, returning the offset
/// vertices. Each edge moves outward along its own normal, so the border is
/// uniform — a scaled copy would thicken it toward the base. Winding-agnostic:
/// the outward side of each edge is chosen as the one pointing away from the
/// triangle's centroid.
func outsetTriangle(_ tri: [CGPoint], by outline: CGFloat) -> [CGPoint] {
    guard tri.count == 3, outline > 0 else { return tri }
    let cx = (tri[0].x + tri[1].x + tri[2].x) / 3
    let cy = (tri[0].y + tri[1].y + tri[2].y) / 3
    func normal(_ p: CGPoint, _ q: CGPoint) -> CGVector {
        let dx = q.x - p.x, dy = q.y - p.y
        let l = max(hypot(dx, dy), 0.0001)
        let nx = -dy / l, ny = dx / l
        let mx = (p.x + q.x) / 2 - cx, my = (p.y + q.y) / 2 - cy
        return nx * mx + ny * my >= 0 ? CGVector(dx: nx, dy: ny) : CGVector(dx: -nx, dy: -ny)
    }
    func line(_ v: CGPoint, _ n: CGVector) -> (CGFloat, CGFloat, CGFloat) {
        (n.dx, n.dy, n.dx * v.x + n.dy * v.y + outline)
    }
    func intersect(_ l1: (CGFloat, CGFloat, CGFloat), _ l2: (CGFloat, CGFloat, CGFloat)) -> CGPoint {
        let (a1, b1, c1) = l1
        let (a2, b2, c2) = l2
        let det = a1 * b2 - a2 * b1
        guard abs(det) > 0.0001 else { return .zero }
        return CGPoint(x: (c1 * b2 - c2 * b1) / det, y: (a1 * c2 - a2 * c1) / det)
    }
    var out: [CGPoint] = []
    for i in 0..<3 {
        let prev = tri[(i + 2) % 3], cur = tri[i], next = tri[(i + 1) % 3]
        out.append(intersect(line(prev, normal(prev, cur)), line(cur, normal(cur, next))))
    }
    return out
}

/// Draw one arrow cap at `tip`, pointing outward along `direction` (need not be
/// unit length). For freehand arrows (pen-arrow) whose ends are not a straight
/// shaft, the caller passes the path's local tangent at the endpoint.
func drawArrowCap(_ cap: ArrowCap, at tip: CGPoint, direction: CGVector,
                  width: CGFloat, color: NSColor) {
    guard cap != .none, width > 0 else { return }
    color.setStroke()
    color.setFill()
    drawCap(capGeometry(cap, tip: tip, direction: direction, width: width), width: width)
}

private func drawCap(_ shape: CapShape, width: CGFloat) {
    switch shape {
    case .none:
        break
    case let .filledTriangle(pts) where pts.count == 3:
        let p = NSBezierPath()
        p.move(to: pts[0]); p.line(to: pts[1]); p.line(to: pts[2]); p.close()
        p.fill()
    case .filledTriangle:
        break
    case let .openBarbs(apex, left, right):
        let p = NSBezierPath()
        p.lineWidth = width
        p.lineCapStyle = .round
        p.lineJoinStyle = .round
        p.move(to: left); p.line(to: apex); p.line(to: right)
        p.stroke()
    case let .dot(center, radius):
        NSBezierPath(ovalIn: CGRect(x: center.x - radius, y: center.y - radius,
                                    width: radius * 2, height: radius * 2)).fill()
    case let .bar(a, b):
        let p = NSBezierPath()
        p.lineWidth = width
        p.lineCapStyle = .round
        p.move(to: a); p.line(to: b)
        p.stroke()
    }
}
