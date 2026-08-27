import Foundation

/// What the Library grid is sorted by.
enum LibrarySortField: String, CaseIterable, Equatable {
    case date, name, size, sourceApp, dimensions

    var displayName: String {
        switch self {
        case .date: return "Date"
        case .name: return "Name"
        case .size: return "Size"
        case .sourceApp: return "App"
        case .dimensions: return "Dimensions"
        }
    }

    /// The direction a field switches to when first chosen — newest/largest
    /// first for date/size; A→Z for name.
    var defaultDirection: LibrarySortDirection {
        switch self {
        case .date, .size: return .descending
        case .name: return .ascending
        case .sourceApp: return .ascending
        case .dimensions: return .descending
        }
    }
}

enum LibrarySortDirection: Equatable {
    case ascending, descending
}

struct LibrarySort: Equatable {
    var field: LibrarySortField
    var direction: LibrarySortDirection

    /// Today's behavior: newest capture first.
    static let `default` = LibrarySort(field: .date, direction: .descending)
}

/// Pure sort of Library items by the chosen field/direction. Equal keys fall
/// back to capture-date descending so ties read newest-first.
func sortLibraryItems(_ items: [LibraryItem], by sort: LibrarySort) -> [LibraryItem] {
    let asc = sort.direction == .ascending
    func ordered(_ r: ComparisonResult) -> Bool {
        asc ? r == .orderedAscending : r == .orderedDescending
    }
    return items.sorted { a, b in
        switch sort.field {
        case .date:
            if a.modified != b.modified { return asc ? a.modified < b.modified : a.modified > b.modified }
        case .name:
            let r = a.displayName.compare(b.displayName, options: [.caseInsensitive, .diacriticInsensitive])
            if r != .orderedSame { return ordered(r) }
        case .size:
            if a.fileSize != b.fileSize { return asc ? a.fileSize < b.fileSize : a.fileSize > b.fileSize }
        case .sourceApp:
            let an = a.sourceApp, bn = b.sourceApp
            if (an == nil) != (bn == nil) { return bn == nil }   // nil last, both directions
            if let an, let bn {
                let r = an.compare(bn, options: [.caseInsensitive, .diacriticInsensitive])
                if r != .orderedSame { return ordered(r) }
            }
        case .dimensions:
            let aa = a.dimensions.map { $0.w * $0.h }
            let bb = b.dimensions.map { $0.w * $0.h }
            if (aa == nil) != (bb == nil) { return bb == nil }   // nil last, both directions
            if let aa, let bb, aa != bb { return asc ? aa < bb : aa > bb }
        }
        // Tie-break: newest capture first, then a stable URL key so equal-date
        // items keep a deterministic order independent of the index query order.
        // Without this, the per-file metadata reloads during a multi-file import
        // (whose `.seal`s share a second-precision capture date) reshuffle the
        // grid until the last reload settles.
        if a.modified != b.modified { return a.modified > b.modified }
        return a.url.path.localizedCaseInsensitiveCompare(b.url.path) == .orderedAscending
    }
}
