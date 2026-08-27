import Foundation

/// One entry on the app-global undo/redo timeline — annotation edits, capture
/// file events (delete/restore/import), navigation between captures, video
/// metadata edits, and full-image reverts, all interleaved by push order
/// instead of arbitrated across separate per-domain stacks.
struct GlobalUndoEntry: Equatable, Codable {
    /// When this entry was pushed onto its stack.
    let at: Date
    var kind: Kind

    enum Kind: Equatable, Codable {
        /// An annotation/canvas edit checkpoint. `capture == nil` means an
        /// unsaved scratch document (new canvas / clipboard paste) — session
        /// only, never persisted, and rebound to a real URL once saved
        /// (`rebindScratch`).
        case edit(capture: URL?, snapshot: EditorSnapshot)
        /// A capture delete/restore/import gesture (see `DeletionUndoHistory`).
        case fileEvent(DeletionUndoHistory.Event)
        /// Switching which capture is open in the editor.
        case navigation(from: URL?, to: URL?)
        /// A metadata-only edit (title/summary/tags) to a video capture.
        case videoMetadata(item: URL, before: MetadataUndoPatch, after: MetadataUndoPatch)
        /// A "Revert to Original Image" — session-only (never persisted; the
        /// revert payload itself lives in-memory for the session).
        case revert(capture: URL)
    }
}

/// The single app-global undo/redo timeline, replacing the three per-domain
/// histories (annotation `EditorHistory`, `DeletionUndoHistory`, session
/// revert stack) with one interleaved stack ordered by push time. Later tasks
/// wire the editor/library controllers to call into this store instead of
/// arbitrating across the old per-domain stacks.
///
/// Persisted through an injected `GlobalUndoTimelineStore` (when present):
/// session-only entries (`.revert`, and `.edit` with no capture — unsaved
/// scratch documents) are filtered out before every save, since they have no
/// meaning across a relaunch. Only the most recent `maxDepth` entries are
/// kept per stack; older ones fall off the bottom.
@MainActor
final class GlobalUndoStore {

    /// On-disk snapshot of both stacks (what `GlobalUndoTimelineStore` reads/writes).
    struct Persisted: Equatable, Codable {
        var undoStack: [GlobalUndoEntry]
        var redoStack: [GlobalUndoEntry]
    }

    /// Most recent entries retained in memory and (filtered) on disk; older
    /// entries are trimmed oldest-first whenever `record` grows past this.
    static let maxDepth = 200

    private(set) var undoStack: [GlobalUndoEntry] = []
    private(set) var redoStack: [GlobalUndoEntry] = []

    private let backend: GlobalUndoTimelineStore?

    /// Loads any persisted stacks from `backend` on creation. With no backend
    /// the timeline is purely in-memory (tests, or a session that opts out).
    init(backend: GlobalUndoTimelineStore?) {
        self.backend = backend
        if let loaded = backend?.load() {
            undoStack = loaded.undoStack
            redoStack = loaded.redoStack
        }
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var topUndo: GlobalUndoEntry? { undoStack.last }
    var topRedo: GlobalUndoEntry? { redoStack.last }

    /// Record a just-performed action. Clears redo — a new action erases the
    /// redo branch. Consecutive `.navigation` entries coalesce into one
    /// (browsing several captures in a row is one ⌘Z step; a round trip back
    /// to the start collapses to nothing).
    func record(_ kind: GlobalUndoEntry.Kind, at recordAt: Date = Date()) {
        // Drop degenerate navigations up front — BOTH stacks are left untouched
        // (no phantom append, and crucially no redo clear on a no-op):
        //   • N3: a `from == nil` nav (launch auto-open of the newest capture)
        //     is provably always dead on the undo side — the scratch/empty state
        //     it points back to is gone — and, recorded here, it would wipe the
        //     redo stack JUST loaded from disk, so redo never survives relaunch.
        //     Guarded centrally so both recording sites are covered.
        //   • N2: a `from == to` fresh append (re-clicking the playing video's
        //     tile, re-opening the already-open item) is a phantom entry that
        //     would also clear redo on a no-op. The coalesce branch below already
        //     drops `from == to` for consecutive navs; this covers the append.
        if case .navigation(let from, let to) = kind, from == nil || from == to {
            UndoDiag.note("global record navigation DROP degenerate "
                + "(\(UndoDiag.name(from))→\(UndoDiag.name(to))) — "
                + "\(from == nil ? "from==nil" : "from==to"), stacks untouched")
            return
        }
        let hadRedo = !redoStack.isEmpty
        if case .navigation(_, let newTo) = kind,
           let top = undoStack.last,
           case .navigation(let existingFrom, _) = top.kind {
            if existingFrom == newTo {
                undoStack.removeLast()
                UndoDiag.note("global record navigation coalesce → drop round-trip (\(UndoDiag.name(existingFrom))) "
                    + "\(hadRedo ? "CLEARED REDO (\(redoStack.count)) " : "")u:\(undoStack.count)")
            } else {
                let merged = GlobalUndoEntry(at: top.at, kind: .navigation(from: existingFrom, to: newTo))
                undoStack[undoStack.count - 1] = merged
                UndoDiag.note("global record navigation coalesce → \(describe(merged.kind)) "
                    + "\(hadRedo ? "CLEARED REDO (\(redoStack.count)) " : "")u:\(undoStack.count)")
            }
        } else {
            undoStack.append(GlobalUndoEntry(at: recordAt, kind: kind))
            UndoDiag.note("global record \(describe(kind)) "
                + "\(hadRedo ? "CLEARED REDO (\(redoStack.count)) " : "")u:\(undoStack.count)")
        }
        redoStack.removeAll()
        trimAndPersist()
    }

    /// Cancel a just-pushed edit checkpoint (e.g. a gesture that turned out to
    /// be a no-op) — only removes the top entry when it is exactly the `.edit`
    /// this call names (matching action label AND capture), never anything else.
    func removeTopEdit(action: String, capture: URL?) {
        guard case .edit(let c, let snapshot) = undoStack.last?.kind,
              c == capture, snapshot.action == action else { return }
        undoStack.removeLast()
        UndoDiag.note("global removeTopEdit \(action) capture:\(UndoDiag.name(capture)) → u:\(undoStack.count)")
        persist()
    }

    func popUndo() -> GlobalUndoEntry? {
        defer { persist() }
        let entry = undoStack.popLast()
        if let entry {
            UndoDiag.note("global popUndo \(describe(entry.kind)) → u:\(undoStack.count) r:\(redoStack.count)")
        }
        return entry
    }

    func popRedo() -> GlobalUndoEntry? {
        defer { persist() }
        let entry = redoStack.popLast()
        if let entry {
            UndoDiag.note("global popRedo \(describe(entry.kind)) → u:\(undoStack.count) r:\(redoStack.count)")
        }
        return entry
    }

    /// Push the undo counterpart after a successful redo.
    func pushUndo(_ entry: GlobalUndoEntry) {
        undoStack.append(entry)
        UndoDiag.note("global pushUndo \(describe(entry.kind)) → u:\(undoStack.count)")
        persist()
    }

    /// Push the redo counterpart after a successful undo.
    func pushRedo(_ entry: GlobalUndoEntry) {
        redoStack.append(entry)
        UndoDiag.note("global pushRedo \(describe(entry.kind)) → r:\(redoStack.count)")
        persist()
    }

    /// Convenience: push a fresh counterpart entry onto the opposite stack
    /// after performing an undo (`redo == false`) or redo (`redo == true`).
    func pushCounterpart(_ kind: GlobalUndoEntry.Kind, redo: Bool) {
        let entry = GlobalUndoEntry(at: Date(), kind: kind)
        if redo { pushUndo(entry) } else { pushRedo(entry) }
    }

    /// Drop fully-dead entries from the top of the chosen stack — so a dead
    /// entry never eats a ⌘Z press or shows a toast for an action that can no
    /// longer happen. Mirrors `DeletionUndoHistory.pruneDeadTopEvents`, but
    /// across all five kinds.
    func pruneDeadTop(redo: Bool, fileExists: (URL) -> Bool,
                       revertAvailable: (URL) -> Bool, scratchAlive: Bool) {
        var prunedKinds: [String] = []
        while let top = (redo ? redoStack : undoStack).last,
              isDead(top.kind, redo: redo, fileExists: fileExists,
                     revertAvailable: revertAvailable, scratchAlive: scratchAlive) {
            if redo { redoStack.removeLast() } else { undoStack.removeLast() }
            prunedKinds.append(describe(top.kind))
        }
        if !prunedKinds.isEmpty {
            UndoDiag.note("global pruned dead \(redo ? "redo" : "undo"): \(prunedKinds.joined(separator: ",")) "
                + "→ u:\(undoStack.count) r:\(redoStack.count)")
            persist()
        }
    }

    private func isDead(_ kind: GlobalUndoEntry.Kind, redo: Bool, fileExists: (URL) -> Bool,
                         revertAvailable: (URL) -> Bool, scratchAlive: Bool) -> Bool {
        switch kind {
        case .edit(let capture, _):
            if let capture { return !fileExists(capture) }
            return !scratchAlive
        case .fileEvent(let event):
            return event.items.allSatisfy { !fileExists(DeletionUndoHistory.liveURL(of: $0, kind: event.kind, redo: redo)) }
        case .navigation(let from, let to):
            let target = redo ? to : from
            if let target { return !fileExists(target) }
            return !scratchAlive
        case .videoMetadata(let item, _, _):
            return !fileExists(item)
        case .revert(let capture):
            return !fileExists(capture) || !revertAvailable(capture)
        }
    }

    /// Rewrite every unsaved-scratch `.edit(capture: nil, …)` in both stacks
    /// to reference `url` — called once a new canvas/clipboard paste is saved
    /// for the first time.
    func rebindScratch(to url: URL) {
        func rewrite(_ entries: inout [GlobalUndoEntry]) {
            for i in entries.indices {
                if case .edit(nil, let snapshot) = entries[i].kind {
                    entries[i].kind = .edit(capture: url, snapshot: snapshot)
                }
            }
        }
        rewrite(&undoStack)
        rewrite(&redoStack)
        UndoDiag.note("global rebindScratch → \(url.lastPathComponent)")
        persist()
    }

    /// Rewrite every URL equal to `from` to `to` across both stacks (a
    /// capture rename). `.fileEvent` items only rewrite `originalURL` —
    /// `trashedURL` is a trash location and never renames.
    func renameCapture(from: URL, to: URL) {
        func rewrite(_ entries: inout [GlobalUndoEntry]) {
            for i in entries.indices {
                switch entries[i].kind {
                case .edit(let capture, let snapshot) where capture == from:
                    entries[i].kind = .edit(capture: to, snapshot: snapshot)
                case .fileEvent(var event):
                    var changed = false
                    for j in event.items.indices where event.items[j].originalURL == from {
                        event.items[j] = DeletionUndoHistory.Item(
                            trashedURL: event.items[j].trashedURL, originalURL: to)
                        changed = true
                    }
                    if changed { entries[i].kind = .fileEvent(event) }
                case .navigation(let f, let t) where f == from || t == from:
                    entries[i].kind = .navigation(from: f == from ? to : f, to: t == from ? to : t)
                case .videoMetadata(let item, let before, let after) where item == from:
                    entries[i].kind = .videoMetadata(item: to, before: before, after: after)
                case .revert(let capture) where capture == from:
                    entries[i].kind = .revert(capture: to)
                default:
                    break
                }
            }
        }
        rewrite(&undoStack)
        rewrite(&redoStack)
        UndoDiag.note("global renameCapture \(from.lastPathComponent) → \(to.lastPathComponent)")
        persist()
    }

    /// Drop every entry in both stacks that references `url` as an `.edit`
    /// capture, `.videoMetadata` item, `.revert` capture, or `.navigation`
    /// endpoint (a capture permanently gone). `.fileEvent` entries are left
    /// alone — `pruneDeadTop` handles those via file existence, since a
    /// `.fileEvent` can still be actionable for its OTHER items.
    func removeCapture(_ url: URL) {
        func references(_ kind: GlobalUndoEntry.Kind) -> Bool {
            switch kind {
            case .edit(let capture, _): return capture == url
            case .videoMetadata(let item, _, _): return item == url
            case .revert(let capture): return capture == url
            case .navigation(let f, let t): return f == url || t == url
            case .fileEvent: return false
            }
        }
        let beforeU = undoStack.count, beforeR = redoStack.count
        undoStack.removeAll { references($0.kind) }
        redoStack.removeAll { references($0.kind) }
        UndoDiag.note("global removeCapture \(url.lastPathComponent) → "
            + "u:\(undoStack.count) (-\(beforeU - undoStack.count)) r:\(redoStack.count) (-\(beforeR - redoStack.count))")
        persist()
    }

    /// Trim both stacks to `maxDepth` (oldest first) and write them out.
    private func trimAndPersist() {
        if undoStack.count > Self.maxDepth { undoStack.removeFirst(undoStack.count - Self.maxDepth) }
        if redoStack.count > Self.maxDepth { redoStack.removeFirst(redoStack.count - Self.maxDepth) }
        persist()
    }

    /// Write both stacks to `backend`, filtering out entries with no meaning
    /// across a relaunch: `.revert` (session-only) and `.edit` with no
    /// capture (unsaved scratch documents — nothing on disk to restore into).
    private func persist() {
        backend?.save(Persisted(
            undoStack: undoStack.filter(isPersistable),
            redoStack: redoStack.filter(isPersistable)))
    }

    private func isPersistable(_ entry: GlobalUndoEntry) -> Bool {
        switch entry.kind {
        case .revert: return false
        case .edit(let capture, _): return capture != nil
        case .fileEvent, .navigation, .videoMetadata: return true
        }
    }

    private func describe(_ kind: GlobalUndoEntry.Kind) -> String {
        switch kind {
        case .edit(let capture, let snapshot):
            return "edit(\(snapshot.action ?? "?") @\(UndoDiag.name(capture)))"
        case .fileEvent(let event):
            return "fileEvent(\(event.kind.rawValue) x\(event.items.count))"
        case .navigation(let from, let to):
            return "navigation(\(UndoDiag.name(from))→\(UndoDiag.name(to)))"
        case .videoMetadata(let item, _, _):
            return "videoMetadata(\(item.lastPathComponent))"
        case .revert(let capture):
            return "revert(\(capture.lastPathComponent))"
        }
    }
}
