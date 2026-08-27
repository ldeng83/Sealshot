import CoreGraphics
import Foundation

/// Axis-aligned bounds of a single geometry in image space (arrow endpoints
/// normalized, rectangle standardized).
func geometryBounds(_ geometry: Geometry) -> CGRect {
    switch geometry {
    case let .arrow(start, end):
        return CGRect(
            x: min(start.x, end.x), y: min(start.y, end.y),
            width: abs(end.x - start.x), height: abs(end.y - start.y)
        )
    case let .rectangle(rect):
        return rect.standardized
    case let .text(rect, _):
        return rect.standardized
    case let .ellipse(rect):
        return rect.standardized
    case let .line(start, end):
        return CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                      width: abs(end.x - start.x), height: abs(end.y - start.y))
    case let .badge(center, radius):
        return CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    case let .pen(points), let .penArrow(points):
        guard let first = points.first else { return .zero }
        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        for p in points.dropFirst() {
            minX = min(minX, p.x); minY = min(minY, p.y)
            maxX = max(maxX, p.x); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    case let .blur(region):
        return region.boundingRect
    case let .image(rect, _):
        return rect.standardized
    case let .cut(rect):
        return rect.standardized
    }
}

/// Map freehand pen points from their `old` bounding box into a `new` one —
/// the box-handle resize for the pen tool (mirrors rectangle/ellipse resize).
/// A zero-size `old` box (degenerate path) is returned unscaled to avoid a
/// divide-by-zero.
func scalePenPoints(_ points: [CGPoint], from old: CGRect, to new: CGRect) -> [CGPoint] {
    guard old.width > 0, old.height > 0 else { return points }
    let sx = new.width / old.width
    let sy = new.height / old.height
    return points.map { p in
        CGPoint(x: new.minX + (p.x - old.minX) * sx,
                y: new.minY + (p.y - old.minY) * sy)
    }
}

/// Union of every annotation's geometry bounds, or nil for an empty list.
func boundingBox(of annotations: [Annotation]) -> CGRect? {
    guard let first = annotations.first else { return nil }
    return annotations.dropFirst().reduce(geometryBounds(first.geometry)) { acc, a in
        acc.union(geometryBounds(a.geometry))
    }
}

/// Translation that moves a group (whose bounds are `boundingBox`) so its
/// center sits at `cursor` when the cursor is inside the image, otherwise at
/// the image center.
func pasteTranslation(boundingBox box: CGRect, cursor: CGPoint?, imageSize: CGSize) -> CGVector {
    let imageRect = CGRect(origin: .zero, size: imageSize)
    let target: CGPoint
    if let c = cursor, imageRect.contains(c) {
        target = c
    } else {
        target = CGPoint(x: imageSize.width / 2, y: imageSize.height / 2)
    }
    let center = CGPoint(x: box.midX, y: box.midY)
    return CGVector(dx: target.x - center.x, dy: target.y - center.y)
}

/// Translate a geometry by a vector. Shared by paste-cloning and group-move.
func translatedGeometry(_ geometry: Geometry, by delta: CGVector) -> Geometry {
    switch geometry {
    case let .arrow(start, end):
        return .arrow(
            start: CGPoint(x: start.x + delta.dx, y: start.y + delta.dy),
            end:   CGPoint(x: end.x   + delta.dx, y: end.y   + delta.dy)
        )
    case let .rectangle(rect):
        return .rectangle(rect: rect.offsetBy(dx: delta.dx, dy: delta.dy))
    case let .text(rect, runs):
        return .text(rect: rect.offsetBy(dx: delta.dx, dy: delta.dy), runs: runs)
    case let .ellipse(rect):
        return .ellipse(rect: rect.offsetBy(dx: delta.dx, dy: delta.dy))
    case let .line(start, end):
        return .line(start: CGPoint(x: start.x + delta.dx, y: start.y + delta.dy),
                     end: CGPoint(x: end.x + delta.dx, y: end.y + delta.dy))
    case let .badge(center, radius):
        return .badge(center: CGPoint(x: center.x + delta.dx, y: center.y + delta.dy), radius: radius)
    case let .pen(points):
        return .pen(points: points.map { CGPoint(x: $0.x + delta.dx, y: $0.y + delta.dy) })
    case let .penArrow(points):
        return .penArrow(points: points.map { CGPoint(x: $0.x + delta.dx, y: $0.y + delta.dy) })
    case let .blur(region):
        return .blur(region: region.offsetBy(dx: delta.dx, dy: delta.dy))
    case let .image(rect, assetID):
        return .image(rect: rect.offsetBy(dx: delta.dx, dy: delta.dy), assetID: assetID)
    case let .cut(rect):
        return .cut(rect: rect.offsetBy(dx: delta.dx, dy: delta.dy))
    }
}

/// Clone annotations for paste: assign fresh ids, translate geometry by
/// `delta`, preserve style and transform.
func clonedForPaste(_ annotations: [Annotation], translatedBy delta: CGVector) -> [Annotation] {
    annotations.map { a in
        Annotation(id: UUID(), geometry: translatedGeometry(a.geometry, by: delta),
                   style: a.style, transform: a.transform)
    }
}
