import Foundation

/// What the recent/deleted strip says when it has no tiles to show.
///
/// Mirrors the Library grid's empty state (`LibraryView.emptyState`), including
/// its distinction between "there is nothing" and "a filter hid everything" —
/// showing the bare empty wording while a filter is on would hide the reason
/// the strip looks empty.
enum StripEmptyMessage {

    /// `nil` while tiles are showing. `totalCount` is the listing BEFORE the
    /// media filter, `displayedCount` after it.
    static func text(displayedCount: Int,
                     totalCount: Int,
                     filter: StripMediaFilter) -> String? {
        guard displayedCount == 0 else { return nil }
        guard totalCount > 0 else { return "No captures here yet." }
        switch filter {
        case .images: return "No images."
        case .videos: return "No videos."
        case .all:    return "No captures here yet."
        }
    }
}
