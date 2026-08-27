import AppKit
import SwiftUI
import CryptoKit

@MainActor
final class ImportPackageCoordinator {
    private static var active: ImportPackageCoordinator?

    private let reader: SealSharePackage.Reader
    private let url: URL
    private let host: NSWindow?
    private let model: ImportPackageModel
    private let config = CaptureConfig()
    private var sheetWindow: NSWindow?
    private let progress = BulkProgressSheet()

    private init(reader: SealSharePackage.Reader, url: URL, host: NSWindow?) {
        self.reader = reader
        self.url = url
        self.host = host ?? NSApp.keyWindow
        let hint = reader.capsuleSummaries.first { $0.kind == .passphrase }?.hint
        self.model = ImportPackageModel(hint: hint, createdAt: reader.header.createdAt,
                                        expiresAt: reader.expiresAt)
    }

    /// Entry point for all open routes.
    static func open(url: URL, host: NSWindow?) {
        guard active == nil else { return }                        // one at a time
        let reader: SealSharePackage.Reader
        do { reader = try SealSharePackage.Reader(url: url) }
        catch { Self.alert(title: "Import Failed", "This isn't a valid Sealshot package.", style: .warning, host: host); return }
        if reader.isExpired {
            let when = reader.expiresAt?.formatted(.dateTime.year().month().day()) ?? "an earlier date"
            Self.alert(title: "Package Expired", "This package expired on \(when) and can no longer be opened.", style: .warning, host: host)
            return
        }
        let c = ImportPackageCoordinator(reader: reader, url: url, host: host)
        active = c
        if !reader.isEncrypted {
            // Plaintext package: no passcode needed — unlock immediately and go straight
            // to the destination picker without showing the passphrase sheet.
            let unlocked: SealSharePackage.Unlocked
            do { unlocked = try reader.unlockPlaintext() }
            catch {
                Self.alert(title: "Import Failed", "This isn't a valid Sealshot package.", style: .warning, host: host)
                active = nil
                return
            }
            c.presentOutcome(unlocked)
            return
        }
        // Encrypted: show the passphrase sheet as before.
        c.showSheet()
    }

    private func showSheet() {
        let root = ImportPackageSheet(
            model: model,
            onCancel: { [weak self] in self?.dismiss() },
            onAddToLibrary: { [weak self] in self?.start(.library) },
            onSaveToFolder: { [weak self] in self?.start(.folder) })
        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        window.styleMask = [.titled]
        sheetWindow = window
        if let host { host.beginSheet(window) { _ in } } else { window.makeKeyAndOrderFront(nil) }
    }

    /// Presents the destination picker for an already-unlocked (plaintext) package and
    /// kicks off the chosen outcome.  This is the single post-unlock dispatch point used
    /// by both the plaintext fast path and (via `start`) the passphrase sheet path.
    private func presentOutcome(_ unlocked: SealSharePackage.Unlocked) {
        Task { await presentOutcomeAsync(unlocked) }
    }

    private func presentOutcomeAsync(_ unlocked: SealSharePackage.Unlocked) async {
        let alert = NSAlert()
        alert.messageText = "Open Package"
        alert.informativeText = "Where would you like to save the contents?"
        alert.addButton(withTitle: "Add to Library")
        alert.addButton(withTitle: "Save to Folder…")
        alert.addButton(withTitle: "Cancel")
        let response: NSApplication.ModalResponse
        if let host {
            response = await withCheckedContinuation { cont in
                alert.beginSheetModal(for: host) { cont.resume(returning: $0) }
            }
        } else {
            response = alert.runModal()
        }
        switch response {
        case .alertFirstButtonReturn:
            await runLibrary(unlocked)
        case .alertSecondButtonReturn:
            await runFolder(unlocked)
        default:
            ImportPackageCoordinator.active = nil
        }
    }

    private enum Destination { case library, folder }

    private func start(_ destination: Destination) {
        guard model.canSubmit else { return }
        model.errorMessage = nil
        model.setWorking(true)
        let passphrase = model.passphrase
        Task {
            let unlocked: SealSharePackage.Unlocked
            do {
                unlocked = try reader.unlock(passphrase: passphrase)
            } catch SealSharePackage.Error.expired {
                model.setWorking(false)
                finishWithExpiry(); return
            } catch {
                model.setWorking(false)
                model.errorMessage = "Incorrect passcode."
                return
            }
            model.setWorking(false)
            switch destination {
            case .library: await runLibrary(unlocked)
            case .folder:  await runFolder(unlocked)
            }
        }
    }

    private func runLibrary(_ unlocked: SealSharePackage.Unlocked) async {
        // Ensure unlocked when encryption is on so the recordings key is available.
        let session = EncryptionSession.shared
        if session.isEnabled && !session.isUnlocked {
            let ok = (try? await session.unlock()) ?? false
            if !ok { return }                                      // declined → stay on sheet
        }
        let crypto = SealPackageCryptoContext.current()
        let saveFolder = config.saveFolder
        let filenameFormat = config.filenameFormat

        // Collection round-trip: if the package names a collection, ask how to import.
        var collectionID: UUID? = nil
        if let descriptor = unlocked.manifest.collection {
            switch await askCollectionChoice(name: descriptor.name) {
            case .cancel:
                ImportPackageCoordinator.active = nil
                endSheet()
                return
            case .asItems:
                collectionID = nil
            case .asCollection:
                collectionID = await makeLocalCollection(named: descriptor.name)
            }
        }

        endSheet()
        if let host { progress.begin(total: unlocked.manifest.entries.count, verb: "Importing", in: host) }
        do {
            let summary = try await SharePackageImporter.importToLibrary(
                unlocked, saveFolder: saveFolder, filenameFormat: filenameFormat, crypto: crypto,
                now: Date(), collectionID: collectionID) { done, total in
                    self.progress.update(done: done, total: total, verb: "Importing")
                }
            progress.end()
            if collectionID != nil {
                NotificationCenter.default.post(name: .collectionsDidChange, object: nil)
            }
            showLibraryResult(summary)
        } catch {
            progress.end()
            Self.alert(title: "Import Failed", error.localizedDescription, style: .warning, host: host)
        }
        ImportPackageCoordinator.active = nil
    }

    private enum CollectionChoice { case asCollection, asItems, cancel }

    /// Ask whether to import the package as its named collection or as loose items.
    private func askCollectionChoice(name: String) async -> CollectionChoice {
        let alert = NSAlert()
        alert.messageText = "Import “\(name)”"
        alert.informativeText = "This package is a collection. How would you like to import it?"
        alert.addButton(withTitle: "As Collection")       // .alertFirstButtonReturn
        alert.addButton(withTitle: "As Individual Items")  // .alertSecondButtonReturn
        alert.addButton(withTitle: "Cancel")               // .alertThirdButtonReturn
        let response: NSApplication.ModalResponse
        if let parent = sheetWindow ?? host {
            response = await withCheckedContinuation { cont in
                alert.beginSheetModal(for: parent) { cont.resume(returning: $0) }
            }
        } else {
            response = alert.runModal()
        }
        switch response {
        case .alertFirstButtonReturn:  return .asCollection
        case .alertSecondButtonReturn: return .asItems
        default:                       return .cancel
        }
    }

    /// Create a fresh local collection, disambiguating on name clash (decision B).
    /// Returns nil if the collection store is unavailable (library locked or a
    /// persistence failure), in which case the caller imports loose items.
    private func makeLocalCollection(named base: String) async -> UUID? {
        guard let store = try? CollectionStore.openCurrentLibraryStore() else { return nil }
        let existing = Set(await store.all().map(\.name))
        let name = CollectionImportNaming.resolvedName(base: base, existing: existing)
        return try? await store.create(name: name, now: Date()).id
    }

    private func runFolder(_ unlocked: SealSharePackage.Unlocked) async {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Save Here"
        panel.message = "Choose a folder to save the files into."
        let chosen: URL?
        if let parent = sheetWindow ?? host {
            chosen = await withCheckedContinuation { cont in
                panel.beginSheetModal(for: parent) { cont.resume(returning: $0 == .OK ? panel.url : nil) }
            }
        } else {
            chosen = panel.runModal() == .OK ? panel.url : nil
        }
        guard let folder = chosen else { return }                  // cancel → stay on sheet
        let dest = folder.appendingPathComponent(url.deletingPathExtension().lastPathComponent, isDirectory: true)
        endSheet()
        if let host { progress.begin(total: unlocked.manifest.entries.count, verb: "Saving", in: host) }
        do {
            let summary = try await SharePackageImporter.importToFolder(unlocked, destinationFolder: dest) { done, total in
                self.progress.update(done: done, total: total, verb: "Saving")
            }
            progress.end()
            showFolderResult(summary, folder: dest)
        } catch {
            progress.end()
            Self.alert(title: "Save Failed", error.localizedDescription, style: .warning, host: host)
        }
        ImportPackageCoordinator.active = nil
    }

    // MARK: Results / helpers

    private func showLibraryResult(_ s: ImportSummary) {
        if !s.importedURLs.isEmpty {
            NotificationCenter.default.post(name: .captureFilesImported,
                                            object: s.importedURLs)
        }
        var msg = "Imported \(s.imported) item\(s.imported == 1 ? "" : "s") into your Library."
        if !s.failed.isEmpty { msg += " \(s.failed.count) couldn't be imported." }
        Self.alert(title: "Import Complete", msg, style: .informational, host: host)
    }

    private func showFolderResult(_ s: ImportSummary, folder: URL) {
        let alert = NSAlert()
        alert.messageText = "Saved \(s.imported) item\(s.imported == 1 ? "" : "s")"
        alert.informativeText = folder.path + (s.failed.isEmpty ? "" : "\n\(s.failed.count) couldn't be saved.")
        alert.addButton(withTitle: "Reveal in Finder")
        alert.addButton(withTitle: "Done")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        }
    }

    private func finishWithExpiry() {
        endSheet()
        Self.alert(title: "Package Expired",
                   "This package has expired and can no longer be opened.",
                   style: .warning, host: host)
        ImportPackageCoordinator.active = nil
    }

    private func endSheet() {
        if let host, let sheetWindow { host.endSheet(sheetWindow) } else { sheetWindow?.close() }
        sheetWindow = nil
    }

    private func dismiss() { endSheet(); ImportPackageCoordinator.active = nil }

    /// Import notices use a custom centered card (ImportNoticeView) instead
    /// of NSAlert: on macOS 26 the system alert is leading-aligned (icon
    /// pinned top-left) and no NSAlert configuration centers it. Presented
    /// as a sheet on `host` (fire-and-forget) or app-modal without one.
    private static func alert(title: String, _ text: String, style _: NSAlert.Style, host: NSWindow?) {
        var dismiss: () -> Void = {}
        let card = ImportNoticeView(title: title, message: text, onOK: { dismiss() })
        let window = NSWindow(contentViewController: NSHostingController(rootView: card))
        window.styleMask = [.titled]
        window.title = title
        // -close would RELEASE the window (isReleasedWhenClosed defaults to true),
        // so stop the modal only and order the window out after runModal returns.
        //
        // The runModal branch below is safe only because both callers pass
        // host: NSApp.keyWindow and reach here from AppKit contexts, never from
        // inside a SwiftUI Button action — see FeedbackComposer.present() for why
        // a nested modal loop started during a SwiftUI update hangs the app.
        window.isReleasedWhenClosed = false
        if let host {
            dismiss = { [weak host] in host?.endSheet(window) }
            host.beginSheet(window) { _ in }
        } else {
            window.center()
            dismiss = { NSApp.stopModal() }
            NSApp.runModal(for: window)
            window.orderOut(nil)
        }
    }
}
