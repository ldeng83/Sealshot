import Foundation

/// Returns the URLs of items that belong to `collectionID`.
///
/// Used to prune membership when a collection is deleted, and reusable for
/// per-collection counts. Items outside the passed-in list are simply not
/// pruned — orphan-tolerant by design (see deleteCollection).
func collectionMemberURLs(_ items: [LibraryItem], collectionID: UUID) -> [URL] {
    items.filter { $0.collectionIDs.contains(collectionID) }.map(\.url)
}
