import CoreGraphics

/// Pure resize math for editor annotations: given a geometry, the dragged
/// handle, and the (object-space) drag point, return the resized geometry.
/// Extracted from EditorCanvasView so both the canvas and the non-magnified
/// SelectionChromeOverlay (which now owns object handle drags) can share it.
/// `freeform` disables aspect-lock for image geometries (⇧ during a drag).
func resizeGeometry(_ geometry: Geometry, handle: AnnotationHandle, to point: CGPoint, freeform: Bool = false) -> Geometry {
    switch geometry {
    case let .arrow(start, end):
        switch handle {
        case .start: return .arrow(start: point, end: end)
        case .end:   return .arrow(start: start, end: point)
        default:     return geometry
        }
    case let .rectangle(rect):
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        switch handle {
        case .topLeft:     minX = point.x; minY = point.y
        case .top:         minY = point.y
        case .topRight:    maxX = point.x; minY = point.y
        case .right:       maxX = point.x
        case .bottomRight: maxX = point.x; maxY = point.y
        case .bottom:      maxY = point.y
        case .bottomLeft:  minX = point.x; maxY = point.y
        case .left:        minX = point.x
        default: break
        }
        let normalizedX  = min(minX, maxX)
        let normalizedY  = min(minY, maxY)
        let width  = abs(maxX - minX)
        let height = abs(maxY - minY)
        return .rectangle(
            rect: CGRect(x: normalizedX, y: normalizedY, width: width, height: height)
        )
    case let .text(rect, runs):
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        switch handle {
        case .topLeft:     minX = point.x; minY = point.y
        case .top:         minY = point.y
        case .topRight:    maxX = point.x; minY = point.y
        case .right:       maxX = point.x
        case .bottomRight: maxX = point.x; maxY = point.y
        case .bottom:      maxY = point.y
        case .bottomLeft:  minX = point.x; maxY = point.y
        case .left:        minX = point.x
        default: break
        }
        return .text(rect: CGRect(x: min(minX, maxX), y: min(minY, maxY),
                                  width: max(20, abs(maxX - minX)), height: max(1, abs(maxY - minY))), runs: runs)
    case let .ellipse(rect):
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        switch handle {
        case .topLeft:     minX = point.x; minY = point.y
        case .top:         minY = point.y
        case .topRight:    maxX = point.x; minY = point.y
        case .right:       maxX = point.x
        case .bottomRight: maxX = point.x; maxY = point.y
        case .bottom:      maxY = point.y
        case .bottomLeft:  minX = point.x; maxY = point.y
        case .left:        minX = point.x
        default: break
        }
        return .ellipse(rect: CGRect(x: min(minX, maxX), y: min(minY, maxY),
                                     width: abs(maxX - minX), height: abs(maxY - minY)))
    case let .line(start, end):
        switch handle {
        case .start: return .line(start: point, end: end)
        case .end:   return .line(start: start, end: point)
        default:     return geometry
        }
    case let .badge(center, _):
        let newRadius = max(8, hypot(point.x - center.x, point.y - center.y))
        return .badge(center: center, radius: newRadius)
    case let .pen(points):
        // Box-handle resize: drag a bounding-box handle and scale the whole
        // path into the new box (mirrors ellipse/rectangle).
        let old = geometryBounds(.pen(points: points))
        let new = resizeRect(old, handle: handle, to: point)
        return .pen(points: scalePenPoints(points, from: old, to: new))
    case let .penArrow(points):
        let old = geometryBounds(.penArrow(points: points))
        let new = resizeRect(old, handle: handle, to: point)
        return .penArrow(points: scalePenPoints(points, from: old, to: new))
    case let .blur(region):
        switch region {
        case let .rect(rect):
            return .blur(region: .rect(resizeRect(rect, handle: handle, to: point)))
        case let .ellipse(rect):
            return .blur(region: .ellipse(resizeRect(rect, handle: handle, to: point)))
        case let .freehand(points, width):
            // Drag a path vertex, mirroring the pen tool.
            guard case let .penPoint(i) = handle, points.indices.contains(i) else { return geometry }
            var pts = points
            pts[i] = point
            return .blur(region: .freehand(points: pts, width: width))
        }
    case let .image(rect, assetID):
        if freeform {
            if case let .rectangle(rect: free) =
                resizeGeometry(.rectangle(rect: rect), handle: handle, to: point) {
                return .image(rect: free, assetID: assetID)
            }
            return .image(rect: rect, assetID: assetID)
        }
        return .image(rect: aspectLockedRect(from: rect, handle: handle, to: point,
                                             aspect: rect.width / max(rect.height, 1)),
                      assetID: assetID)
    case let .cut(rect):
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        switch handle {
        case .topLeft:     minX = point.x; minY = point.y
        case .top:         minY = point.y
        case .topRight:    maxX = point.x; minY = point.y
        case .right:       maxX = point.x
        case .bottomRight: maxX = point.x; maxY = point.y
        case .bottom:      maxY = point.y
        case .bottomLeft:  minX = point.x; maxY = point.y
        case .left:        minX = point.x
        default: break
        }
        let normalizedX  = min(minX, maxX)
        let normalizedY  = min(minY, maxY)
        let width  = abs(maxX - minX)
        let height = abs(maxY - minY)
        return .cut(
            rect: CGRect(x: normalizedX, y: normalizedY, width: width, height: height)
        )
    }
}

/// Resize an axis-aligned rect by dragging one of its 8 handles to `point`.
/// Shared by the rectangle/ellipse blur regions and pen box-resize.
func resizeRect(_ rect: CGRect, handle: AnnotationHandle, to point: CGPoint) -> CGRect {
    var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
    switch handle {
    case .topLeft:     minX = point.x; minY = point.y
    case .top:         minY = point.y
    case .topRight:    maxX = point.x; minY = point.y
    case .right:       maxX = point.x
    case .bottomRight: maxX = point.x; maxY = point.y
    case .bottom:      maxY = point.y
    case .bottomLeft:  minX = point.x; maxY = point.y
    case .left:        minX = point.x
    default: break
    }
    return CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
}
