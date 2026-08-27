import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision

/// On-device background removal via Apple's subject-lifting mask (the same
/// machinery behind Preview's "Remove Background"). Produces a transparent
/// cutout at the input's exact pixel size — used as a toggle-able alternate
/// base like the Enhance image. No models shipped; macOS 14 API, same as the
/// app floor. Validated on real images via the scratchpad `bgpreview` harness
/// before building (soft matte; struggles on hair-vs-busy-background and
/// translucency; UI screenshots usually have no subject at all).
enum BackgroundRemover {

    enum Outcome {
        case cutout(CGImage)
        /// Vision ran fine but found nothing liftable (typical for UI
        /// screenshots) — surfaced as a quiet toast, never an error.
        case noSubject
        case failed
    }

    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// Off-main compute; result hops back to the caller's actor.
    /// `focusInSource` (image pixel space, top-left origin — map a visible-
    /// space focus through the crop first, see `EditorState.aiOCRRect`)
    /// constrains the subject search to that region: the mask runs on ONLY
    /// those pixels, and everything outside is background → transparent.
    static func removeBackground(from image: CGImage,
                                 focusInSource: CGRect? = nil) async -> Outcome {
        await Task.detached(priority: .userInitiated) {
            guard let focus = focusInSource?.integral,
                  focus.width >= 8, focus.height >= 8,
                  focus != CGRect(x: 0, y: 0, width: image.width, height: image.height)
            else { return compute(image) }
            let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            let clamped = focus.intersection(bounds)
            guard !clamped.isEmpty, let sub = image.cropping(to: clamped) else {
                return compute(image)
            }
            switch compute(sub) {
            case .cutout(let subCutout):
                // Place the focus-area cutout back into a full-size clear
                // canvas (CG context is bottom-left origin; the crop rect is
                // top-left) — everything outside the focus stays transparent.
                guard let ctx = CGContext(
                    data: nil, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { return .failed }
                ctx.draw(subCutout, in: CGRect(
                    x: clamped.minX,
                    y: CGFloat(image.height) - clamped.maxY,
                    width: clamped.width, height: clamped.height))
                guard let out = ctx.makeImage() else { return .failed }
                return .cutout(out)
            case .noSubject: return .noSubject
            case .failed: return .failed
            }
        }.value
    }

    private static func compute(_ image: CGImage) -> Outcome {
        let handler = VNImageRequestHandler(cgImage: image)
        let request = VNGenerateForegroundInstanceMaskRequest()
        do {
            try handler.perform([request])
        } catch {
            return .failed
        }
        guard let observation = request.results?.first,
              !observation.allInstances.isEmpty else { return .noSubject }
        do {
            let buffer = try observation.generateScaledMaskForImage(
                forInstances: observation.allInstances, from: handler)
            let matte = CIImage(cvPixelBuffer: buffer)
            let src = CIImage(cgImage: image)
            let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0))
                .cropped(to: src.extent)
            let blend = CIFilter.blendWithMask()
            blend.inputImage = src
            blend.backgroundImage = clear
            blend.maskImage = matte
            guard let out = blend.outputImage,
                  let cg = ciContext.createCGImage(out, from: src.extent) else { return .failed }
            return .cutout(cg)
        } catch {
            return .failed
        }
    }
}
