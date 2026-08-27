import Foundation

/// Persistence for whether the editor's bottom recent strip is hidden.
///
/// The strip is collapsed/shown by the chevron toggle in the editor meta row
/// (and the ⌥⌘S shortcut). This type is a thin `UserDefaults` wrapper, kept
/// separate from `StripHeightPreference` so each preference stays
/// single-purpose. Default is *visible* — a fresh install shows the strip.
enum StripVisibilityPreference {

    private static let key = "stripHidden"

    /// Whether the strip should start hidden. Defaults to `false` (visible)
    /// when nothing has been stored.
    static func isHidden(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key)
    }

    /// Persist the hidden state.
    static func store(_ hidden: Bool, into defaults: UserDefaults = .standard) {
        defaults.set(hidden, forKey: key)
    }
}
