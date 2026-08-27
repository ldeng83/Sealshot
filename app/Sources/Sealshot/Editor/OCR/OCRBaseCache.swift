import CoreGraphics
import os.log

private let log = OSLog(subsystem: "com.seal-shot.sealshot", category: "ocr")

/// Shares the expensive, policy-independent half of text recognition between
/// the consumers of a single capture.
///
/// A fresh capture is recognized twice: `MetadataCoordinator` reads it for
/// search text and keywords, and the editor's Live Text overlay reads it for
/// selection. Both are handed the SAME `CGImage` instance — `RegionCapturer`
/// passes `raw.image` to `MetadataCoordinator.start(source:)` and to the
/// `CaptureResult` that `EditorController.present` turns into
/// `EditorState.sourceImage` — but they ask for different `RefinementPolicy`
/// levels, so neither can reuse the other's finished layout. They can share
/// the base: tiling, dedup, stitching and column repair do not depend on the
/// policy, and that base is the bulk of the cost.
///
/// **Joining an IN-FLIGHT base is the point, not just caching finished ones.**
/// A store-on-completion cache helped only when the two reads were separated
/// in time. In the field they overlap: the two passes started 2.5s apart, both
/// missed the cache, and then contended — 26.1s and 24.2s for a base that
/// takes ~10s uncontended. A late arrival now awaits the running computation
/// instead of starting a rival one.
///
/// **Keyed by instance identity, deliberately.** A content fingerprint is not
/// an option: `CGImage.cropping` returns a view sharing the PARENT's data
/// provider (the hazard `selfContainedForCoreImage` documents), so bytes read
/// from the provider are identical for every same-sized tile of one image —
/// and `SmartRedactionAnalyzer` recognizes equal-sized vertical tiles whose
/// text feeds Luhn-checked card detection. Identity cannot make that mistake:
/// the same object is by definition the same pixels.
@MainActor
final class OCRBaseCache {

    static let shared = OCRBaseCache()

    /// Small on purpose. The win is one capture read twice within a short
    /// window; anything older has no second consumer coming. Entries pin their
    /// image (see `Done`), so an unbounded cache would pin bitmaps too.
    private let limit = 3

    private struct Done {
        /// Retained so the address behind the key cannot be recycled. Without
        /// this, a freed `CGImage` could be replaced by a new one allocated at
        /// the same address and identity lookup would return another image's
        /// text. In the case this exists for, the image is alive anyway (the
        /// editor holds it), so pinning usually costs nothing.
        let image: CGImage
        let key: ObjectIdentifier
        let base: OCRBase
    }

    /// A base computation in progress, plus how many callers are waiting on it.
    private final class Pending {
        let image: CGImage           // pinned, same reason as `Done.image`
        let task: Task<OCRBase, Error>
        var waiters = 0
        init(image: CGImage, task: Task<OCRBase, Error>) {
            self.image = image
            self.task = task
        }
    }

    /// Per-call token so a waiter is only ever released once, no matter whether
    /// the cancellation handler or the normal path gets there first.
    final class Ticket { fileprivate var released = false }

    private var done: [Done] = []
    private var pending: [ObjectIdentifier: Pending] = [:]

    /// The base for `image`: reused if finished, joined if already running,
    /// otherwise computed. `make` builds the work only when it is actually
    /// needed, so a joining caller never constructs a redundant task.
    func base(for image: CGImage, priority: TaskPriority,
              make: (CGImage, TaskPriority) -> Task<OCRBase, Error>) async throws -> OCRBase {
        let key = ObjectIdentifier(image)

        if let hit = finished(key, image) { return hit }

        let entry: Pending
        if let existing = pending[key] {
            entry = existing
            os_log("OCR base joined in flight (%dx%d)", log: log, type: .info,
                   image.width, image.height)
        } else {
            // A `.userInitiated` caller joining a `.utility` computation relies
            // on Swift escalating the awaited task's priority; the base is
            // started at whatever priority first needed it.
            entry = Pending(image: image, task: make(image, priority))
            pending[key] = entry
        }

        entry.waiters += 1
        let ticket = Ticket()
        do {
            let base = try await withTaskCancellationHandler {
                try await entry.task.value
            } onCancel: {
                // Hops to the main actor to touch the refcount. The shared task
                // is cancelled only once NO caller is left waiting on it —
                // otherwise one consumer walking away would destroy the other's
                // work.
                Task { @MainActor [weak self] in self?.release(key, ticket) }
            }
            release(key, ticket, cancelIfLast: false)
            store(base, for: image)
            return base
        } catch {
            release(key, ticket)
            throw error
        }
    }

    /// A finished base for this exact instance, or nil.
    private func finished(_ key: ObjectIdentifier, _ image: CGImage) -> OCRBase? {
        guard let index = done.firstIndex(where: { $0.key == key }) else { return nil }
        let entry = done[index]
        // Defence in depth: identity should imply identical geometry, so a
        // mismatch means the assumption above is broken. Drop the entry rather
        // than return text that may belong to different pixels.
        guard entry.image.width == image.width, entry.image.height == image.height else {
            os_log("OCR base cache identity/geometry mismatch — dropping entry",
                   log: log, type: .error)
            done.remove(at: index)
            return nil
        }
        // Refresh recency so a capture being read twice isn't evicted between
        // its two consumers by unrelated recognitions (redaction tiles).
        done.append(done.remove(at: index))
        os_log("OCR base reused (%dx%d, %d tiles, %d lines)", log: log, type: .info,
               image.width, image.height, entry.base.tileCount, entry.base.lines.count)
        return entry.base
    }

    private func release(_ key: ObjectIdentifier, _ ticket: Ticket, cancelIfLast: Bool = true) {
        guard !ticket.released else { return }
        ticket.released = true
        guard let entry = pending[key] else { return }
        entry.waiters -= 1
        guard entry.waiters <= 0 else { return }
        if cancelIfLast { entry.task.cancel() }
        pending.removeValue(forKey: key)
    }

    func store(_ base: OCRBase, for image: CGImage) {
        let key = ObjectIdentifier(image)
        done.removeAll { $0.key == key }
        done.append(Done(image: image, key: key, base: base))
        if done.count > limit { done.removeFirst(done.count - limit) }
    }

    /// Drop everything — used by tests, and available if memory pressure ever
    /// needs to reclaim the pinned images.
    func removeAll() {
        done.removeAll()
        for entry in pending.values { entry.task.cancel() }
        pending.removeAll()
    }
}
