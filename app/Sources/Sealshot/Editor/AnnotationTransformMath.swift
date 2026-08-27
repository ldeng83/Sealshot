import CoreGraphics

/// The affine matrix for `transform` about `center`, in a Y-DOWN coordinate
/// space (canvas view space and stored image space): T(c)·R(θ)·S(flip)·T(−c)
/// in column-vector notation — physical order: shift to origin, FLIP, then
/// ROTATE, then shift back. (CG's .rotated/.scaledBy/.translatedBy PREPEND,
/// so the chained builder below evaluates right-to-left relative to the
/// chain; the tests pin the resulting point mapping.)
/// In a Y-UP space (the export renderer after flipY) callers negate the
/// angle and swap flipV/flipH effects by negating the angle only — see
/// renderMatrix(for:center:).
func transformMatrix(for t: AnnotationTransform, center: CGPoint) -> CGAffineTransform {
    guard !t.isIdentity else { return .identity }
    let radians = t.rotationDegrees * .pi / 180
    return CGAffineTransform(translationX: center.x, y: center.y)
        .rotated(by: radians)
        .scaledBy(x: t.flipH ? -1 : 1, y: t.flipV ? -1 : 1)
        .translatedBy(x: -center.x, y: -center.y)
}

/// Matrix for the export renderer's 1× space, which is Y-UP (geometry is
/// flipY'd before drawing): same flip scales, NEGATED angle, about the
/// flipped center.
func renderMatrix(for t: AnnotationTransform, center: CGPoint) -> CGAffineTransform {
    guard !t.isIdentity else { return .identity }
    let radians = -t.rotationDegrees * .pi / 180
    return CGAffineTransform(translationX: center.x, y: center.y)
        .rotated(by: radians)
        .scaledBy(x: t.flipH ? -1 : 1, y: t.flipV ? -1 : 1)
        .translatedBy(x: -center.x, y: -center.y)
}

/// Axis-aligned bounding box of `bounds` under `transform` (for crop
/// clipping and marquee/emphasis chrome).
func transformedAABB(bounds: CGRect, transform t: AnnotationTransform) -> CGRect {
    guard !t.isIdentity else { return bounds }
    let m = transformMatrix(for: t,
                            center: CGPoint(x: bounds.midX, y: bounds.midY))
    let corners = [
        CGPoint(x: bounds.minX, y: bounds.minY),
        CGPoint(x: bounds.maxX, y: bounds.minY),
        CGPoint(x: bounds.maxX, y: bounds.maxY),
        CGPoint(x: bounds.minX, y: bounds.maxY),
    ].map { $0.applying(m) }
    let xs = corners.map(\.x), ys = corners.map(\.y)
    return CGRect(x: xs.min()!, y: ys.min()!,
                  width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
}
