import Foundation
import CoreGraphics
import os.log

/// Backfills visual tags across the library, additively. Mirrors
/// `OCRBackfillCoordinator`: a single cancellable Task, locked packages skipped,
/// `.captureMetadataDidChange` posted per updated capture so the index/UI refresh.
@MainActor
@Observable
final class VisualTagBackfillJob {

    let progress = CanvasProgress()
    /// Set to `true` when the pass completes (whether by finishing or being
    /// cancelled). The Library overlay observes this to dismiss itself.
    private(set) var isFinished = false
    private let log = OSLog(subsystem: "com.seal-shot.sealshot", category: "visual-tag-backfill")
    private let visualTags: (CGImage) async -> VisualTags
    private var task: Task<Void, Never>?

    /// `visualTags` maps a source image to its `VisualTags`; the default uses the
    /// on-device `VisionTagger` (injectable for tests).
    init(visualTags: ((CGImage) async -> VisualTags)? = nil) {
        if let visualTags {
            self.visualTags = visualTags
        } else {
            let tagger = VisionTagger()
            self.visualTags = { image in
                await Task.detached(priority: .utility) { tagger.tags(for: image) }.value
            }
        }
    }

    /// Whether a capture should be (re)tagged: it has metadata, is unlocked, and
    /// its visual tags are stale. Pure for testing.
    nonisolated static func needsTagging(metadata: CaptureMetadata?, isLocked: Bool) -> Bool {
        guard !isLocked, let metadata else { return false }
        return metadata.visualTagVersion < VisionTagger.version
    }

    /// Fire-and-forget entry point. Safe to call repeatedly —
    /// only one pass runs at a time per job instance.
    func start(saveFolder: URL) {
        guard task == nil else { return }
        isFinished = false
        task = Task { @MainActor [weak self] in
            await self?.run(saveFolder: saveFolder)
            self?.task = nil
            self?.isFinished = true
        }
    }

    func cancel() {
        task?.cancel()
        isFinished = true
    }

    /// One backfill pass over the save folder and its Trash. Failures are
    /// logged and skipped. Locked packages are skipped cheaply here — they will
    /// be re-processed on the next backfill trigger (e.g. after unlock).
    private func run(saveFolder: URL) async {
        let folders = [
            saveFolder,
            saveFolder.appendingPathComponent(SealDeleter.deletedSubfolderName, isDirectory: true),
        ]
        let seals = folders.flatMap { sealURLs(in: $0) }
        progress.label = "Adding visual tags…"
        var done = 0
        for url in seals {
            if Task.isCancelled { return }
            done += 1
            progress.fraction = Double(done) / Double(max(seals.count, 1))
            progress.note = "Tagging \(done) of \(seals.count)…"

            if SealPackageCrypter.isLocked(url) { continue }   // re-tagged on next unlock
            // Video captures have no source image to tag; skip them explicitly
            // rather than letting readSealPackage fail on missing source.png.
            if let manifest = try? SealMetadataStore.readManifest(at: url),
               manifest.captureKind == .screenRecording || manifest.captureKind == .importedVideo {
                continue
            }
            do {
                let contents = try readSealPackage(at: url, crypto: SealPackageCryptoContext.current())
                guard Self.needsTagging(metadata: contents.manifest.metadata, isLocked: false)
                else { continue }
                let visual = await visualTags(contents.source)
                try SealMetadataStore.update(at: url) {
                    $0.smartKeywords = VisualTagMerge.backfill(existing: $0.smartKeywords, visual: visual)
                    $0.visualTagVersion = VisionTagger.version
                }
                NotificationCenter.default.post(name: .captureMetadataDidChange, object: url)
            } catch {
                os_log("visual-tag backfill skipped %{public}@: %{public}@",
                       log: log, type: .error, url.lastPathComponent, String(describing: error))
            }
        }
        progress.fraction = 1
        progress.note = ""
    }

    /// `.seal` packages directly inside `folder` (non-recursive), mirroring
    /// `OCRBackfillCoordinator`'s enumeration. Returns [] if the folder is absent.
    private func sealURLs(in folder: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "seal" } ?? []
    }
}
