import CoreGraphics
import Foundation

/// The 8 draggable handles of the focus-crop rectangle.
enum FocusHandle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
}

/// A single straight stroke of the focus-crop viewfinder overlay (view space).
struct FocusBracketSegment: Equatable {
    var a: CGPoint
    var b: CGPoint
}

/// The viewfinder strokes that mark the focus rectangle `v` (view space): an
/// L-shaped bracket at each corner plus a short centred tick on each edge.
///
/// This deliberately reads differently from an object's resize handles (filled
/// dots): brackets say "you're framing a region," not "grab to resize a thing."
/// `arm` is the length of each corner arm; `tick` is the full length of each
/// edge centre mark. Corner arms run inward along the two meeting edges; edge
/// ticks are centred on the midpoint and lie along their edge.
func focusBracketSegments(in v: CGRect, arm: CGFloat, tick: CGFloat) -> [FocusBracketSegment] {
    func seg(_ ax: CGFloat, _ ay: CGFloat, _ bx: CGFloat, _ by: CGFloat) -> FocusBracketSegment {
        FocusBracketSegment(a: CGPoint(x: ax, y: ay), b: CGPoint(x: bx, y: by))
    }
    let half = tick / 2
    return [
        // Top-left corner: arm right, arm down.
        seg(v.minX, v.minY, v.minX + arm, v.minY),
        seg(v.minX, v.minY, v.minX, v.minY + arm),
        // Top-right corner: arm left, arm down.
        seg(v.maxX, v.minY, v.maxX - arm, v.minY),
        seg(v.maxX, v.minY, v.maxX, v.minY + arm),
        // Bottom-right corner: arm left, arm up.
        seg(v.maxX, v.maxY, v.maxX - arm, v.maxY),
        seg(v.maxX, v.maxY, v.maxX, v.maxY - arm),
        // Bottom-left corner: arm right, arm up.
        seg(v.minX, v.maxY, v.minX + arm, v.maxY),
        seg(v.minX, v.maxY, v.minX, v.maxY - arm),
        // Edge centre ticks, collinear with their edge.
        seg(v.midX - half, v.minY, v.midX + half, v.minY),  // top
        seg(v.midX - half, v.maxY, v.midX + half, v.maxY),  // bottom
        seg(v.minX, v.midY - half, v.minX, v.midY + half),  // left
        seg(v.maxX, v.midY - half, v.maxX, v.midY + half),  // right
    ]
}

/// Hit-test a point `p` against the focus rectangle `v` (both view space).
///
/// Every drawn handle dot — the 4 corners AND the 4 edge midpoints — is a
/// grabbable disc of radius `cornerRadius` around its centre, so placing the
/// cursor on (or near) any dot activates it; the nearest dot wins, with corners
/// breaking ties. As a convenience, a point within `edgeTolerance` of an edge
/// line — anywhere along the span outside the corner zones — also grabs that
/// edge, so a whole edge can be dragged, not just its midpoint dot. Returns nil
/// when `p` isn't near the boundary.
func focusHandleHit(at p: CGPoint, in v: CGRect,
                    cornerRadius: CGFloat, edgeTolerance: CGFloat) -> FocusHandle? {
    // Corners first so they break ties against the adjacent edge midpoints.
    let dots: [(FocusHandle, CGPoint)] = [
        (.topLeft,     CGPoint(x: v.minX, y: v.minY)),
        (.topRight,    CGPoint(x: v.maxX, y: v.minY)),
        (.bottomLeft,  CGPoint(x: v.minX, y: v.maxY)),
        (.bottomRight, CGPoint(x: v.maxX, y: v.maxY)),
        (.top,    CGPoint(x: v.midX, y: v.minY)),
        (.bottom, CGPoint(x: v.midX, y: v.maxY)),
        (.left,   CGPoint(x: v.minX, y: v.midY)),
        (.right,  CGPoint(x: v.maxX, y: v.midY)),
    ]
    var nearest: (handle: FocusHandle, dist: CGFloat)?
    for (handle, c) in dots {
        let d = hypot(p.x - c.x, p.y - c.y)
        if d <= cornerRadius, nearest == nil || d < nearest!.dist {
            nearest = (handle, d)
        }
    }
    if let nearest { return nearest.handle }
    // Whole-edge band (corner zones excluded so corners keep priority).
    let withinX = p.x >= v.minX + cornerRadius && p.x <= v.maxX - cornerRadius
    let withinY = p.y >= v.minY + cornerRadius && p.y <= v.maxY - cornerRadius
    if withinX && abs(p.y - v.minY) <= edgeTolerance { return .top }
    if withinX && abs(p.y - v.maxY) <= edgeTolerance { return .bottom }
    if withinY && abs(p.x - v.minX) <= edgeTolerance { return .left }
    if withinY && abs(p.x - v.maxX) <= edgeTolerance { return .right }
    return nil
}

/// Constrain `rect` to `aspect` (width / height), keeping `anchor` (a corner of
/// rect, image space top-left) fixed. Sizes to the larger of the two axis-driven
/// candidates, then scales both dims proportionally if the result would exceed
/// `bounds`, keeping `anchor` fixed. `anchor` must be one of rect's 4 corners.
func aspectConstrainedRect(_ rect: CGRect, aspect: CGFloat, anchor: CGPoint, bounds: CGRect) -> CGRect {
    let minSize: CGFloat = 1
    let w = rect.width, h = rect.height
    var tw = max(w, h * aspect)
    var th = tw / aspect
    tw = max(tw, minSize); th = max(th, minSize)

    let anchorIsLeft = anchor.x <= rect.midX
    let anchorIsTop  = anchor.y <= rect.midY

    // Find the minimum scale that keeps the free corner within bounds.
    var scale: CGFloat = 1
    if anchorIsLeft {
        if tw > bounds.maxX - anchor.x { scale = min(scale, (bounds.maxX - anchor.x) / tw) }
    } else {
        if tw > anchor.x - bounds.minX { scale = min(scale, (anchor.x - bounds.minX) / tw) }
    }
    if anchorIsTop {
        if th > bounds.maxY - anchor.y { scale = min(scale, (bounds.maxY - anchor.y) / th) }
    } else {
        if th > anchor.y - bounds.minY { scale = min(scale, (anchor.y - bounds.minY) / th) }
    }
    if scale < 1 {
        tw = max(tw * scale, minSize)
        th = tw / aspect
    }

    let ox = anchorIsLeft ? anchor.x : anchor.x - tw
    let oy = anchorIsTop  ? anchor.y : anchor.y - th
    return CGRect(x: ox, y: oy, width: tw, height: th)
}

/// Resize `start` by dragging `handle` toward image point `p`. The dragged
/// edge(s) follow `p` freely — the rect may GROW or SHRINK — constrained only
/// to stay within `bounds` (the image) and never go below `minSize` on either
/// axis. Image-space, top-left origin.
///
/// Bidirectional resize is what lets a user re-open an existing focus crop and
/// drag an anchor back out to enlarge it.
func resizeFocus(start: CGRect, handle: FocusHandle, to p: CGPoint,
                 minSize: CGFloat, bounds: CGRect) -> CGRect {
    var left = start.minX, top = start.minY, right = start.maxX, bottom = start.maxY
    // Clamp the drag point to the image so an edge can't leave the picture,
    // but allow it anywhere inside — including outside the start rect (grow).
    let px = min(max(p.x, bounds.minX), bounds.maxX)
    let py = min(max(p.y, bounds.minY), bounds.maxY)
    switch handle {
    case .topLeft:     left = px; top = py
    case .top:         top = py
    case .topRight:    right = px; top = py
    case .right:       right = px
    case .bottomRight: right = px; bottom = py
    case .bottom:      bottom = py
    case .bottomLeft:  left = px; bottom = py
    case .left:        left = px
    }
    // Enforce minimum size by pushing the moved edge back toward the fixed one.
    if right - left < minSize {
        switch handle {
        case .topLeft, .bottomLeft, .left: left = right - minSize
        default:                           right = left + minSize
        }
    }
    if bottom - top < minSize {
        switch handle {
        case .topLeft, .topRight, .top: top = bottom - minSize
        default:                        bottom = top + minSize
        }
    }
    left = max(left, bounds.minX); top = max(top, bounds.minY)
    right = min(right, bounds.maxX); bottom = min(bottom, bounds.maxY)
    return CGRect(x: left, y: top, width: right - left, height: bottom - top)
}
