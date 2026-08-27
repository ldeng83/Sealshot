import AppKit
import UniformTypeIdentifiers

/// Drives "Export to Image": single → Save panel, multiple → folder + dedupe.
@MainActor
enum ExportImageCoordinator {

    static func present(sources: [SharePackageSource], host: NSWindow?) {
        guard !sources.isEmpty else { return }
        if sources.count == 1 { presentSingle(sources[0], host: host) }
        else { presentMultiple(sources, host: host) }
    }

    // MARK: single

    private static func presentSingle(_ source: SharePackageSource, host: NSWindow?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = FriendlyFilename.sanitize(source.displayName) + ".png"
        if let last = LastSaveDirectory.url { panel.directoryURL = last }
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let dest = panel.url else { return }
            Task { await writeSingle(source, to: dest, host: host) }
        }
        if let host { panel.beginSheetModal(for: host, completionHandler: handler) }
        else { handler(panel.runModal()) }
    }

    private static func writeSingle(_ source: SharePackageSource, to dest: URL, host: NSWindow?) async {
        let crypto = SealPackageCryptoContext.current()
        let key = try? EncryptionSession.shared.contentKey(for: .recordings)
        do {
            let data = try await ExportImageRenderer.pngData(for: source, crypto: crypto, recordingsKey: key)
            try data.write(to: dest, options: .atomic)
            LastSaveDirectory.remember(dest)
            alert(source.isVideo
                    ? "Exported the video's first frame as an image. Use Export to Video for the full clip."
                    : "Exported image.",
                  host: host, style: .informational)
        } catch ExportImageError.locked {
            alert("Unlock Sealshot to export this item.", host: host, style: .warning)
        } catch {
            alert("Couldn't export this item.", host: host, style: .warning)
        }
    }

    // MARK: multiple

    private static func presentMultiple(_ sources: [SharePackageSource], host: NSWindow?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Export Here"
        panel.message = "Choose a folder to export \(sources.count) images into."
        if let last = LastSaveDirectory.url { panel.directoryURL = last }
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let folder = panel.url else { return }
            Task { await writeMultiple(sources, to: folder, host: host) }
        }
        if let host { panel.beginSheetModal(for: host, completionHandler: handler) }
        else { handler(panel.runModal()) }
    }

    private static func writeMultiple(_ sources: [SharePackageSource], to folder: URL, host: NSWindow?) async {
        let crypto = SealPackageCryptoContext.current()
        let key = try? EncryptionSession.shared.contentKey(for: .recordings)
        let progress = BulkProgressSheet()
        if let host { progress.begin(total: sources.count, verb: "Exporting", in: host) }
        var used: Set<String> = []
        var ok = 0, failed = 0, videoOk = 0
        for (index, source) in sources.enumerated() {
            progress.update(done: index, total: sources.count, verb: "Exporting")
            do {
                let data = try await ExportImageRenderer.pngData(for: source, crypto: crypto, recordingsKey: key)
                let name = CaptureConfig.uniqueName(base: FriendlyFilename.sanitize(source.displayName), ext: "png") {
                    used.contains($0) || FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
                }
                used.insert(name)
                try data.write(to: folder.appendingPathComponent(name), options: .atomic)
                ok += 1
                if source.isVideo { videoOk += 1 }
            } catch {
                failed += 1
            }
        }
        progress.end()
        LastSaveDirectory.url = folder
        let plural = ok == 1 ? "" : "s"
        var msg = failed == 0
            ? "Exported \(ok) image\(plural)."
            : "Exported \(ok) image\(plural). \(failed) couldn't be exported (locked or unreadable)."
        // Only count videos that actually exported — call out that they're a
        // first frame, not the whole clip (use Export to Video for that).
        if videoOk > 0 {
            msg += " \(videoOk) video\(videoOk == 1 ? "" : "s") exported as first frame."
        }
        alert(msg, host: host, style: failed == 0 ? .informational : .warning)
    }

    private static func alert(_ message: String, host: NSWindow?, style: NSAlert.Style) {
        let a = NSAlert()
        a.messageText = message
        a.alertStyle = style
        a.addButton(withTitle: "OK")
        if let host { a.beginSheetModal(for: host) { _ in } } else { a.runModal() }
    }
}
