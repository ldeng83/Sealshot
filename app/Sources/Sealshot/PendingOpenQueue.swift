import Foundation

/// Accumulates file URLs that arrive via Finder's "Open With" while the
/// encryption session is locked, so they can be replayed once the user
/// unlocks. `drain()` returns everything queued and empties the queue in one
/// step, so a replay never double-imports or drops URLs.
struct PendingOpenQueue {
    private(set) var urls: [URL] = []

    var isEmpty: Bool { urls.isEmpty }

    mutating func enqueue(_ incoming: [URL]) {
        urls.append(contentsOf: incoming)
    }

    /// Returns all queued URLs and clears the queue.
    mutating func drain() -> [URL] {
        defer { urls = [] }
        return urls
    }
}
