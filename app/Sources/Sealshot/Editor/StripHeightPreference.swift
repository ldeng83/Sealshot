import CoreGraphics
import Foundation

/// Geometry + persistence for the user-resizable bottom recent strip.
///
/// The strip is resized by dragging the divider above it (`StripResizeHandle`).
/// This type owns the allowed range, the strip⇄thumbnail conversion, the clamp,
/// and the persisted height. The pure functions are unit-tested; persistence is
/// a thin `UserDefaults` wrapper that clamps on read so a hand-edited or stale
/// value can never push the strip out of range.
enum StripHeightPreference {

    /// Non-thumbnail vertical chrome inside the strip: 18pt label + 12+12pt
    /// padding + 15pt legacy scroller + 1pt slack. The thumbnail image height
    /// is `stripHeight - chrome`.
    static let chrome: CGFloat = 58

    /// Smallest strip height (64pt thumbnails).
    static let minHeight: CGFloat = 122
    /// Largest strip height (220pt thumbnails).
    static let maxHeight: CGFloat = 278
    /// Legacy fixed height (88pt thumbnails) — used when nothing is stored yet.
    static let defaultHeight: CGFloat = 146

    private static let key = "stripHeight"

    /// Clamp an arbitrary strip height to the allowed range.
    static func clamp(_ height: CGFloat) -> CGFloat {
        min(maxHeight, max(minHeight, height))
    }

    /// Thumbnail image height for a given strip height.
    static func thumbHeight(forStripHeight height: CGFloat) -> CGFloat {
        height - chrome
    }

    /// Persisted strip height, clamped on read. Falls back to `defaultHeight`
    /// when nothing has been stored.
    static func load(_ defaults: UserDefaults = .standard) -> CGFloat {
        let stored = defaults.object(forKey: key) as? Double
        return clamp(stored.map { CGFloat($0) } ?? defaultHeight)
    }

    /// Persist a strip height (clamped first, so storage stays in range).
    static func store(_ height: CGFloat, into defaults: UserDefaults = .standard) {
        defaults.set(Double(clamp(height)), forKey: key)
    }
}
