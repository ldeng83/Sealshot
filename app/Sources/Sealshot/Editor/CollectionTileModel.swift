import Foundation

// Pure helpers backing the album browser's collection tiles: each tile shows a
// representative thumbnail drawn from the newest member of the collection.

/// Newest member of `collectionID` (by `modified`), or nil if the collection is
/// empty in `items`.
func representativeMember(_ items: [LibraryItem], collectionID: UUID) -> LibraryItem? {
    items.filter { $0.collectionIDs.contains(collectionID) }.max { $0.modified < $1.modified }
}

/// Newest favorited item (for the pinned Favorites tile), or nil.
func favoriteRepresentative(_ items: [LibraryItem]) -> LibraryItem? {
    items.filter(\.isFavorite).max { $0.modified < $1.modified }
}
