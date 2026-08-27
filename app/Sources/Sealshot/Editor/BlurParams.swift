import CoreGraphics

/// Maps a normalized blur strength (0…1) to the concrete Core Image filter
/// parameter for each `BlurMode`. Kept pure and separate so the live canvas and
/// the save renderer derive identical parameters, and so the mapping is
/// unit-testable without Core Image.
enum BlurParams {

    /// `CIPixellate` input scale (block edge length, px) for a given strength.
    /// Strength 0 → 4px blocks (subtle); strength 1 → 40px blocks (heavy).
    static func pixelateScale(forStrength strength: Double) -> CGFloat {
        let s = clamp(strength)
        return CGFloat(4 + s * 36)
    }

    /// `CIGaussianBlur` radius (px) for a given strength. Strength 0 → 2px
    /// (subtle); strength 1 → 32px (heavy).
    static func gaussianRadius(forStrength strength: Double) -> CGFloat {
        let s = clamp(strength)
        return CGFloat(2 + s * 30)
    }

    /// Clamp an arbitrary strength to the supported 0…1 range.
    static func clamp(_ strength: Double) -> Double {
        min(1, max(0, strength))
    }
}
