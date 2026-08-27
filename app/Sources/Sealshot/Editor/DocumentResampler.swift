import CoreGraphics
import CoreImage
import Foundation

/// High-quality resample for the document Resize feature: Lanczos in both
/// directions (the same filter the Enhance pipeline uses), with independent
/// horizontal/vertical scales so an unlocked (stretch) resize works. Falls
/// back to a `.high`-interpolation CGContext draw if Core Image fails.
enum DocumentResampler {

    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    static func resample(_ image: CGImage, to target: CGSize) -> CGImage? {
        let w = Int(target.width.rounded()), h = Int(target.height.rounded())
        guard w > 0, h > 0 else { return nil }
        if w == image.width, h == image.height { return image }
        if let lanczos = lanczosResample(image, width: w, height: h) { return lanczos }
        return contextResample(image, width: w, height: h)
    }

    private static func lanczosResample(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard let filter = CIFilter(name: "CILanczosScaleTransform") else { return nil }
        let scaleY = CGFloat(height) / CGFloat(image.height)
        let scaleX = CGFloat(width) / CGFloat(image.width)
        filter.setValue(CIImage(cgImage: image), forKey: kCIInputImageKey)
        filter.setValue(scaleY, forKey: kCIInputScaleKey)
        // Aspect ratio corrects the horizontal axis relative to the vertical
        // scale — 1.0 for a uniform resize, ≠1 for an unlocked stretch.
        filter.setValue(scaleX / scaleY, forKey: kCIInputAspectRatioKey)
        guard let out = filter.outputImage else { return nil }
        return ciContext.createCGImage(out, from: CGRect(x: 0, y: 0, width: width, height: height))
    }

    private static func contextResample(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }
}
