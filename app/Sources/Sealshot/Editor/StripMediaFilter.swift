import Foundation

/// Editor recent/deleted-strip media filter: show everything, only images
/// (`.seal`/PNG captures), or only videos (recordings).
enum StripMediaFilter: String, CaseIterable {
    case all, images, videos

    /// Whether an item with the given video-ness passes the filter.
    func includes(isVideo: Bool) -> Bool {
        switch self {
        case .all:    return true
        case .images: return !isVideo
        case .videos: return isVideo
        }
    }
}

/// Persists the strip's media filter across launches (a global UI preference).
enum StripMediaFilterPreference {
    private static let key = "editorStripMediaFilter"

    static func load(_ defaults: UserDefaults = .standard) -> StripMediaFilter {
        defaults.string(forKey: key).flatMap(StripMediaFilter.init(rawValue:)) ?? .all
    }

    static func store(_ filter: StripMediaFilter, _ defaults: UserDefaults = .standard) {
        defaults.set(filter.rawValue, forKey: key)
    }
}
