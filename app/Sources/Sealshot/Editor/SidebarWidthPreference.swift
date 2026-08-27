import CoreGraphics
import Foundation

/// Geometry + persistence for the user-resizable right tool-properties sidebar.
///
/// The sidebar is resized by dragging the split divider on its leading edge.
/// This type owns the allowed width range, the clamp, and the persisted width.
/// Pure functions are unit-tested; persistence is a thin `UserDefaults` wrapper
/// that clamps on read so a hand-edited or stale value can never push the
/// sidebar out of range.
enum SidebarWidthPreference {

    /// Narrowest the property panel can get before controls start clipping.
    static let minWidth: CGFloat = 200
    /// Widest it's allowed to grow (keeps the canvas usable).
    static let maxWidth: CGFloat = 420
    /// `EditorSidebarView.width` — used when nothing is stored yet.
    static let defaultWidth: CGFloat = 240

    private static let key = "sidebarWidth"

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
