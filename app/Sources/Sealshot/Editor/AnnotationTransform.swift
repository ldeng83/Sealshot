import CoreGraphics

/// Wrap any angle into the stored range [-180, 180).
func normalizedDegrees(_ degrees: CGFloat) -> CGFloat {
    var d = degrees.truncatingRemainder(dividingBy: 360)
    if d >= 180 { d -= 360 }
    if d < -180 { d += 360 }
    return d
}

/// Per-annotation transform: flip about the object's own axes composed
/// BEFORE a rotation about its bounds center. Positive degrees = clockwise
/// on screen. Stored angle is always in [-180, 180).
struct AnnotationTransform: Equatable, Codable {
    var rotationDegrees: CGFloat = 0
    var flipH: Bool = false
    var flipV: Bool = false

    var isIdentity: Bool { rotationDegrees == 0 && !flipH && !flipV }

    /// Same rotation, no flips. The rotate lollipop uses this so it always
    /// sits above the object's visual top (rotation measured from straight-up),
    /// rather than being mirrored to the bottom by a vertical flip.
    var rotationOnly: AnnotationTransform { AnnotationTransform(rotationDegrees: rotationDegrees) }

    /// UI-level horizontal flip: also negates the angle so the on-screen
    /// result is a physical mirror of what was displayed.
    func flippedH() -> AnnotationTransform {
        AnnotationTransform(rotationDegrees: normalizedDegrees(-rotationDegrees),
                            flipH: !flipH, flipV: flipV)
    }

    /// UI-level vertical flip: also negates the angle so the on-screen
    /// result is a physical mirror of what was displayed. (With display =
    /// R(θ)·S about the center, N·R(θ)·S = R(−θ)·(S with flipV toggled)
    /// for the top-bottom mirror N = diag(1,−1) — same conjugation as
    /// `flippedH()`, NOT 180−θ, which would mirror horizontally instead.)
    func flippedV() -> AnnotationTransform {
        AnnotationTransform(rotationDegrees: normalizedDegrees(-rotationDegrees),
                            flipH: flipH, flipV: !flipV)
    }
}
