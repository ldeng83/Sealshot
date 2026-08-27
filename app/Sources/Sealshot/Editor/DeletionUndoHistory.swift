import Foundation

/// Value types describing a capture-file trash gesture — deletions AND restores
/// (strip / Library tab); NOT annotation edits. One event per user gesture: a
/// bulk delete (or restore) is a single event, so one ⌘Z reverts the whole
/// batch. Interleaved with every other undo kind on the app-global timeline
/// (`GlobalUndoStore`), which now owns the undo/redo stacks and persistence;
/// this type is just the payload (`.fileEvent`).
///
/// Mostly bookkeeping — the controller performs the SealDeleter moves and
/// pushes the counterpart event with post-move locations (restore/delete can
/// suffix basenames on name conflicts, so URLs change across a round trip).
enum DeletionUndoHistory {

    /// Which gesture an event records — decides what undo does. Undo of a
    /// `.deletion` restores; undo of a `.restoration` re-deletes (redo
    /// reverses each).
    enum Kind: String, Codable {
        case deletion, restoration
        /// Files minted by an import (⌘O / drag / .sealshare). Undo MOVES
        /// them to Deleted (never destroys); redo restores them.
        case importation
        /// A capture that just landed in the library. Same undo semantics as
        /// an import: undo trashes (recoverable), redo restores.
        case capture
    }

    struct Item: Equatable, Codable {
        /// Where the file sits in `Deleted/` while this event is undoable.
        let trashedURL: URL
        /// Where it lived in the save folder before the delete.
        let originalURL: URL
    }

    struct Event: Equatable, Codable {
        var items: [Item]
        /// The gesture this records — deletion or restoration.
        var kind: Kind
        /// The then-open capture was part of this batch — undo reopens it.
        let containedOpenFile: Bool
        /// Push time onto the global timeline.
        let at: Date
    }

    /// Which of an item's two locations must still EXIST for the event to be
    /// actionable, per gesture and direction: undoing a deletion restores
    /// from the trash (`trashedURL`); undoing a restoration/import/capture
    /// re-deletes the live file (`originalURL`); redo mirrors each. Used by
    /// `GlobalUndoStore.pruneDeadTop` to drop dead `.fileEvent` entries.
    static func liveURL(of item: Item, kind: Kind, redo: Bool) -> URL {
        switch kind {
        case .deletion: return redo ? item.originalURL : item.trashedURL
        case .restoration, .importation, .capture: return redo ? item.trashedURL : item.originalURL
        }
    }
}
