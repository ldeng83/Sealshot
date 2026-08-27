import Foundation
import CoreGraphics
import os.log

private let log = OSLog(subsystem: "com.seal-shot.sealshot", category: "ocr")

/// One-time background migration: OCR every `.seal` package whose manifest
/// predates v4 (`ocrText == nil`) and patch the text in, so the whole Library
/// becomes text-searchable. Runs serially at utility priority; patched
/// packages no longer match the filter, so the work is idempotent across
/// launches. Only `ocrText` is written (`SealMetadataStore.applyOCRText`) —
/// user-edited titles/tags are never touched.
@MainActor
final class OCRBackfillCoordinator {

    static let shared = OCRBackfillCoordinator()

    private var task: Task<Void, Never>?
    private let ocr: (CGImage) async throws -> String

    /// `ocr` maps a source image to its joined OCR text; the default uses the
    /// on-device `TextRecognizer` (injectable for tests).
    init(ocr: ((CGImage) async throws -> String)? = nil) {
        if let ocr {
            self.ocr = ocr
        } else {
            let recognizer = TextRecognizer()
            self.ocr = { image in
                // Background migration of the whole library — the least
                // latency-sensitive OCR in the app, so it takes the budget too.
                let layout = try await recognizer.recognize(image, policy: .budgeted)
                return layout.lines.map(\.text).joined(separator: "\n")
            }
        }
    }

    /// Fire-and-forget entry point for app launch. Safe to call repeatedly —
    /// only one pass runs per process. To force a new pass (e.g. post-unlock),
    /// call `restart(saveFolder:)` instead.
    func start(saveFolder: URL) {
        guard task == nil else { return }
        task = Task(priority: .utility) { [weak self] in
            await self?.run(saveFolder: saveFolder)
        }
    }

    /// Cancels any in-progress pass and begins a new one. Used after the
    /// encryption session unlocks so previously-skipped locked packages are
    /// processed. The new pass will pick up any packages not yet OCR'd.
    func restart(saveFolder: URL) {
        task?.cancel()
        task = nil
        start(saveFolder: saveFolder)
    }

    func cancel() { task?.cancel() }

    /// One backfill pass over the save folder and its Trash. Newest captures
    /// first, so the images the user is most likely to search become
    /// searchable soonest. Failures are logged and skipped.
    func run(saveFolder: URL) async {
        let folders = [
            saveFolder,
            saveFolder.appendingPathComponent(SealDeleter.deletedSubfolderName, isDirectory: true),
        ]
        var patched = 0
        for folder in folders {
            for url in pendingSeals(in: folder) {
                if Task.isCancelled { return }
                // Don't race the capture pipeline. A freshly-captured package
                // sits on disk with `ocrText == nil` for as long as its own OCR
                // takes, so it looks pending here while it is already being
                // recognized — running it again just puts two full recognitions
                // of the same image on the same CPU/GPU (see OCRInFlightRegistry).
                if OCRInFlightRegistry.shared.contains(url) { continue }
                // `pendingSeals` is a snapshot taken before the loop; re-read the
                // manifest now, since a capture whose OCR completed since then is
                // no longer pending. Narrows what the registry can't cover — an
                // item claimed and released between the listing and this turn.
                guard let current = try? SealMetadataStore.readManifest(at: url),
                      current.ocrText == nil else { continue }
                do {
                    let contents = try readSealPackage(at: url, crypto: SealPackageCryptoContext.current())
                    let text = try await ocr(contents.source)
                    try SealMetadataStore.applyOCRText(text, to: url)
                    patched += 1
                    NotificationCenter.default.post(name: .captureMetadataDidChange, object: url)
                } catch {
                    os_log("OCR backfill failed for %{public}@: %{public}@",
                           log: log, type: .error, url.lastPathComponent, String(describing: error))
                }
            }
        }
        if patched > 0 {
            os_log("OCR backfill patched %d package(s)", log: log, type: .info, patched)
        }
    }

    /// `.seal` packages in `folder` whose manifest has no OCR text yet,
    /// newest-first. Unreadable manifests are skipped (they'd fail the patch
    /// anyway). Locked packages are skipped cheaply here — throwing through
    /// the read path is more expensive and the error would just be swallowed.
    /// Phase 2b re-triggers backfill after the user unlocks their library.
    private func pendingSeals(in folder: URL) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return entries
            .filter { $0.pathExtension == "seal" }
            .filter { url in
                // Skip locked packages — OCR requires decrypted source bytes; backfill
                // of locked packages is deferred until Phase 2b post-unlock re-trigger.
                if SealPackageCrypter.isLocked(url) {
                    os_log("OCR backfill skipping locked package %{public}@",
                           log: log, type: .debug, url.lastPathComponent)
                    return false
                }
                guard let manifest = try? SealMetadataStore.readManifest(at: url) else { return false }
                // Video captures have no source image to OCR; skip them.
                //
                // A Live Capture scene is skipped for the opposite reason: its
                // `source` IS an image, but it is the display wallpaper. OCR'ing
                // it would read desktop icon names and menu-bar text into the
                // capture's text — and because a non-empty `ocrText` is then
                // reused rather than regenerated, the scene would be keyworded
                // from the wallpaper permanently. A scene's text lives in its
                // per-window assets, and `MetadataCoordinator` (whose scene
                // exemption in `needsTagBackfill` still fires) reads it there.
                guard manifest.captureKind != .screenRecording,
                      manifest.captureKind != .importedVideo,
                      manifest.captureKind != .liveCapture else { return false }
                return manifest.ocrText == nil
            }
            .sorted { mtime($0) > mtime($1) }
    }

    private func mtime(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
    }
}
