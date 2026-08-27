import Foundation

/// Persistence for the Library's grid/list view mode, remembered across
/// launches. Default is grid (the historical behavior).
enum LibraryViewModePreference {

    private static let key = "libraryViewMode"

    static func load(_ defaults: UserDefaults = .standard) -> LibraryViewMode {
        guard let raw = defaults.string(forKey: key),
              let mode = LibraryViewMode(rawValue: raw) else { return .grid }
        return mode
    }

    static func store(_ mode: LibraryViewMode, into defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: key)
    }
}
