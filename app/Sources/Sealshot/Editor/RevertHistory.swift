import Foundation

/// In-memory undo/redo of "Revert to Original" operations. Holds whole
/// `EditorState` objects (with their images), so it is deliberately NOT
/// persisted — the revert commits when the editor closes/reopens. Interleaved
/// with the other undo kinds via a session-only `.revert` marker pushed onto
/// the app-global timeline (`GlobalUndoStore`); the marker carries no
/// payload — this history holds the actual before/after states it restores.
@MainActor
final class RevertHistory {
    struct Entry {
        let previous: EditorState   // state before the revert (restored on undo)
        let reverted: EditorState   // state after the revert (restored on redo)
        let at: Date
    }

    private(set) var undoStack: [Entry] = []
    private(set) var redoStack: [Entry] = []

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Record a just-performed revert. Clears redo (a new action erases the
    /// redo branch — same semantics as the annotation/deletion stacks).
    func record(previous: EditorState, reverted: EditorState, at: Date = Date()) {
        undoStack.append(Entry(previous: previous, reverted: reverted, at: at))
        redoStack.removeAll()
    }

    func popUndo() -> Entry? { undoStack.popLast() }
    func popRedo() -> Entry? { redoStack.popLast() }
    func pushRedo(_ e: Entry) { redoStack.append(e) }
    func pushUndo(_ e: Entry) { undoStack.append(e) }

    /// Drop all entries (commits any pending revert). Called when the editor
    /// navigates to a different capture — the controller (and this history) is
    /// reused across captures, and revert-undo is per-capture / session-scoped.
    func clear() {
        undoStack.removeAll()
        redoStack.removeAll()
    }
}
