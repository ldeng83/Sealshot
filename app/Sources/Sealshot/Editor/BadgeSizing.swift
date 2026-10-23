import CoreGraphics

/// Step (badge) size bounds and default, scaled to the image (radius in image
/// pixels). A fixed range read wrong at both ends: a Retina capture's steps
/// topped out small at 60, and a fixed default looked tiny on a large capture
/// and oversized on a small crop. The size slider, the handle drag and
/// creation all clamp to the same range.
enum BadgeSizing {
    static let minRadius: CGFloat = 8
    /// Never narrower than the old fixed 8…60 range.
    static let minMaxRadius: CGFloat = 60
    /// Max radius as a fraction of the image's shorter side (1080p → 108,
    /// a 2160px-tall Retina capture → 216).
    static let maxFraction: CGFloat = 0.10
    /// Default radius as a fraction of the shorter side (2160px tall → ~65,
    /// 1080p → ~32).
    static let defaultFraction: CGFloat = 0.03

    static func range(for imageSize: CGSize) -> ClosedRange<CGFloat> {
        minRadius...max(minMaxRadius, shortSide(imageSize) * maxFraction)
    }

    static func defaultRadius(for imageSize: CGSize) -> CGFloat {
        clamp(shortSide(imageSize) * defaultFraction, for: imageSize)
    }

    static func clamp(_ radius: CGFloat, for imageSize: CGSize) -> CGFloat {
        let r = range(for: imageSize)
        return min(max(radius, r.lowerBound), r.upperBound)
    }

    private static func shortSide(_ size: CGSize) -> CGFloat { min(size.width, size.height) }
}
