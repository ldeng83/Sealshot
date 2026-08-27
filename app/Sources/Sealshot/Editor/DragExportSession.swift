import AppKit

/// Thread-safe cancel flag: set on the main actor by the Cancel button, read
/// synchronously from the background export queue between chunks.
final class DragExportCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
    func cancel() { lock.lock(); _cancelled = true; lock.unlock() }
}

/// Shared progress + cancel for a drag-out export that has one or more SLOW
/// items (encrypted-video file promises fulfilled after the drop). Fast items
/// (images, plaintext videos) are written eagerly at drag start and never touch
/// this — so the sheet only ever tracks the genuinely-slow work.
///
/// A single `BulkProgressSheet` (grace-delayed, so quick exports never flash)
/// shows aggregate "Exporting N of M…" progress: each item contributes an equal
/// slice, filled by its own byte fraction. The promise writes run serialized
/// (one at a time — see `CaptureDragPayload`'s queue), so `completedItems` stays
/// in step. `@MainActor`, hence implicitly Sendable: the background writes reach
/// it only through `Task { @MainActor in … }` hops, except the cancel flag which
/// is its own thread-safe object read directly on the queue.
@MainActor
final class DragExportSession {
    let cancelFlag = DragExportCancelFlag()

    private let sheet = BulkProgressSheet()
    private let totalItems: Int
    /// `true` for a multi-file export: the sheet shows as soon as the first write
    /// starts (no grace delay), so "N of M" is always visible. Single-item
    /// exports keep the grace delay, so a quick single image never flashes UI.
    private let immediate: Bool
    private var completedItems = 0
    private weak var host: NSWindow?
    private var began = false
    private var ended = false

    init(totalItems: Int, host: NSWindow?, immediate: Bool) {
        self.totalItems = max(0, totalItems)
        self.host = host
        self.immediate = immediate
    }

    /// Lazily present the sheet when the first write starts (not at drag start —
    /// a drop may be seconds away, and a drag may be cancelled). Idempotent.
    private func ensureBegun() {
        guard !began, !ended, totalItems > 0, let host else { return }
        began = true
        sheet.begin(total: 1, verb: "Exporting", in: host,
                    onCancel: { [weak self] in self?.cancelFlag.cancel() },
                    immediate: immediate)
        updateBar(itemFraction: 0)
    }

    /// A file's write is beginning. Shows the sheet and advances "N of M".
    func willStartItem() {
        ensureBegun()
        updateBar(itemFraction: 0)
    }

    /// Byte progress within the current (in-flight) item. `done`/`total` are that
    /// one item's bytes; the bar shows the aggregate across all items.
    func reportProgress(done: Int, total: Int) {
        ensureBegun()
        updateBar(itemFraction: total > 0 ? min(1, Double(done) / Double(total)) : 0)
    }

    private func updateBar(itemFraction: Double) {
        guard !ended else { return }
        let overall = (Double(completedItems) + itemFraction) / Double(max(1, totalItems))
        let n = min(completedItems + 1, totalItems)
        sheet.setFraction(overall, label: "Exporting \(n) of \(totalItems)…", detail: nil)
    }

    /// One item's write finished (success or skip). Ends the sheet on the last.
    func itemFinished() {
        guard !ended else { return }
        completedItems += 1
        if completedItems >= totalItems { finish() } else { updateBar(itemFraction: 0) }
    }

    /// Tear the sheet down (last item, or a cancel that abandons the rest).
    func finish() {
        guard !ended else { return }
        ended = true
        sheet.end()
    }
}
