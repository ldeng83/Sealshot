import Foundation

/// User-adjustable clarity parameters for the Enhance panel. Pure value type;
/// the mapping accessors convert the 0–100 UI ranges to Core Image filter values.
struct EnhanceParams: Codable, Equatable {
    enum Upscale: String, Codable, CaseIterable { case off, x2, x4 }

    var upscale: Upscale
    var sharpness: Int        // 0–100
    var noiseReduction: Int   // 0–100
    var contrast: Int         // 0–100

    static let `default` = EnhanceParams(upscale: .x2, sharpness: 25,
                                         noiseReduction: 0, contrast: 0)

    var scaleFactor: Int { switch upscale { case .off: 1; case .x2: 2; case .x4: 4 } }
    /// CIUnsharpMask intensity 0…2 (25 ≈ the prior fixed 0.5).
    var unsharpIntensity: Double { Double(sharpness) / 100.0 * 2.0 }
    /// CINoiseReduction inputNoiseLevel 0…0.05.
    var noiseLevel: Double { Double(noiseReduction) / 100.0 * 0.05 }
    /// CIColorControls contrast 1.0…1.3.
    var contrastFactor: Double { 1.0 + Double(contrast) / 100.0 * 0.3 }
}
