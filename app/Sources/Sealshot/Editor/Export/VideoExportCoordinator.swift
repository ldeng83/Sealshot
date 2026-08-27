import AppKit
import UniformTypeIdentifiers

/// Drives "Export to Video": Save panel → streaming decrypt with progress + cancel.
/// v1 exports a single video; non-video sources are ignored.
@MainActor
enum VideoExportCoordinator {

    /// Thread-safe one-way cancel flag.  NSLock is available on the macOS 14 floor.
    private final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var _cancelled = false
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
        func cancel() { lock.lock(); _cancelled = true; lock.unlock() }
    }

    static func present(sources: [SharePackageSource], host: NSWindow?) {
        // Only videos are exportable here; images in the selection are skipped
        // (a count is surfaced in the summary). One video → Save panel; several →
        // a folder, matching "Export to Image".
        let videos = sources.filter { $0.isVideo }
        guard !videos.isEmpty else { return }
        let skippedImages = sources.count - videos.count
        if videos.count == 1 {
            presentSingle(videos[0], skippedImages: skippedImages, host: host)
        } else {
            presentMultiple(videos, skippedImages: skippedImages, host: host)
        }
    }

    // MARK: single

    private static func presentSingle(_ source: SharePackageSource, skippedImages: Int, host: NSWindow?) {
        let crypto = SealPackageCryptoContext.current()

        // Resolve the output container from the package header (cheap; no payload read).
        let ext: String
        let type: UTType
        if let contents = try? VideoSealPackageIO.read(at: source.url, crypto: crypto) {
            (ext, type) = VideoExportWriter.outputType(for: contents)
        } else {
            (ext, type) = ("mov", .quickTimeMovie)   // locked/unreadable → sensible default; export will surface the error
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = FriendlyFilename.sanitize(source.displayName) + "." + ext
        if let last = LastSaveDirectory.url { panel.directoryURL = last }

        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let dest = panel.url else { return }
            run(source: source, dest: dest, crypto: crypto, skippedImages: skippedImages, host: host)
        }
        if let host { panel.beginSheetModal(for: host, completionHandler: handler) }
        else { handler(panel.runModal()) }
    }

    // MARK: multiple

    private static func presentMultiple(_ videos: [SharePackageSource], skippedImages: Int, host: NSWindow?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Export Here"
        panel.message = "Choose a folder to export \(videos.count) videos into."
        if let last = LastSaveDirectory.url { panel.directoryURL = last }
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let folder = panel.url else { return }
            runBatch(videos, to: folder, skippedImages: skippedImages, host: host)
        }
        if let host { panel.beginSheetModal(for: host, completionHandler: handler) }
        else { handler(panel.runModal()) }
    }

    private static func runBatch(_ videos: [SharePackageSource], to folder: URL,
                                 skippedImages: Int, host: NSWindow?) {
        let crypto = SealPackageCryptoContext.current()
        // Pre-resolve deduped destinations on the main actor (correct container
        // extension per video), so the detached export loop only touches URLs.
        var used: Set<String> = []
        let plan: [(url: URL, dest: URL)] = videos.map { source in
            let ext = (try? VideoSealPackageIO.read(at: source.url, crypto: crypto))
                .map { VideoExportWriter.outputType(for: $0).0 } ?? "mov"
            let name = CaptureConfig.uniqueName(base: FriendlyFilename.sanitize(source.displayName), ext: ext) {
                used.contains($0) || FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
            }
            used.insert(name)
            return (source.url, folder.appendingPathComponent(name))
        }
        let progress = BulkProgressSheet()
        let flag = CancelFlag()
        if let host {
            progress.begin(total: plan.count, verb: "Exporting", in: host,
                           onCancel: { flag.cancel() }, immediate: true)
        }
        Task.detached(priority: .userInitiated) {
            var ok = 0, failed = 0
            for (index, item) in plan.enumerated() {
                if flag.isCancelled { break }
                await MainActor.run { progress.update(done: index, total: plan.count, verb: "Exporting") }
                do {
                    try VideoExportWriter.export(packageURL: item.url, to: item.dest, crypto: crypto,
                                                 progress: { _, _ in }, isCancelled: { flag.isCancelled })
                    ok += 1
                } catch is CancellationError {
                    break
                } catch {
                    failed += 1
                }
            }
            let okF = ok, failedF = failed
            await MainActor.run {
                progress.end()
                LastSaveDirectory.url = folder
                let plural = okF == 1 ? "" : "s"
                var msg = failedF == 0
                    ? "Exported \(okF) video\(plural)."
                    : "Exported \(okF) video\(plural). \(failedF) couldn't be exported (locked or unreadable)."
                if skippedImages > 0 {
                    msg += " \(skippedImages) image\(skippedImages == 1 ? "" : "s") skipped — use Export to Image for those."
                }
                alert(msg, host: host, style: failedF == 0 ? .informational : .warning)
            }
        }
    }

    private static func run(source: SharePackageSource, dest: URL,
                            crypto: SealPackageCryptoContext, skippedImages: Int = 0, host: NSWindow?) {
        let progress = BulkProgressSheet()
        let flag = CancelFlag()

        // Total payload bytes for the determinate bar (cheap header read; never
        // decrypts the payload). Both encrypted and plaintext exports report
        // incremental byte progress, so the bar fills for either.
        let totalBytes = payloadByteCount(packageURL: source.url, crypto: crypto)

        if let host {
            // Export is an explicit user action — show the bar + Cancel right
            // away rather than waiting out the grace delay (recordings often
            // finish faster than 250 ms). setFraction(0,…) is called before the
            // sheet is presented (next run-loop turn) so the first painted frame
            // already shows the MB label, not the raw byte count.
            progress.begin(total: max(1, totalBytes), verb: "Exporting", in: host,
                           onCancel: { flag.cancel() }, immediate: true)
            progress.setFraction(0,
                                 label: "Exporting 0 of \(max(1, totalBytes / 1_000_000)) MB",
                                 detail: nil)
        }
        Task.detached(priority: .userInitiated) {
            do {
                try VideoExportWriter.export(
                    packageURL: source.url, to: dest, crypto: crypto,
                    progress: { done, total in
                        guard total > 0 else { return }
                        let fraction = Double(done) / Double(total)
                        let doneMB = done / 1_000_000, totalMB = max(1, total / 1_000_000)
                        Task { @MainActor in
                            progress.setFraction(fraction,
                                                 label: "Exporting \(doneMB) of \(totalMB) MB",
                                                 detail: nil)
                        }
                    },
                    isCancelled: { flag.isCancelled })
                await MainActor.run {
                    progress.end()
                    LastSaveDirectory.remember(dest)
                    var msg = "Exported video."
                    if skippedImages > 0 {
                        msg += " \(skippedImages) image\(skippedImages == 1 ? "" : "s") skipped — use Export to Image for those."
                    }
                    alert(msg, host: host, style: .informational)
                }
            } catch is CancellationError {
                await MainActor.run { progress.end() }
            } catch VideoSealPackageIOError.packageLocked {
                await MainActor.run {
                    progress.end()
                    alert("Unlock Sealshot to export this video.", host: host, style: .warning)
                }
            } catch {
                await MainActor.run {
                    progress.end()
                    alert("Couldn't export this video.", host: host, style: .warning)
                }
            }
        }
    }

    /// Best-effort total byte count of the payload, for the determinate bar.
    /// Encrypted → the SealedChunkFile header's `originalLength`; plaintext → the
    /// on-disk payload size. Returns 0 if it can't be determined (the bar still
    /// fills from the live fraction the export callbacks supply).
    private static func payloadByteCount(packageURL: URL,
                                         crypto: SealPackageCryptoContext) -> Int {
        guard let contents = try? VideoSealPackageIO.read(at: packageURL, crypto: crypto) else { return 0 }
        if let key = contents.key {
            guard let reader = try? SealedChunkFile.Reader(url: contents.payloadURL, key: key) else { return 0 }
            return Int(reader.originalLength)
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: contents.payloadURL.path)
        return (attrs?[.size] as? Int) ?? 0
    }

    private static func alert(_ message: String, host: NSWindow?, style: NSAlert.Style) {
        let a = NSAlert()
        a.messageText = message
        a.alertStyle = style
        a.addButton(withTitle: "OK")
        if let host { a.beginSheetModal(for: host) { _ in } } else { a.runModal() }
    }
}
