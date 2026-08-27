import Foundation

/// Sort a `(tag, count)` list case-insensitively A→Z for the BY TAG facet.
func sortedTagsAlphabetically(_ raw: [(tag: String, count: Int)]) -> [(tag: String, count: Int)] {
    raw.sorted { $0.tag.localizedCaseInsensitiveCompare($1.tag) == .orderedAscending }
}

/// AND match: an item passes when it carries EVERY selected tag. An empty
/// selection matches everything (no filter).
func libraryItemMatchesTags(itemTags: [String], selected: Set<String>) -> Bool {
    selected.isSubset(of: Set(itemTags))
}
