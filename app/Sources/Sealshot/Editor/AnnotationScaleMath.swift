import CoreGraphics
import Foundation

/// Bulk geometry scaling for the document Resize operation: every annotation's
/// stored points/rects (visible-image pixels) multiply by the resize factors,
/// together with the size-bearing style fields (stroke width, font size,
/// corner radius) so drawings keep their proportions on the resized image.
/// `AnnotationTransform` (rotation/flips) is left untouched — angles are
/// scale-invariant under uniform factors; under a non-uniform (unlocked)
/// resize, rotated objects scale by their bounds like everything else, an
/// accepted approximation (anisotropic scale of a rotation isn't
/// representable in the transform model).
enum AnnotationScaleMath {

    static func scaledAnnotations(_ annotations: [Annotation],
                                  fx: CGFloat, fy: CGFloat) -> [Annotation] {
        annotations.map { a in
            var out = a
            out.geometry = scaledGeometry(a.geometry, fx: fx, fy: fy)
            out.style = scaledStyle(a.style, fx: fx, fy: fy)
            return out
        }
    }

    /// Uniform factor for 1-D sizes (stroke, radius, font) under a possibly
    /// non-uniform resize: the geometric mean keeps areas proportional and
    /// equals the factor when the resize is uniform.
    static func sizeFactor(fx: CGFloat, fy: CGFloat) -> CGFloat {
        (fx * fy > 0) ? sqrt(fx * fy) : 1
    }

    static func scaledGeometry(_ g: Geometry, fx: CGFloat, fy: CGFloat) -> Geometry {
        func p(_ pt: CGPoint) -> CGPoint { CGPoint(x: pt.x * fx, y: pt.y * fy) }
        func r(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX * fx, y: rect.minY * fy,
                   width: rect.width * fx, height: rect.height * fy)
        }
        switch g {
        case .arrow(let s, let e): return .arrow(start: p(s), end: p(e))
        case .line(let s, let e): return .line(start: p(s), end: p(e))
        case .rectangle(let rect): return .rectangle(rect: r(rect))
        case .ellipse(let rect): return .ellipse(rect: r(rect))
        case .text(let rect, let runs):
            // Runs carry their own font sizes (rich text) — scale each.
            let f = sizeFactor(fx: fx, fy: fy)
            var scaledRuns = runs
            for i in scaledRuns.indices { scaledRuns[i].fontSize *= f }
            return .text(rect: r(rect), runs: scaledRuns)
        case .badge(let center, let radius):
            return .badge(center: p(center), radius: radius * sizeFactor(fx: fx, fy: fy))
        case .pen(let points): return .pen(points: points.map(p))
        case .penArrow(let points): return .penArrow(points: points.map(p))
        case .blur(let region): return .blur(region: scaledBlur(region, fx: fx, fy: fy))
        case .image(let rect, let assetID): return .image(rect: r(rect), assetID: assetID)
        case .cut(let rect): return .cut(rect: r(rect))
        }
    }

    static func scaledBlur(_ region: BlurRegion, fx: CGFloat, fy: CGFloat) -> BlurRegion {
        func p(_ pt: CGPoint) -> CGPoint { CGPoint(x: pt.x * fx, y: pt.y * fy) }
        func r(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX * fx, y: rect.minY * fy,
                   width: rect.width * fx, height: rect.height * fy)
        }
        switch region {
        case .rect(let rect): return .rect(r(rect))
        case .ellipse(let rect): return .ellipse(r(rect))
        case .freehand(let points, let width):
            return .freehand(points: points.map(p),
                             width: width * sizeFactor(fx: fx, fy: fy))
        }
    }

    static func scaledStyle(_ s: Style, fx: CGFloat, fy: CGFloat) -> Style {
        let f = sizeFactor(fx: fx, fy: fy)
        var out = s
        out.strokeWidth = s.strokeWidth * f
        out.fontSize = s.fontSize * f
        out.cornerRadius = s.cornerRadius * f
        return out
    }
}
