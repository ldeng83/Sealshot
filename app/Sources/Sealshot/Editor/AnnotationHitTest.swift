import CoreGraphics
import Foundation

/// Which handle of a selected annotation was hit. Arrow has 2 endpoint
/// handles; rectangle has 8 (4 corners + 4 edge midpoints).
enum AnnotationHandle: Equatable {
    /// Lollipop grab above the object's top-center: drag to rotate.
    case rotate
    case start, end                              // arrow
    case topLeft, top, topRight                  // rectangle corners + edge midpoints
    case left, right
    case bottomLeft, bottom, bottomRight
    case penPoint(Int)                           // freehand vertex by index
}

/// Return the topmost annotation whose body is within `tolerance` of `point`,
/// or nil. Search runs from the end of the list because later entries are
/// drawn on top.
internal func hitTestAnnotations(
    _ annotations: [Annotation],
    at point: CGPoint,
    tolerance: CGFloat
) -> UUID? {
    for annotation in annotations.reversed() {
        if hits(annotation, at: point, tolerance: tolerance) {
            return annotation.id
        }
    }
    return nil
}

/// Return the handle of `annotation` that contains `point`, or nil. Caller
/// is responsible for ensuring `annotation` is the currently-selected one.
/// `handleSize` is the full edge length of a handle (8pt by default).
internal func hitTestHandles(
    of annotation: Annotation,
    at point: CGPoint,
    handleSize: CGFloat,
    rotateOffset: CGFloat = 24
) -> AnnotationHandle? {
    let half = handleSize / 2
    let candidates = handlePositions(of: annotation, rotateOffset: rotateOffset)
    for (handle, position) in candidates {
        let r = CGRect(
            x: position.x - half, y: position.y - half,
            width: handleSize, height: handleSize
        )
        if r.contains(point) {
            return handle
        }
    }
    return nil
}

// MARK: - Body hit-testing

private func hits(_ annotation: Annotation, at point: CGPoint, tolerance: CGFloat) -> Bool {
    // Rotated/flipped objects: test in OBJECT space — inverse-map the probe
    // so every per-geometry case below stays transform-unaware.
    var point = point
    if !annotation.transform.isIdentity {
        let b = geometryBounds(annotation.geometry)
        point = point.applying(
            transformMatrix(for: annotation.transform,
                            center: CGPoint(x: b.midX, y: b.midY)).inverted())
    }
    switch annotation.geometry {
    case let .arrow(start, end):
        return distanceFromPoint(point, toSegmentFrom: start, to: end) <= tolerance
    case let .rectangle(rect):
        // A filled rectangle is hittable anywhere inside (plus the edge
        // tolerance); an outline-only rectangle only near its edge.
        if annotation.style.fillColor != nil {
            return rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        }
        return pointIsNearRectangleEdge(point, rect: rect, tolerance: tolerance)
    case let .text(rect, _):
        return rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
    case let .ellipse(rect):
        if annotation.style.fillColor != nil {
            return pointInEllipse(point, rect: rect, tolerance: tolerance)
        }
        return pointNearEllipseEdge(point, rect: rect, tolerance: tolerance)
    case let .line(start, end):
        return distanceFromPoint(point, toSegmentFrom: start, to: end) <= tolerance
    case let .badge(center, radius):
        return hypot(point.x - center.x, point.y - center.y) <= radius + tolerance
    case let .pen(points), let .penArrow(points):
        if points.count == 1 { return hypot(point.x - points[0].x, point.y - points[0].y) <= tolerance }
        for i in 0..<max(0, points.count - 1) where
            distanceFromPoint(point, toSegmentFrom: points[i], to: points[i + 1]) <= tolerance {
            return true
        }
        return false
    case let .blur(region):
        return blurRegionHits(region, at: point, tolerance: tolerance)
    case let .image(rect, _):
        // Images are always "filled" — hittable anywhere inside.
        return rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
    case let .cut(rect):
        // Always edge-only: a transparent hole has no fill, so only the border is hittable.
        return pointIsNearRectangleEdge(point, rect: rect, tolerance: tolerance)
    }
}

/// A blur region is hittable anywhere inside its filled shape (plus the edge
/// tolerance). Freehand is hittable within half the brush width of its path.
private func blurRegionHits(_ region: BlurRegion, at point: CGPoint, tolerance: CGFloat) -> Bool {
    switch region {
    case let .rect(rect):
        return rect.standardized.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
    case let .ellipse(rect):
        return pointInEllipse(point, rect: rect.standardized, tolerance: tolerance)
    case let .freehand(points, width):
        let reach = width / 2 + tolerance
        if points.count == 1 { return hypot(point.x - points[0].x, point.y - points[0].y) <= reach }
        for i in 0..<max(0, points.count - 1) where
            distanceFromPoint(point, toSegmentFrom: points[i], to: points[i + 1]) <= reach {
            return true
        }
        return false
    }
}

private func distanceFromPoint(_ p: CGPoint, toSegmentFrom a: CGPoint, to b: CGPoint) -> CGFloat {
    let dx = b.x - a.x
    let dy = b.y - a.y
    let lengthSquared = dx*dx + dy*dy
    if lengthSquared < 0.0001 {
        return hypot(p.x - a.x, p.y - a.y)
    }
    var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared
    t = max(0, min(1, t))
    let projection = CGPoint(x: a.x + t * dx, y: a.y + t * dy)
    return hypot(p.x - projection.x, p.y - projection.y)
}

private func pointIsNearRectangleEdge(
    _ p: CGPoint,
    rect: CGRect,
    tolerance: CGFloat
) -> Bool {
    let top    = CGPoint(x: max(rect.minX, min(rect.maxX, p.x)), y: rect.minY)
    let bottom = CGPoint(x: max(rect.minX, min(rect.maxX, p.x)), y: rect.maxY)
    let left   = CGPoint(x: rect.minX, y: max(rect.minY, min(rect.maxY, p.y)))
    let right  = CGPoint(x: rect.maxX, y: max(rect.minY, min(rect.maxY, p.y)))
    let d = min(
        hypot(p.x - top.x,    p.y - top.y),
        hypot(p.x - bottom.x, p.y - bottom.y),
        hypot(p.x - left.x,   p.y - left.y),
        hypot(p.x - right.x,  p.y - right.y)
    )
    return d <= tolerance
}

private func ellipseValue(_ p: CGPoint, rect: CGRect) -> CGFloat {
    let rx = rect.width / 2, ry = rect.height / 2
    guard rx > 0, ry > 0 else { return .greatestFiniteMagnitude }
    let dx = (p.x - rect.midX) / rx, dy = (p.y - rect.midY) / ry
    return dx*dx + dy*dy
}
private func pointInEllipse(_ p: CGPoint, rect: CGRect, tolerance: CGFloat) -> Bool {
    ellipseValue(p, rect: rect.insetBy(dx: -tolerance, dy: -tolerance)) <= 1.0
}
private func pointNearEllipseEdge(_ p: CGPoint, rect: CGRect, tolerance: CGFloat) -> Bool {
    let outer = ellipseValue(p, rect: rect.insetBy(dx: -tolerance, dy: -tolerance))
    let inner = ellipseValue(p, rect: rect.insetBy(dx: tolerance, dy: tolerance))
    return outer <= 1.0 && inner >= 1.0
}

// MARK: - Marquee rect selection

/// Return the ids of every annotation whose axis-aligned bounds are fully
/// ENCLOSED by `rect` (image space), in document order. Used by marquee
/// selection.
///
/// Containment, not intersection: a marquee that merely grazes an object
/// leaves it alone, so sweeping a band across a busy canvas selects what you
/// drew the band around rather than everything it brushed past. The test is
/// the transformed AABB, so a rotated object needs the box around it enclosed
/// — slightly more area than the shape appears to occupy.
internal func annotationsContained(_ annotations: [Annotation], rect: CGRect) -> [UUID] {
    let marquee = rect.standardized
    return annotations
        .filter {
            marquee.contains(transformedAABB(bounds: geometryBounds($0.geometry),
                                             transform: $0.transform))
        }
        .map { $0.id }
}

// MARK: - Handle positions

/// Handle positions in IMAGE space: per-geometry object-space positions plus
/// the rotate lollipop above the top-center, all mapped through the
/// annotation's transform so they track the rotated/flipped object.
/// `rotateOffset` is the lollipop's distance above the top edge (image
/// space) — the canvas passes a zoom-compensated value so the dot keeps a
/// constant view-space gap from the object.
internal func handlePositions(
    of annotation: Annotation,
    rotateOffset: CGFloat = 24
) -> [(AnnotationHandle, CGPoint)] {
    let b = geometryBounds(annotation.geometry)
    let center = CGPoint(x: b.midX, y: b.midY)
    let base = baseHandlePositions(of: annotation)
    let rotateBase = CGPoint(x: b.midX, y: b.minY - rotateOffset)
    let t = annotation.transform
    guard !t.isIdentity else { return base + [(.rotate, rotateBase)] }
    // Resize handles track the full transform (flip included) so they follow
    // the mirrored object; the rotate lollipop tracks ROTATION ONLY so it stays
    // above the visual top and "anchor straight up = 0°" survives a flip.
    let m = transformMatrix(for: t, center: center)
    let rotateM = transformMatrix(for: t.rotationOnly, center: center)
    return base.map { ($0.0, $0.1.applying(m)) }
         + [(.rotate, rotateBase.applying(rotateM))]
}

private func baseHandlePositions(of annotation: Annotation) -> [(AnnotationHandle, CGPoint)] {
    switch annotation.geometry {
    case let .arrow(start, end):
        return [(.start, start), (.end, end)]
    case let .rectangle(rect):
        return [
            (.topLeft,     CGPoint(x: rect.minX, y: rect.minY)),
            (.top,         CGPoint(x: rect.midX, y: rect.minY)),
            (.topRight,    CGPoint(x: rect.maxX, y: rect.minY)),
            (.right,       CGPoint(x: rect.maxX, y: rect.midY)),
            (.bottomRight, CGPoint(x: rect.maxX, y: rect.maxY)),
            (.bottom,      CGPoint(x: rect.midX, y: rect.maxY)),
            (.bottomLeft,  CGPoint(x: rect.minX, y: rect.maxY)),
            (.left,        CGPoint(x: rect.minX, y: rect.midY))
        ]
    case let .text(rect, _):
        return [
            (.topLeft,     CGPoint(x: rect.minX, y: rect.minY)),
            (.top,         CGPoint(x: rect.midX, y: rect.minY)),
            (.topRight,    CGPoint(x: rect.maxX, y: rect.minY)),
            (.right,       CGPoint(x: rect.maxX, y: rect.midY)),
            (.bottomRight, CGPoint(x: rect.maxX, y: rect.maxY)),
            (.bottom,      CGPoint(x: rect.midX, y: rect.maxY)),
            (.bottomLeft,  CGPoint(x: rect.minX, y: rect.maxY)),
            (.left,        CGPoint(x: rect.minX, y: rect.midY))
        ]
    case let .ellipse(rect):
        return [
            (.topLeft,     CGPoint(x: rect.minX, y: rect.minY)),
            (.top,         CGPoint(x: rect.midX, y: rect.minY)),
            (.topRight,    CGPoint(x: rect.maxX, y: rect.minY)),
            (.right,       CGPoint(x: rect.maxX, y: rect.midY)),
            (.bottomRight, CGPoint(x: rect.maxX, y: rect.maxY)),
            (.bottom,      CGPoint(x: rect.midX, y: rect.maxY)),
            (.bottomLeft,  CGPoint(x: rect.minX, y: rect.maxY)),
            (.left,        CGPoint(x: rect.minX, y: rect.midY))
        ]
    case let .line(start, end):
        return [(.start, start), (.end, end)]
    case let .badge(center, radius):
        return [
            (.top,    CGPoint(x: center.x, y: center.y - radius)),
            (.right,  CGPoint(x: center.x + radius, y: center.y)),
            (.bottom, CGPoint(x: center.x, y: center.y + radius)),
            (.left,   CGPoint(x: center.x - radius, y: center.y))
        ]
    case let .pen(points), let .penArrow(points):
        // Bounding-box resize handles (mirrors the canvas overlay), not a dot
        // per vertex — so the drawn line reads smooth.
        return rectHandlePositions(geometryBounds(.pen(points: points)))
    case let .blur(region):
        return blurRegionHandles(region)
    case let .image(rect, _):
        return [
            (.topLeft,     CGPoint(x: rect.minX, y: rect.minY)),
            (.topRight,    CGPoint(x: rect.maxX, y: rect.minY)),
            (.bottomRight, CGPoint(x: rect.maxX, y: rect.maxY)),
            (.bottomLeft,  CGPoint(x: rect.minX, y: rect.maxY))
        ]
    case let .cut(rect):
        return [
            (.topLeft,     CGPoint(x: rect.minX, y: rect.minY)),
            (.top,         CGPoint(x: rect.midX, y: rect.minY)),
            (.topRight,    CGPoint(x: rect.maxX, y: rect.minY)),
            (.right,       CGPoint(x: rect.maxX, y: rect.midY)),
            (.bottomRight, CGPoint(x: rect.maxX, y: rect.maxY)),
            (.bottom,      CGPoint(x: rect.midX, y: rect.maxY)),
            (.bottomLeft,  CGPoint(x: rect.minX, y: rect.maxY)),
            (.left,        CGPoint(x: rect.minX, y: rect.midY))
        ]
    }
}

/// Selection/resize handles for a blur region: the 8 box handles for
/// rect/ellipse, or the simplified path vertices for freehand (draggable, like
/// the pen tool). Shared by hit-testing and the canvas selection overlay.
func blurRegionHandles(_ region: BlurRegion) -> [(AnnotationHandle, CGPoint)] {
    switch region {
    case let .rect(rect), let .ellipse(rect):
        return rectHandlePositions(rect.standardized)
    case let .freehand(points, _):
        return PathSimplify.anchorIndices(count: points.count, max: PathSimplify.maxPenAnchors)
            .map { (.penPoint($0), points[$0]) }
    }
}

/// The 8 resize handles (4 corners + 4 edge midpoints) of an axis-aligned rect.
private func rectHandlePositions(_ rect: CGRect) -> [(AnnotationHandle, CGPoint)] {
    [
        (.topLeft,     CGPoint(x: rect.minX, y: rect.minY)),
        (.top,         CGPoint(x: rect.midX, y: rect.minY)),
        (.topRight,    CGPoint(x: rect.maxX, y: rect.minY)),
        (.right,       CGPoint(x: rect.maxX, y: rect.midY)),
        (.bottomRight, CGPoint(x: rect.maxX, y: rect.maxY)),
        (.bottom,      CGPoint(x: rect.midX, y: rect.maxY)),
        (.bottomLeft,  CGPoint(x: rect.minX, y: rect.maxY)),
        (.left,        CGPoint(x: rect.minX, y: rect.midY))
    ]
}
