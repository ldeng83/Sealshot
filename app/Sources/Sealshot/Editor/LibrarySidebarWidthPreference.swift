import CoreGraphics
import Foundation

/// Geometry + persistence for the user-resizable Library sidebar (the left nav
/// panel). Mirrors `SidebarWidthPreference` (the editor's right panel) but uses
/// its own key + range so the two panels remember their widths independently.
/// Pure functions are unit-tested; persistence is a thin `UserDefaults` wrapper
/// that clamps on read so a hand-edited/stale value can never push the panel
/// out of range.
enum LibrarySidebarWidthPreference {

    /// Narrowest before the section/collection rows start clipping.
    static let minWidth: CGFloat = 180
    /// Widest it's allowed to grow (keeps the content grid usable).
    static let maxWidth: CGFloat = 360
    /// Used when nothing is stored yet.
    static let defaultWidth: CGFloat = 232

    private static let key = "librarySidebarWidth"

    /// Clamp an arbitrary width to the allowed range.
    static func clamp(_ width: CGFloat) -> CGFloat {
        min(maxWidth, max(minWidth, width))
    }

    /// Persisted width, clamped on read. Falls back to `defaultWidth` when
    /// nothing has been stored.
    static func load(_ defaults: UserDefaults = .standard) -> CGFloat {
        let stored = defaults.object(forKey: key) as? Double
        return clamp(stored.map { CGFloat($0) } ?? defaultWidth)
    }

    /// Persist a width (clamped first, so storage stays in range).
    static func store(_ width: CGFloat, into defaults: UserDefaults = .standard) {
        defaults.set(Double(clamp(width)), forKey: key)
    }
}
