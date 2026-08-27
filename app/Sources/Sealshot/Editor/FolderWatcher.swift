import Foundation
import CoreServices

/// Watches a folder tree via FSEvents and fires `onChange` on the main queue
/// (debounced) when anything beneath it changes. The Library uses this to
/// reconcile its index when captures are added, edited or removed — by other
/// parts of the app (saves, OCR backfill) or by the user in Finder.
final class FolderWatcher {

    /// Called on the main queue after events settle.
    var onChange: (() -> Void)?

    private(set) var watchedFolder: URL?

    private let debounce: TimeInterval
    private let latency: TimeInterval
    /// The stream's callback queue; also guards `pending`.
    private let queue = DispatchQueue(label: "com.seal-shot.sealshot.folder-watcher")
    private var stream: FSEventStreamRef?
    private var pending: DispatchWorkItem?

    init(debounce: TimeInterval = 0.3, latency: TimeInterval = 0.2) {
        self.debounce = debounce
        self.latency = latency
    }

    deinit { stop() }

    /// Start (or re-arm) watching `folder`. No-op when already watching it.
    func watch(_ folder: URL) {
        let standardized = folder.standardizedFileURL
        guard standardized != watchedFolder else { return }
        stop()

        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue().fireDebounced()
        }
        guard let stream = FSEventStreamCreate(
            nil, callback, &context,
            [standardized.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)) else { return }
        self.stream = stream
        watchedFolder = standardized
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        watchedFolder = nil
        queue.sync {
            pending?.cancel()
            pending = nil
        }
    }

    /// Runs on `queue` (the stream's callback queue).
    private func fireDebounced() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            DispatchQueue.main.async { self?.onChange?() }
        }
        pending = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }
}
