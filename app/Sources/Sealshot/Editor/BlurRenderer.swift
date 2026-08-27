import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// The one place blur pixels are produced. Samples a region from the base
/// (source) image and applies a Core Image filter, so the live canvas
/// (`EditorCanvasView`) and the saved-image renderer (`AnnotationRenderer`)
/// derive identical pixels. Coordinate mapping (view-space vs the renderer's
/// flipped context) stays with each caller; this type is space-agnostic.
enum BlurRenderer {

    /// One shared GPU-backed context for the whole editor. Creating a CIContext
    /// per render is expensive; a single static instance is reused.
    static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Fallback fill for the `.solid` effect when an annotation carries no
    /// explicit color (`Style.fillColor == nil`). A near-black neutral.
    static let defaultSolidColor = NSColor(white: 0.13, alpha: 1)

    /// The solid fill color for a blur, resolving `Style.fillColor` or the
    /// default. Shared by both callers so an uncolored solid blur looks the same.
    static func solidColor(for style: Style) -> CGColor {
        (style.fillColor?.nsColor ?? defaultSolidColor).cgColor
    }

    /// Caches the filtered output so a region isn't re-filtered on every redraw
    /// (hover, selection, scroll). Keyed by source identity + geometry + effect,
    /// so it invalidates automatically when any of those change. Only an active
    /// strength drag (new strength each frame) misses, which is unavoidable work.
    private final class CacheEntry {
        let image: CGImage
        let bbox: CGRect
        init(image: CGImage, bbox: CGRect) { self.image = image; self.bbox = bbox }
    }
    private static let cache: NSCache<NSString, CacheEntry> = {
        let c = NSCache<NSString, CacheEntry>()
        c.countLimit = 64
        return c
    }()

    /// Filtered pixels for `region`, sampled from `source`.
    ///
    /// - Parameters:
    ///   - region: blur region in post-crop **1× image space** (top-left origin).
    ///   - source: the full base `CGImage` (pre-crop), at `scale`× resolution.
    ///   - cropOrigin: the active crop's origin in source 1× space (`.zero` if none).
    ///   - scale: `source` is `scale`× the 1× annotation space (e.g. a 2× enhanced bitmap).
    /// - Returns: the filtered region image plus the **1× image-space** rect it
    ///   occupies (clamped to the image), or nil if the region is degenerate.
    static func filteredRegionImage(
        region: BlurRegion,
        mode: BlurMode,
        strength: Double,
        solidColor: CGColor,
        source: CGImage,
        cropOrigin: CGPoint,
        scale: CGFloat
    ) -> (image: CGImage, bbox: CGRect)? {
        let bbox1x = region.boundingRect
        guard bbox1x.width > 0.5, bbox1x.height > 0.5 else { return nil }

        // Map the 1× region bounds into source pixels, then clamp to the image.
        let baseRect = CGRect(
            x: (bbox1x.minX + cropOrigin.x) * scale,
            y: (bbox1x.minY + cropOrigin.y) * scale,
            width: bbox1x.width * scale,
            height: bbox1x.height * scale
        ).integral.intersection(CGRect(x: 0, y: 0, width: source.width, height: source.height))
        guard !baseRect.isNull, baseRect.width >= 1, baseRect.height >= 1 else { return nil }

        // The clamped 1× rect the filtered pixels correspond to (for drawing).
        let clamped1x = CGRect(
            x: baseRect.minX / scale - cropOrigin.x,
            y: baseRect.minY / scale - cropOrigin.y,
            width: baseRect.width / scale,
            height: baseRect.height / scale
        )

        // Cache hit? Key on source identity + every parameter that changes pixels.
        let srcID = UInt(bitPattern: Unmanaged.passUnretained(source).toOpaque())
        let colorKey = (solidColor.components ?? []).map { String(format: "%.3f", $0) }.joined(separator: ",")
        let key = "\(srcID)|\(scale)|\(cropOrigin.x),\(cropOrigin.y)|\(mode.rawValue)|\(Int((strength * 1000).rounded()))|\(colorKey)|\(region.hashValue)" as NSString
        if let hit = cache.object(forKey: key) {
            return (hit.image, hit.bbox)
        }

        let out: CGImage
        if mode == .solid {
            // Instant block-out: a solid fill of `solidColor`, no sampling. For
            // solid, `strength` is reinterpreted as the fill's opacity (0 clear
            // … 1 fully opaque) so the panel's "Opacity" slider has an effect.
            let extent = CGRect(x: 0, y: 0, width: baseRect.width, height: baseRect.height)
            let base = CIColor(cgColor: solidColor)
            let alpha = max(0, min(1, CGFloat(strength)))
            let tinted = CIColor(red: base.red, green: base.green, blue: base.blue, alpha: alpha)
            let solid = CIImage(color: tinted).cropped(to: extent)
            guard let img = ciContext.createCGImage(solid, from: extent) else { return nil }
            out = img
        } else {
            guard let sub = source.cropping(to: baseRect) else { return nil }
            let input = CIImage(cgImage: sub)
            let extent = input.extent
            let filtered: CIImage
            switch mode {
            case .pixelate:
                let f = CIFilter.pixellate()
                f.inputImage = input
                f.center = CGPoint(x: extent.midX, y: extent.midY)
                f.scale = Float(BlurParams.pixelateScale(forStrength: strength) * scale)
                filtered = (f.outputImage ?? input).cropped(to: extent)
            case .mosaic:
                // Hexagonal cells — a visually distinct "mosaic" vs square pixelate.
                let f = CIFilter.hexagonalPixellate()
                f.inputImage = input
                f.center = CGPoint(x: extent.midX, y: extent.midY)
                f.scale = Float(BlurParams.pixelateScale(forStrength: strength) * scale)
                filtered = (f.outputImage ?? input).cropped(to: extent)
            case .gaussian:
                // Clamp first so the blur doesn't pull in transparent edge pixels.
                let clamp = CIFilter.affineClamp()
                clamp.inputImage = input
                clamp.transform = CGAffineTransform.identity
                let f = CIFilter.gaussianBlur()
                f.inputImage = clamp.outputImage ?? input
                f.radius = Float(BlurParams.gaussianRadius(forStrength: strength) * scale)
                filtered = (f.outputImage ?? input).cropped(to: extent)
            case .solid:
                return nil   // handled above
            }
            guard let img = ciContext.createCGImage(filtered, from: extent) else { return nil }
            out = img
        }

        cache.setObject(CacheEntry(image: out, bbox: clamped1x), forKey: key)
        return (out, clamped1x)
    }

    /// The clip path for a blur region, built in the caller's target space. The
    /// caller supplies the transforms from 1× image space to its context:
    /// `mapRect`/`mapPoint` position the shape and `mapLength` scales the brush
    /// width. Shared so the live canvas and the save renderer clip identically.
    static func clipPath(
        for region: BlurRegion,
        mapRect: (CGRect) -> CGRect,
        mapPoint: (CGPoint) -> CGPoint,
        mapLength: (CGFloat) -> CGFloat
    ) -> NSBezierPath {
        switch region {
        case let .rect(r): return NSBezierPath(rect: mapRect(r.standardized))
        case let .ellipse(r): return NSBezierPath(ovalIn: mapRect(r.standardized))
        case let .freehand(points, width):
            return freehandClipPath(points: points.map(mapPoint), width: mapLength(width))
        }
    }

    /// Rotate/flip a finished clip `path` about `center` (in the caller's
    /// DRAWING space). The blur EXCEPTION: only the mask transforms — the
    /// sampled pixels underneath stay axis-aligned — so callers transform the
    /// clip path here rather than concatenating the whole context. `yDown`
    /// selects the matrix flavor: the live canvas is y-down (`transformMatrix`),
    /// the export renderer's flipY'd space is y-up (`renderMatrix`).
    static func transformedClipPath(_ path: NSBezierPath, transform t: AnnotationTransform,
                                    center: CGPoint, yDown: Bool) -> NSBezierPath {
        guard !t.isIdentity else { return path }
        let m = yDown ? transformMatrix(for: t, center: center)
                      : renderMatrix(for: t, center: center)
        let at = AffineTransform(m11: m.a, m12: m.b, m21: m.c, m22: m.d,
                                 tX: m.tx, tY: m.ty)
        let out = path.copy() as! NSBezierPath
        out.transform(using: at)
        return out
    }

    /// A filled outline path for a freehand brush stroke: the polyline through
    /// `points` stroked at `width`, converted to a fillable region usable as a
    /// clip. `points` and `width` must already be in the caller's target space.
    static func freehandClipPath(points: [CGPoint], width: CGFloat) -> NSBezierPath {
        let cg = CGMutablePath()
        if let first = points.first {
            cg.move(to: first)
            for p in points.dropFirst() { cg.addLine(to: p) }
            if points.count == 1 { cg.addLine(to: first) }
        }
        let stroked = cg.copy(
            strokingWithWidth: max(1, width),
            lineCap: .round,
            lineJoin: .round,
            miterLimit: 10
        )
        return NSBezierPath(cgPath: stroked)
    }
}
