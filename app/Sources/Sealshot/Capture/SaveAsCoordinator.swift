import AppKit
import UniformTypeIdentifiers
import os.log

private let log = OSLog(subsystem: "com.seal-shot.sealshot", category: "capture")

@MainActor
final class SaveAsCoordinator {
    enum SaveError: Error {
        case writeFailed(URL, underlying: Error)
    }

    private let config: CaptureConfig

    init(config: CaptureConfig) {
        self.config = config
    }

    /// Run an NSSavePanel modally; on accept, write `pngData` atomically.
    /// Returns the saved URL, or nil if the user cancelled.
    func runSavePanel(pngData: Data) throws -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.png]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = config.renderFilename()
        // Prefer the folder the user last saved into; fall back to the
        // configured capture save folder.
        panel.directoryURL = LastSaveDirectory.url ?? config.saveFolder

        // Activate so the panel comes to front above any fullscreen target.
        NSApp.activate(ignoringOtherApps: true)

        let response = panel.runModal()
        guard response == .OK, let url = panel.url else {
            os_log("save-as cancelled by user", log: log, type: .info)
            return nil
        }
        LastSaveDirectory.remember(url)

        do {
            try pngData.write(to: url, options: .atomic)
            os_log("save-as wrote %{public}@", log: log, type: .info, url.path)
            return url
        } catch {
            os_log(
                "save-as write failed at %{public}@: %{public}@",
                log: log, type: .error, url.path, String(describing: error)
            )
            throw SaveError.writeFailed(url, underlying: error)
        }
    }
}
