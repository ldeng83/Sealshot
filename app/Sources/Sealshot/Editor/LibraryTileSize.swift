import Foundation
import CoreGraphics

/// Geometry for the Library grid's user-adjustable tile size. `width` is the
/// adaptive grid item's minimum (which drives column reflow); the card's
/// thumbnail height is derived from it to keep the historical 180→120 aspect.
enum LibraryTileSize {

    /// Smallest tile the slider allows — still legible.
    static let min: CGFloat = 120
    /// Largest tile. The 720px thumbnail cap (see
    /// CaptureThumbnail.captureThumbnailMaxPixel) keeps tiles fully crisp up to
    /// ~360pt on Retina; beyond that, up to this max, thumbnails upscale and
    /// soften slightly — an accepted trade for roomier previews.
    static let max: CGFloat = 480
    /// Slider quantization — reflows the grid at most a handful of times per drag.
    static let step: CGFloat = 20
    /// Shipping default tile width (a valid 20pt stop).
    static let `default`: CGFloat = 280

    /// Thumbnail height per unit width, preserving the original 180→120 card.
    private static let heightRatio: CGFloat = 120.0 / 180.0

    /// Clamp `width` to `[min, max]`, then snap to the nearest `step`.
    static func snap(_ width: CGFloat) -> CGFloat {
        let clamped = Swift.min(Swift.max(width, min), max)
        return (clamped / step).rounded() * step
    }

    /// Card thumbnail height for a given tile width.
    static func height(forWidth width: CGFloat) -> CGFloat {
        (width * heightRatio).rounded()
    }
}

/// Persistence for the Library tile width, remembered across launches and
/// shared by every Library tab. Mirrors `LibrarySortPreference`.
enum LibraryTileSizePreference {

    private static let key = "libraryTileWidth"

    static func load(_ defaults: UserDefaults = .standard) -> CGFloat {
        guard let raw = defaults.object(forKey: key) as? Double else {
            return LibraryTileSize.default
        }
        return LibraryTileSize.snap(CGFloat(raw))
    }

    static func store(_ width: CGFloat, into defaults: UserDefaults = .standard) {
        defaults.set(Double(LibraryTileSize.snap(width)), forKey: key)
    }
}
