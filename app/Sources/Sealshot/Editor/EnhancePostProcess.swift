import CoreImage
import CoreGraphics

/// Tunable Core Image post-process applied after upscaling. Pure; off-main safe.
enum EnhancePostProcess {
    static func apply(_ image: CGImage, params: EnhanceParams, ciContext: CIContext) -> CGImage {
        var ci = CIImage(cgImage: image)
        if params.noiseLevel > 0, let f = CIFilter(name: "CINoiseReduction") {
            f.setValue(ci, forKey: kCIInputImageKey)
            f.setValue(params.noiseLevel, forKey: "inputNoiseLevel")
            f.setValue(0.4, forKey: "inputSharpness")
            ci = f.outputImage ?? ci
        }
        if params.unsharpIntensity > 0, let f = CIFilter(name: "CIUnsharpMask") {
            f.setValue(ci, forKey: kCIInputImageKey)
            f.setValue(1.2, forKey: kCIInputRadiusKey)
            f.setValue(params.unsharpIntensity, forKey: kCIInputIntensityKey)
            ci = f.outputImage ?? ci
        }
        if params.contrastFactor != 1.0, let f = CIFilter(name: "CIColorControls") {
            f.setValue(ci, forKey: kCIInputImageKey)
            f.setValue(params.contrastFactor, forKey: kCIInputContrastKey)
            ci = f.outputImage ?? ci
        }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        return ciContext.createCGImage(ci, from: rect) ?? image
    }
}
