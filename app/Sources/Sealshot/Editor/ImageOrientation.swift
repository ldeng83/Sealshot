import CoreGraphics
import Foundation

/// One whole-image orientation step (Image ▸ Rotate / Flip).
enum ImageOrientationStep: CaseIterable, Equatable {
    case rotateLeft, rotateRight, flipHorizontal, flipVertical

    var actionName: String {
        switch self {
        case .rotateLeft: return "Rotate Left"
        case .rotateRight: return "Rotate Right"
        case .flipHorizontal: return "Flip Image Horizontal"
        case .flipVertical: return "Flip Image Vertical"
        }
    }

    var swapsAxes: Bool { self == .rotateLeft || self == .rotateRight }

    /// The step's map from a `size` image to the result, in IMAGE space
    /// (top-left origin, y down). Rotations are 90° about the canvas; the
    /// result of a rotation is `size` transposed.
    func transform(for size: CGSize) -> CGAffineTransform {
        let w = size.width, h = size.height
        switch self {
        case .rotateRight:    return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        case .rotateLeft:     return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        case .flipHorizontal: return CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)
        case .flipVertical:   return CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)
        }
    }

    func resultSize(for size: CGSize) -> CGSize {
        swapsAxes ? CGSize(width: size.height, height: size.width) : size
    }
}

/// The document's orientation relative to `source.png`, which is never
/// rewritten (Sealshot leaves original pixels untouched — same contract as
/// Resize). Persisted in annotations.json (v13) and applied on open, BEFORE
/// the crop and any Resize. Read as: mirror left-right first when `mirrored`,
/// then rotate `quarterTurns` × 90° clockwise. Every element of the square's
/// symmetry group has exactly one such form, so equal orientations compare equal.
struct ImageOrientation: Codable, Equatable {
    var quarterTurns: Int = 0
    var mirrored: Bool = false

    static let identity = ImageOrientation()
    var isIdentity: Bool { quarterTurns == 0 && !mirrored }

    init(quarterTurns: Int = 0, mirrored: Bool = false) {
        self.quarterTurns = ((quarterTurns % 4) + 4) % 4
        self.mirrored = mirrored
    }

    /// Decoded values come from a file that may have been shared with the
    /// user, so `quarterTurns` is brought into 0...3: a negative count would
    /// trap in `steps`, and a huge one would turn the image millions of times.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(quarterTurns: try c.decodeIfPresent(Int.self, forKey: .quarterTurns) ?? 0,
                  mirrored: try c.decodeIfPresent(Bool.self, forKey: .mirrored) ?? false)
    }

    /// This orientation followed by `step`.
    func then(_ step: ImageOrientationStep) -> ImageOrientation {
        switch step {
        case .rotateRight:
            return ImageOrientation(quarterTurns: (quarterTurns + 1) % 4, mirrored: mirrored)
        case .rotateLeft:
            return ImageOrientation(quarterTurns: (quarterTurns + 3) % 4, mirrored: mirrored)
        case .flipHorizontal:
            // H·R^k = R^(−k)·H: a mirror reverses the turns that precede it.
            return ImageOrientation(quarterTurns: (4 - quarterTurns) % 4, mirrored: !mirrored)
        case .flipVertical:
            // V = R²·H.
            let h = then(.flipHorizontal)
            return ImageOrientation(quarterTurns: (h.quarterTurns + 2) % 4, mirrored: h.mirrored)
        }
    }

    /// Undoes this orientation. A mirrored orientation is a reflection, so it
    /// is its own inverse.
    var inverse: ImageOrientation {
        mirrored ? self : ImageOrientation(quarterTurns: (4 - quarterTurns) % 4)
    }

    /// The steps that build this orientation from identity, in order.
    var steps: [ImageOrientationStep] {
        (mirrored ? [.flipHorizontal] : []) + Array(repeating: .rotateRight, count: quarterTurns)
    }

    /// The orientation that takes `self` to `target`.
    func relative(to target: ImageOrientation) -> ImageOrientation {
        Self.compose(inverse, then: target)
    }

    /// `first` followed by `second`.
    static func compose(_ first: ImageOrientation, then second: ImageOrientation) -> ImageOrientation {
        second.steps.reduce(first) { $0.then($1) }
    }
}

// MARK: - Pixels

enum ImageOrientationRenderer {

    /// `image` with `step` applied. Exact: a quarter turn or mirror only moves
    /// pixels, so nothing is resampled. Nil only if no bitmap context can be made.
    static func apply(_ step: ImageOrientationStep, to image: CGImage) -> CGImage? {
        let size = CGSize(width: image.width, height: image.height)
        let out = step.resultSize(for: size)
        guard let ctx = context(width: Int(out.width), height: Int(out.height), like: image) else { return nil }
        // `transform(for:)` is y-down; CGContext is y-up. Conjugate by the
        // vertical flip of each side.
        let flipIn = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: size.height)
        let flipOut = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: out.height)
        ctx.interpolationQuality = .none
        ctx.concatenate(flipIn.concatenating(step.transform(for: size)).concatenating(flipOut))
        ctx.draw(image, in: CGRect(origin: .zero, size: size))
        return ctx.makeImage()
    }

    /// `image` with every step of `orientation` applied.
    static func apply(_ orientation: ImageOrientation, to image: CGImage) -> CGImage? {
        orientation.steps.reduce(Optional(image)) { img, step in img.flatMap { apply(step, to: $0) } }
    }

    /// A context matching `image`'s depth where CoreGraphics supports it, else
    /// 8-bit sRGB.
    private static func context(width: Int, height: Int, like image: CGImage) -> CGContext? {
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        if let space = image.colorSpace, space.model == .rgb,
           let ctx = CGContext(data: nil, width: width, height: height,
                               bitsPerComponent: image.bitsPerComponent == 16 ? 16 : 8,
                               bytesPerRow: 0, space: space, bitmapInfo: info) {
            return ctx
        }
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                         bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                         bitmapInfo: info)
    }
}

// MARK: - Document

extension EditorState {

    /// A fresh state that is this document after `step` — the Image ▸ Rotate /
    /// Flip counterpart of Resize's rebuild (`applyDocumentResize`). Every
    /// bitmap turns with it (they're exact pixel moves, so the enhanced and
    /// cutout bases survive, unlike a resample); the crop/grow rects map in
    /// source space, annotations and focus in visible space. Nil if a bitmap
    /// can't be transformed. The caller records the undo checkpoint and swaps.
    func reoriented(by step: ImageOrientationStep) -> EditorState? {
        func turned(_ image: CGImage) -> CGImage? { ImageOrientationRenderer.apply(step, to: image) }
        guard let base = turned(sourceImage) else { return nil }
        var pristine: CGImage?
        if let p = pristineSource {
            guard let t = turned(p) else { return nil }
            pristine = t
        }
        let newOrientation = orientation.then(step)
        let fresh = EditorState(
            sourceImage: base,
            sourceURL: sourceURL,
            enhancedImage: enhancedImage.flatMap(turned),
            showingEnhanced: showingEnhanced,
            pristineSource: pristine,
            orientation: newOrientation,
            unorientedSource: persistedSourceImage)

        let sourceSize = CGSize(width: sourceImage.width, height: sourceImage.height)
        let sourceT = step.transform(for: sourceSize)
        let visibleT = step.transform(for: visibleImageSize)
        fresh.annotations = ImageOrientationMath.annotations(annotations, after: step, in: visibleImageSize)
        fresh.croppedRect = croppedRect.map { $0.applying(sourceT).standardized }
        fresh.contentClip = contentClip.map { $0.applying(sourceT).standardized }
        fresh.focusRect = focusRect.map { $0.applying(visibleT).standardized }
        fresh.cutoutImage = cutoutImage.flatMap(turned)
        fresh.setShowingCutout(showingCutout)
        fresh.enhanceParams = enhanceParams
        fresh.enhanceDraft = enhanceDraft
        fresh.imageAssets = imageAssets
        fresh.isReadOnly = isReadOnly
        fresh.backgroundFill = backgroundFill
        // Captured-layout frames are in the ORIGINAL orientation, which is
        // exactly where Revert to Original (scene-aware) puts them back.
        fresh.sceneOriginalFrames = sceneOriginalFrames
        fresh.markDirty()
        return fresh
    }

    /// This document turned to `target` (e.g. `.identity` for Reset
    /// Orientation): the steps between the two, applied in order. Nil if a
    /// step fails; `self` when already there.
    func reoriented(to target: ImageOrientation) -> EditorState? {
        orientation.relative(to: target).steps.reduce(Optional(self)) { state, step in
            state?.reoriented(by: step)
        }
    }
}

// MARK: - Annotations

/// Moves annotations with the image. Shapes, arrows, strokes, blur regions and
/// cuts land exactly over the same pixels (a redaction must keep covering what
/// it covered). Bitmap layers turn with the image. Text and badges only move:
/// they stay upright and unmirrored so they remain readable.
enum ImageOrientationMath {

    /// `annotations` in a `size` (visible-image space) document after `step`.
    static func annotations(_ annotations: [Annotation], after step: ImageOrientationStep,
                            in size: CGSize) -> [Annotation] {
        let t = step.transform(for: size)
        return annotations.map { annotation($0, after: step, transform: t) }
    }

    static func annotation(_ a: Annotation, after step: ImageOrientationStep,
                           transform t: CGAffineTransform) -> Annotation {
        var out = a
        func p(_ point: CGPoint) -> CGPoint { point.applying(t) }
        func r(_ rect: CGRect) -> CGRect { rect.standardized.applying(t).standardized }
        /// Same size, centre carried — for content that must not be stretched.
        func moved(_ rect: CGRect) -> CGRect {
            let c = CGPoint(x: rect.midX, y: rect.midY).applying(t)
            return CGRect(x: c.x - rect.width / 2, y: c.y - rect.height / 2,
                          width: rect.width, height: rect.height)
        }
        switch a.geometry {
        case let .arrow(s, e):     out.geometry = .arrow(start: p(s), end: p(e))
        case let .line(s, e):      out.geometry = .line(start: p(s), end: p(e))
        case let .rectangle(rect): out.geometry = .rectangle(rect: r(rect))
        case let .ellipse(rect):   out.geometry = .ellipse(rect: r(rect))
        case let .cut(rect):       out.geometry = .cut(rect: r(rect))
        case let .pen(points):     out.geometry = .pen(points: points.map(p))
        case let .penArrow(points): out.geometry = .penArrow(points: points.map(p))
        case let .blur(region):
            switch region {
            case let .rect(rect):    out.geometry = .blur(region: .rect(r(rect)))
            case let .ellipse(rect): out.geometry = .blur(region: .ellipse(r(rect)))
            case let .freehand(points, width):
                out.geometry = .blur(region: .freehand(points: points.map(p), width: width))
            }
        case let .text(rect, runs):
            out.geometry = .text(rect: moved(rect), runs: runs)
            return out   // upright: transform unchanged
        case let .badge(center, radius):
            out.geometry = .badge(center: p(center), radius: radius)
            return out
        case let .image(rect, assetID):
            out.geometry = .image(rect: moved(rect), assetID: assetID)
            out.transform = turnedWithImage(a.transform, step: step)
            return out
        }
        out.transform = mappedGeometryTransform(a.transform, step: step)
        return out
    }

    /// Display is R(θ)·S about the centre (`transformMatrix`). For content kept
    /// at its own size (bitmap layers), the whole scene's turn or mirror lands on
    /// the transform: N·R(θ)·S = R(θ ± 90°)·S for a quarter turn, R(−θ)·(S with
    /// that axis toggled) for a mirror.
    static func turnedWithImage(_ t: AnnotationTransform, step: ImageOrientationStep) -> AnnotationTransform {
        switch step {
        case .rotateRight:
            return AnnotationTransform(rotationDegrees: normalizedDegrees(t.rotationDegrees + 90),
                                       flipH: t.flipH, flipV: t.flipV)
        case .rotateLeft:
            return AnnotationTransform(rotationDegrees: normalizedDegrees(t.rotationDegrees - 90),
                                       flipH: t.flipH, flipV: t.flipV)
        case .flipHorizontal: return t.flippedH()
        case .flipVertical:   return t.flippedV()
        }
    }

    /// For geometry whose points/rects were mapped themselves, what's left for
    /// the transform is N·R(θ)·S·N⁻¹ = R(±θ)·(N·S·N⁻¹): a quarter turn keeps θ
    /// and swaps the flip axes; a mirror negates θ and keeps the flips.
    static func mappedGeometryTransform(_ t: AnnotationTransform,
                                        step: ImageOrientationStep) -> AnnotationTransform {
        guard !t.isIdentity else { return t }
        if step.swapsAxes {
            return AnnotationTransform(rotationDegrees: t.rotationDegrees, flipH: t.flipV, flipV: t.flipH)
        }
        return AnnotationTransform(rotationDegrees: normalizedDegrees(-t.rotationDegrees),
                                   flipH: t.flipH, flipV: t.flipV)
    }
}
