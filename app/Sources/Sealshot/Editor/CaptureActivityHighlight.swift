import Foundation

extension URL {
    /// Canonical key for activity-highlight matching. `URL ==` is unreliable
    /// for file URLs built different ways (the same file gets different
    /// representations via `appendingPathComponent` vs the index/FileManager),
    /// so compare standardized filesystem paths instead.
    var activityHighlightKey: String { standardizedFileURL.path }
}

/// Dismissal rule for the persistent delete/restore highlight: clicking a
/// marked item keeps the marks; clicking anything else (a non-marked item or
/// empty space) dismisses them. Pure, operates on `activityHighlightKey`s.
enum ActivityHighlightDismissal {
    /// Whether a click should clear the current marks. `clicked == nil` means
    /// empty space.
    static func shouldDismiss(marked: Set<String>, clicked: String?) -> Bool {
        guard !marked.isEmpty else { return false }
        guard let clicked else { return true }   // empty space → dismiss
        return !marked.contains(clicked)         // a non-marked item → dismiss
    }
}

/// App-wide source of truth for the persistent delete/restore highlight.
///
/// Centralized (not per-view) on purpose: the recent/deleted strips and the
/// Library view model are created lazily and can be rebuilt, so per-view marks
/// fed by a transient notification were lost for any action that happened
/// before the view existed. Here the marks accumulate in one place; views read
/// it whenever they appear or refresh, and observe `.changed` to repaint.
@MainActor
final class ActivityHighlightStore {
    static let shared = ActivityHighlightStore()

    /// Posted on every mutation so strips / Library can repaint.
    static let changed = Notification.Name("activityHighlightChanged")

    private(set) var keys: Set<String> = []

    /// Add a batch of landed URLs (delete/restore or undo/redo). Accumulates.
    func mark(_ urls: [URL]) {
        let new = Set(urls.map(\.activityHighlightKey))
        guard !new.isEmpty else { return }
        keys.formUnion(new)
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    /// Clear the marks if a click lands outside them (non-marked item, or empty
    /// space when `clicked` is nil); a click on a marked item keeps them.
    func dismiss(clicked: URL?) {
        guard ActivityHighlightDismissal.shouldDismiss(
            marked: keys, clicked: clicked?.activityHighlightKey) else { return }
        keys.removeAll()
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    func contains(_ url: URL) -> Bool { keys.contains(url.activityHighlightKey) }
}
