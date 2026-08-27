import Foundation

/// Narrows the Library grid by capture media kind. Replaces the old
/// Images/Videos sections.
enum LibraryFileTypeFilter: String, CaseIterable, Identifiable {
    case all = "All Files"
    case images = "Images"
    case videos = "Videos"
    var id: String { rawValue }
    var title: String { self == .all ? "All" : rawValue }
    func matches(isVideo: Bool) -> Bool {
        switch self {
        case .all: return true
        case .images: return !isVideo
        case .videos: return isVideo
        }
    }
}

/// What the Library grid is scoped to within the Collections section (or via the
/// Favorites built-in). `.favorites` maps to the existing isFavorite flag.
enum LibraryCollectionSelection: Equatable {
    case none
    case favorites
    case collection(UUID)
    func matches(isFavorite: Bool, collectionIDs: [UUID]) -> Bool {
        switch self {
        case .none: return true
        case .favorites: return isFavorite
        case .collection(let id): return collectionIDs.contains(id)
        }
    }
}

