import Foundation

/// Holds a Find-in-Image query back until typing pauses.
///
/// Every keystroke used to drive `state.imageTextSearchQuery` straight through,
/// and each change re-ran the match over the capture's text and repainted the
/// canvas. An eight-letter word therefore cost eight full passes, seven of them
/// for prefixes nobody wanted results for — which on a large capture on Intel
/// shows up as the field lagging the keyboard.
///
/// Split out from the panel so the sequencing is testable without AppKit: the
/// delegate callback is not a place to discover that Return searched for the
/// wrong thing.
@MainActor
final class ImageTextSearchQueryDebouncer {

    /// Matches `LibraryView.scheduleSearchReload`. The two search fields should
    /// not feel different from each other, and 150ms is already proven there.
    nonisolated static let typingDelayMilliseconds = 150

    /// Called when a query is actually ready to be searched for.
    var onDeliver: ((String) -> Void)?

    private var pending: String?
    private var task: Task<Void, Never>?

    /// Take a query from the field. Delivered after a pause — except an empty
    /// one, which goes at once: waiting to clear leaves highlights on screen
    /// for a query that is visibly gone, which reads as a stuck panel.
    func submit(_ query: String) {
        task?.cancel()
        task = nil
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            pending = nil
            onDeliver?(query)
            return
        }
        pending = query
        task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.typingDelayMilliseconds))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Deliver the pending query now. For anything that acts ON the results —
    /// Return moves to the next match — so it works from what is typed rather
    /// than from whatever the last completed search happened to be.
    func flush() {
        task?.cancel()
        task = nil
        guard let query = pending else { return }
        pending = nil
        onDeliver?(query)
    }

    /// Drop the pending query without delivering it. For leaving the panel or
    /// switching capture, where a late arrival would search the wrong image.
    func cancel() {
        task?.cancel()
        task = nil
        pending = nil
    }

    deinit { task?.cancel() }
}
