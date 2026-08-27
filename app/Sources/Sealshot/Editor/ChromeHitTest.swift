import CoreGraphics

/// Hit-test precomputed handle positions against a point, all in the SAME space
/// (the overlay uses screen space). `handleSize` is the full edge length of the
/// centered grab square. Returns the first containing handle (callers order
/// positions so the visually-topmost / priority handle comes first).
func hitTestHandlePositions(_ positions: [(AnnotationHandle, CGPoint)],
                            at point: CGPoint, handleSize: CGFloat) -> AnnotationHandle? {
    let half = handleSize / 2
    for (handle, c) in positions {
        let r = CGRect(x: c.x - half, y: c.y - half, width: handleSize, height: handleSize)
        if r.contains(point) { return handle }
    }
    return nil
}

/// The rotate lollipop dot, a constant screen `offset` above the object's
/// projected top-center. Flipped (top-left) origin, so "above" is `y - offset`.
func screenRotatePosition(topCenterScreen: CGPoint, offset: CGFloat) -> CGPoint {
    CGPoint(x: topCenterScreen.x, y: topCenterScreen.y - offset)
}
