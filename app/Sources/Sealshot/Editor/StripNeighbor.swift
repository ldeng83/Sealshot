import Foundation

/// Pick the item the editor should move to after `removed` is deleted from the
/// strip. `displayed` is the strip's on-screen order (newest-first, already
/// media-filtered) — using it, rather than an independently re-derived
/// listing, is what makes the post-delete selection match what the user sees
/// instead of a surprise "random" pick.
///
/// Picks the item immediately to the right of `removed` — whatever its type
/// (image or video; the caller opens or plays it) — skipping only other files
/// in `batch`. With nothing to the right, walks left for the new rightmost.
/// Returns nil when nothing remains outside `batch`.
func stripNeighbor(
    after removed: URL,
    excluding batch: Set<URL>,
    in displayed: [URL]
) -> URL? {
    guard let idx = displayed.firstIndex(of: removed) else {
        // Not on screen (shouldn't happen) — fall back to the first remaining.
        return displayed.first { !batch.contains($0) }
    }
    // Walk right past batch members.
    if idx + 1 < displayed.count {
        for i in (idx + 1)..<displayed.count where !batch.contains(displayed[i]) {
            return displayed[i]
        }
    }
    // No right-neighbor — walk left for the new rightmost.
    if idx > 0 {
        for i in (0..<idx).reversed() where !batch.contains(displayed[i]) {
            return displayed[i]
        }
    }
    return nil
}

/// What the editor should do after a strip deletion.
struct PostDeletePlan: Equatable {
    /// The item currently on screen (open image OR playing video) was deleted,
    /// so the editor must move off it.
    let switchNeeded: Bool
    /// The neighbor to open/play in its place — nil when nothing remains
    /// (caller shows the empty editor).
    let switchTo: URL?
    /// The open editor image itself was deleted: clear its editor state so its
    /// autosave can't resurrect it, and reopen it on undo (`containedOpenFile`).
    let clearOpenImage: Bool
}

/// Decide the post-deletion move. The on-screen item is the playing video if
/// one is up (it sits over the open image), else the open image. If that item
/// is in the delete `batch`, switch to its `stripNeighbor` in the strip's
/// visible order. `clearOpenImage` is independent: it tracks whether the open
/// image was deleted (which can happen even while a video plays on top).
func postDeletePlan(
    deleting batch: Set<URL>,
    openImage: URL?,
    playingVideo: URL?,
    displayed: [URL]
) -> PostDeletePlan {
    let clearOpenImage = openImage.map(batch.contains) ?? false
    let current = playingVideo ?? openImage
    guard let current, batch.contains(current) else {
        return PostDeletePlan(switchNeeded: false, switchTo: nil, clearOpenImage: clearOpenImage)
    }
    return PostDeletePlan(
        switchNeeded: true,
        switchTo: stripNeighbor(after: current, excluding: batch, in: displayed),
        clearOpenImage: clearOpenImage)
}
