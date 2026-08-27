import Foundation

/// Last-captured area-selection size in pixels, persisted across launches so
/// a cmd+click can recall it. Pure + `UserDefaults`; `nil` until a size has
/// been captured. Only positive sizes persist.
enum SelectionSizePreference {
    private static let widthKey = "selectionSizePixelWidth"
    private static let heightKey = "selectionSizePixelHeight"

    static func current(_ defaults: UserDefaults = .standard) -> (width: Int, height: Int)? {
        guard let w = defaults.object(forKey: widthKey) as? Int,
              let h = defaults.object(forKey: heightKey) as? Int,
              w > 0, h > 0 else { return nil }
        return (w, h)
    }

    static func set(width: Int, height: Int, into defaults: UserDefaults = .standard) {
        guard width > 0, height > 0 else { return }
        defaults.set(width, forKey: widthKey)
        defaults.set(height, forKey: heightKey)
    }
}
