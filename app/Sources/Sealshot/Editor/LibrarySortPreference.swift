import Foundation

/// Persistence for the Library grid's sort (field + direction), remembered
/// across launches. Default is Date, newest-first (the historical behavior).
enum LibrarySortPreference {

    private static let fieldKey = "librarySortField"
    private static let ascendingKey = "librarySortAscending"

    static func load(_ defaults: UserDefaults = .standard) -> LibrarySort {
        guard let raw = defaults.string(forKey: fieldKey),
              let field = LibrarySortField(rawValue: raw) else { return .default }
        let ascending = defaults.bool(forKey: ascendingKey)
        return LibrarySort(field: field, direction: ascending ? .ascending : .descending)
    }

    static func store(_ sort: LibrarySort, into defaults: UserDefaults = .standard) {
        defaults.set(sort.field.rawValue, forKey: fieldKey)
        defaults.set(sort.direction == .ascending, forKey: ascendingKey)
    }
}
