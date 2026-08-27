import AppKit
import CoreImage
import CoreML
import Vision
import os.log

private let log = OSLog(subsystem: "com.seal-shot.sealshot", category: "enhance")

/// Upscales a low-resolution capture to 2×. Uses the bundled
/// `realesr-general-x4v3` Core ML model (tiled 256→1024, then Lanczos-downscaled
/// to 2×) when available; otherwise falls back to a Core Image Lanczos+sharpen.
@MainActor
final class ImageEnhancer {
    nonisolated static let tile = 256
    nonisolated static let modelUpscale = 4
    nonisolated static let outputScale = 2

    nonisolated let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    nonisolated let vnModel: VNCoreMLModel?

    init() {
        self.vnModel = Self.loadModel()
    }

    var isModelAvailable: Bool { vnModel != nil }

    private static func loadModel() -> VNCoreMLModel? {
        guard let url = Bundle.main.url(forResource: "RealESRGeneralX4V3", withExtension: "mlmodelc") else {
            os_log("enhance model .mlmodelc not found in bundle", log: log, type: .error)
            return nil
        }
        do {
            // Default compute units (`.all`) on purpose. `.cpuAndGPU` measured
            // 9% faster in an ISOLATED benchmark but made no difference in the
            // app — per-tile inference was 173.5ms either way — and it
            // explicitly excludes the Neural Engine, which would disable the
            // likely-fastest path on Apple Silicon for a gain that does not
            // exist. Let Core ML choose.
            return try VNCoreMLModel(for: MLModel(contentsOf: url))
        } catch {
            os_log("enhance model load failed: %{public}@", log: log, type: .error, String(describing: error))
            return nil
        }
    }

    /// Enhance with the given params. Stage 1 upscales per `params.scaleFactor`
    /// (1=Off passthrough, 2=2×, 4=4×); Stage 2 applies tunable CI post-process.
    ///
    /// Prefers the model for upscaling; falls back to Core Image Lanczos.
    /// The heavy tiled inference runs off the main actor inside a detached task.
    /// `onProgress` receives values in 0.0…1.0 and is called from a background
    /// thread; the caller is responsible for hopping to the main actor.
    ///
    /// Cooperatively cancellable: cancelling the awaiting task cancels the
    /// detached work, which throws `CancellationError` at the next tile boundary
    /// (model inference of the in-flight tile still finishes first).
    func enhance(_ image: CGImage, params: EnhanceParams,
                 onProgress: (@Sendable (Double) -> Void)? = nil) async throws -> CGImage {
        let model = vnModel
        let ctx = ciContext
        let task = Task.detached(priority: .userInitiated) { () throws -> CGImage in
            // Stage 1: upscale to params.scaleFactor.
            let upscaled: CGImage
            if params.scaleFactor == 1 {
                upscaled = image                          // Off → no upscale
                onProgress?(0.5)
            } else if let model {
                do {
                    upscaled = try enhanceWithModel(image, scale: params.scaleFactor,
                                                    model: model, ciContext: ctx,
                                                    onProgress: onProgress)
                } catch is CancellationError {
                    throw CancellationError()   // don't fall back when the user cancelled
                } catch {
                    os_log("model enhance failed, falling back: %{public}@", log: log, type: .error, String(describing: error))
                    upscaled = enhanceWithCoreImage(image, scale: params.scaleFactor, ciContext: ctx) ?? image
                }
            } else {
                upscaled = enhanceWithCoreImage(image, scale: params.scaleFactor, ciContext: ctx) ?? image
            }
            try Task.checkCancellation()
            // Stage 2: tunable post-process (sharpen/denoise/contrast).
            let result = EnhancePostProcess.apply(upscaled, params: params, ciContext: ctx)
            // A cancel landing DURING post-process (or after the last tile)
            // must not complete as success — the caller would install the
            // result and leave the Enabled switch on.
            try Task.checkCancellation()
            onProgress?(1.0)
            return result
        }
        let result = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        return result
    }

    // MARK: - Core Image fallback (always available, unit-tested)

    /// Lanczos 2× + default post-process. Returns nil only on context failure.
    nonisolated func coreImageEnhance(_ image: CGImage) -> CGImage? {
        guard let upscaled = enhanceWithCoreImage(image, scale: ImageEnhancer.outputScale, ciContext: ciContext) else {
            return nil
        }
        return EnhancePostProcess.apply(upscaled, params: .default, ciContext: ciContext)
    }
}

// MARK: - Private free functions (no actor isolation — safe to call from any thread)

private enum EnhanceError: Error { case context, inference }

/// Lanczos upscale to `scale`×, callable off the main actor.
/// Sharpening is not applied here; callers apply `EnhancePostProcess` afterward.
private func enhanceWithCoreImage(_ image: CGImage, scale: Int, ciContext: CIContext) -> CGImage? {
    let ci = CIImage(cgImage: image)
    guard let lanczos = CIFilter(name: "CILanczosScaleTransform") else { return nil }
    lanczos.setValue(ci, forKey: kCIInputImageKey)
    lanczos.setValue(CGFloat(scale), forKey: kCIInputScaleKey)
    lanczos.setValue(1.0, forKey: kCIInputAspectRatioKey)
    guard let scaled = lanczos.outputImage else { return nil }
    let target = CGRect(x: 0, y: 0,
                        width: image.width * scale,
                        height: image.height * scale)
    return ciContext.createCGImage(scaled, from: target)
}

/// Tiled Core ML 4× upscale then Lanczos downscale to `scale`×, callable off the main actor.
private func enhanceWithModel(
    _ image: CGImage,
    scale: Int,
    model: VNCoreMLModel,
    ciContext: CIContext,
    onProgress: (@Sendable (Double) -> Void)? = nil
) throws -> CGImage {
    let up = ImageEnhancer.modelUpscale
    let bigW = image.width * up, bigH = image.height * up
    guard let ctx = CGContext(
        data: nil, width: bigW, height: bigH, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { throw EnhanceError.context }

    let allTiles = EnhanceGeometry.tiles(imageWidth: image.width, imageHeight: image.height, tile: ImageEnhancer.tile)
    let totalTiles = allTiles.count
    var completed = 0
    for rect in allTiles {
        try Task.checkCancellation()   // bail between tiles when the user cancels
        guard let crop = image.cropping(to: rect) else { throw EnhanceError.inference }
        let padded = try paddedEnhanceTile(crop)
        let outTile = try runEnhanceModel(padded, model: model, ciContext: ciContext)
        let validW = Int(rect.width) * up
        let validH = Int(rect.height) * up
        // Model output is top-left origin; take the valid (un-padded) corner.
        guard let valid = outTile.cropping(to: CGRect(x: 0, y: 0, width: validW, height: validH)) else {
            throw EnhanceError.inference
        }
        // CGContext is bottom-left origin; flip the destination Y.
        let destX = Int(rect.minX) * up
        let destYFromTop = Int(rect.minY) * up
        let destY = bigH - destYFromTop - validH
        ctx.draw(valid, in: CGRect(x: destX, y: destY, width: validW, height: validH))
        completed += 1
        // Reserve the final step for the downscale below, so the bar reaches
        // 100% only when the result is actually ready (not on the last tile).
        onProgress?(Double(completed) / Double(totalTiles + 1))
    }
    guard let big = ctx.makeImage() else { throw EnhanceError.context }
    let result = downscaleEnhanced(big, scale: scale, of: image, ciContext: ciContext) ?? big
    onProgress?(1.0)
    return result
}

/// Place `crop` at the top-left of a `tile`×`tile` RGB image (rest zero-padded),
/// matching the conversion validator's tiling.
private func paddedEnhanceTile(_ crop: CGImage) throws -> CGImage {
    let t = ImageEnhancer.tile
    if crop.width == t && crop.height == t { return crop }
    guard let ctx = CGContext(
        data: nil, width: t, height: t, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { throw EnhanceError.context }
    // top-left placement in bottom-left coords → y = t - height
    ctx.draw(crop, in: CGRect(x: 0, y: t - crop.height, width: crop.width, height: crop.height))
    guard let out = ctx.makeImage() else { throw EnhanceError.context }
    return out
}

private func runEnhanceModel(_ tile: CGImage, model: VNCoreMLModel, ciContext: CIContext) throws -> CGImage {
    let request = VNCoreMLRequest(model: model)
    request.imageCropAndScaleOption = .scaleFill   // tile is already 256×256
    try VNImageRequestHandler(cgImage: tile, options: [:]).perform([request])
    guard let obs = request.results?.first as? VNPixelBufferObservation else {
        throw EnhanceError.inference
    }
    let ci = CIImage(cvPixelBuffer: obs.pixelBuffer)
    guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { throw EnhanceError.inference }
    return cg
}

private func downscaleEnhanced(_ image: CGImage, scale: Int, of original: CGImage, ciContext: CIContext) -> CGImage? {
    let target = CGRect(x: 0, y: 0, width: original.width * scale, height: original.height * scale)
    let ci = CIImage(cgImage: image)
    guard let f = CIFilter(name: "CILanczosScaleTransform") else { return nil }
    // image is 4× original; we want 2× → scale factor = 2/4 = 0.5
    f.setValue(ci, forKey: kCIInputImageKey)
    f.setValue(CGFloat(scale) / CGFloat(ImageEnhancer.modelUpscale), forKey: kCIInputScaleKey)
    f.setValue(1.0, forKey: kCIInputAspectRatioKey)
    guard let out = f.outputImage else { return nil }
    return ciContext.createCGImage(out, from: target)
}
