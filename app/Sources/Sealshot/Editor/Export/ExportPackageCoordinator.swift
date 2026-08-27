import AppKit
import SwiftUI
import CryptoKit
import UniformTypeIdentifiers

@MainActor
final class ExportPackageCoordinator {
    private static var active: ExportPackageCoordinator?

    private let model: ExportPackageModel
    private let host: NSWindow?
    private var sheetWindow: NSWindow?
    private let progress = BulkProgressSheet()
    private let collection: ShareCollectionDescriptor?

    /// The single Task that owns the entire export (prepare + write).
    private var exportTask: Task<Void, Error>?

    private init(sources: [SharePackageSource], host: NSWindow?,
                 collection: ShareCollectionDescriptor?) {
        self.model = ExportPackageModel(sources: sources)
        self.host = host
        self.collection = collection
    }

    /// Entry point for all callers. No-op on an empty selection.
    static func present(sources: [SharePackageSource], host: NSWindow?,
                        collection: ShareCollectionDescriptor? = nil) {
        guard !sources.isEmpty else { return }
        guard active == nil else { return }   // single-flight: one export at a time (keeps the strong self-capture safe)
        let coordinator = ExportPackageCoordinator(sources: sources,
                                                   host: host ?? NSApp.keyWindow,
                                                   collection: collection)
        active = coordinator
        coordinator.showSheet()
    }

    private func showSheet() {
        let root = ExportPackageSheet(
            model: model,
            onCancel: { [weak self] in self?.dismissSheet() },
            onExport: { [weak self] in self?.chooseDestination() })
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled]
        sheetWindow = window
        if let host { host.beginSheet(window) { _ in } }
        else { window.makeKeyAndOrderFront(nil) }
    }

    private func endSheet() {
        if let host, let sheetWindow { host.endSheet(sheetWindow) }
        else { sheetWindow?.close() }
        sheetWindow = nil
    }

    private func dismissSheet() {
        endSheet()
        ExportPackageCoordinator.active = nil
    }

    private func chooseDestination() {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        switch model.format {
        case .sealshare:
            panel.allowedContentTypes = [.sealshare]
            panel.nameFieldStringValue = model.defaultFileName + ".sealshare"
        case .zip:
            panel.allowedContentTypes = [.zip]
            panel.nameFieldStringValue = model.defaultFileName + ".zip"
        }
        if let last = LastSaveDirectory.url { panel.directoryURL = last }
        let parent = sheetWindow ?? host
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            guard response == .OK, let dest = panel.url else { return }   // cancel: keep sheet open
            LastSaveDirectory.remember(dest)
            self.runExport(to: dest)
        }
        if let parent { panel.beginSheetModal(for: parent, completionHandler: handler) }
        else { handler(panel.runModal()) }
    }

    private func runExport(to dest: URL) {
        let crypto = SealPackageCryptoContext.current()
        let recordingsKey = try? EncryptionSession.shared.contentKey(for: .recordings)
        let model = self.model
        endSheet()

        let verb = model.encryptionEnabled ? "Encrypting" : "Packaging"

        // Σ source file sizes for determinate progress. The zip path processes the bytes
        // twice (render entries, then encrypt/write), so its total is doubled to keep the
        // bar moving smoothly across both phases instead of saturating at 100% halfway.
        let sourceBytes: Int64 = model.sources.reduce(Int64(0)) { $0 + fileSize(of: $1.url) }
        let totalBytes = model.format == .zip ? sourceBytes * 2 : sourceBytes

        let counter = ProgressCounter()
        let itemCounter = ProgressCounter()
        let meter = ExportProgressMeter(totalBytes: totalBytes, start: Date())
        let totalItems = model.sources.count

        if let host {
            progress.begin(total: totalItems, verb: verb, in: host,
                           onCancel: { [weak self] in self?.exportTask?.cancel() })
        }

        // Refresh loop: polls the counters every 100 ms. The bar stays byte-based
        // (smooth even for a single large video); the label shows the item count
        // ("Packaging 5 of 10…") instead of a time-left estimate.
        let refresh = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let s = meter.sample(done: counter.current, now: Date())
                let done = min(Int(itemCounter.current), totalItems)
                self.progress.setFraction(s.fraction,
                                          label: "\(verb) \(done) of \(totalItems)…",
                                          detail: nil)
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }

        // Single detached Task owns the entire export so one cancel covers all phases.
        let enc = model.encryptionEnabled
        let format = model.format
        let sources = model.sources
        let includeOriginal = model.includeOriginal
        let note = model.note.isEmpty ? nil : model.note
        let expiresAt = model.effectiveExpiry
        let password = model.effectivePassphrase
        let hint = model.hint.isEmpty ? nil : model.hint

        // NOTE: captures `self` strongly. Not a leak: the closure (and its `self`
        // reference) is freed when the task completes — every path finishes or throws.
        exportTask = Task.detached {
            do {
                switch (format, enc) {
                case (.sealshare, let isEnc):
                    let request = SharePackageRequest(
                        sources: sources,
                        encryption: isEnc ? .passphrase(password, hint: hint) : .none,
                        note: note,
                        expiresAt: expiresAt,
                        includeOriginal: includeOriginal,
                        destination: dest,
                        collection: self.collection)
                    try await SharePackageBuilder.build(request, crypto: crypto, recordingsKey: recordingsKey,
                                                        onBytes: { counter.add($0) },
                                                        onItem: { itemCounter.add(1) })
                case (.zip, let isEnc):
                    let entries = try await SharePackageBuilder.prepareZipEntries(
                        sources, includeOriginal: includeOriginal,
                        crypto: crypto, recordingsKey: recordingsKey,
                        onBytes: { counter.add($0) },
                        onItem: { itemCounter.add(1) })
                    if isEnc {
                        try AesZipWriter.write(entries: entries, password: password, to: dest,
                                               onBytes: { counter.add($0) })
                    } else {
                        try ZipWriter.write(entries: entries, to: dest,
                                            onBytes: { counter.add($0) })
                    }
                }
                await MainActor.run { refresh.cancel(); self.finish(dest: dest, encrypted: enc) }
            } catch is CancellationError {
                await MainActor.run { refresh.cancel(); self.cancelled(dest: dest) }
            } catch {
                await MainActor.run { refresh.cancel(); self.fail(error, dest: dest) }
            }
        }
    }

    // MARK: – File size helper

    private func fileSize(of url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }

    // MARK: – Completion handlers (all @MainActor via caller)

    private func finish(dest: URL, encrypted: Bool) {
        progress.end()
        let alert = NSAlert()
        alert.messageText = encrypted ? "Encrypted package saved" : "Package saved"
        if encrypted {
            alert.informativeText = "Send the passcode separately — never with the file."
        }
        alert.addButton(withTitle: "Reveal in Finder")
        alert.addButton(withTitle: "Share…")
        alert.addButton(withTitle: "Done")
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.activateFileViewerSelecting([dest])
        case .alertSecondButtonReturn:
            let picker = NSSharingServicePicker(items: [dest])
            if let view = host?.contentView {
                picker.show(relativeTo: .zero, of: view, preferredEdge: .minY)
            }
        default:
            break
        }
        ExportPackageCoordinator.active = nil
    }

    private func cancelled(dest: URL) {
        progress.end()
        try? FileManager.default.removeItem(at: dest)
        ExportPackageCoordinator.active = nil
    }

    private func fail(_ error: Error, dest: URL) {
        progress.end()
        try? FileManager.default.removeItem(at: dest)
        let alert = NSAlert()
        switch error {
        case SharePackageBuildError.sourceLocked, SharePackageBuildError.recordingsKeyUnavailable:
            alert.messageText = "Unlock Sealshot to export these items"
            alert.informativeText = "Some selected items are encrypted and need Sealshot unlocked first."
        default:
            alert.messageText = "Export failed"
            alert.informativeText = (error as? SharePackageBuildError).map { String(describing: $0) }
                ?? error.localizedDescription
        }
        alert.alertStyle = .warning
        alert.runModal()
        ExportPackageCoordinator.active = nil
    }
}
