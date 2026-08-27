import AppKit
import CryptoKit
import os.log

private let log = OSLog(subsystem: "com.seal-shot.sealshot", category: "capture")

/// Shared output side-effects for all capture paths: PNG encoding, clipboard
/// write, and `.seal` package write per `CaptureConfig.defaultOutput`.
enum CaptureOutputWriter {
    enum OutputError: Error {
        case pngEncodingFailed
        case saveFolderUnavailable(URL, underlying: Error)
        case fileWriteFailed(URL, underlying: Error)
    }

    /// Encode a CGImage to PNG at its native pixel dimensions.
    static func encodePNG(_ cgImage: CGImage) throws -> Data {
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw OutputError.pngEncodingFailed
        }
        return png
    }

    /// Apply clipboard / file side-effects. Mirrors the previous per-capturer
    /// `writeOutput`: on a file-write failure when the clipboard already
    /// succeeded, returns with `savedFileURL == nil` instead of throwing.
    @MainActor
    static func writeOutput(
        cgImage: CGImage,
        pngData png: Data,
        config: CaptureConfig,
        title: String? = nil,
        app: String? = nil
    ) throws -> (clipboardWritten: Bool, savedFileURL: URL?, packageKey: SymmetricKey?) {
        let pxW = cgImage.width
        let pxH = cgImage.height

        let output = config.defaultOutput
        let writeClipboard = (output == .clipboard || output == .both)
        let writeFile = (output == .file || output == .both)

        var clipboardWritten = false
        var savedFileURL: URL? = nil
        var packageKey: SymmetricKey? = nil

        if writeClipboard {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.declareTypes([.png], owner: nil)
            pb.setData(png, forType: .png)
            os_log("clipboard write %{public}dx%{public}d", log: log, type: .info, pxW, pxH)
            clipboardWritten = true
        }

        if writeFile {
            // With "Add captures to Library" off, the file lands in Scratch/ —
            // a subfolder the Library's per-folder projection never lists.
            // Same writer, same crypto context below, so Enhanced Security
            // covers scratch captures identically.
            let destination = ScratchCapture.destination(
                saveFolder: config.saveFolder,
                addToLibrary: ScratchCapturePreference().addsToLibrary)
            do {
                try FileManager.default.createDirectory(
                    at: destination,
                    withIntermediateDirectories: true
                )
            } catch {
                os_log("save folder unavailable at %{public}@: %{public}@",
                       log: log, type: .error, destination.path, String(describing: error))
                if writeClipboard {
                    return (clipboardWritten: clipboardWritten, savedFileURL: nil, packageKey: nil)
                }
                throw OutputError.saveFolderUnavailable(destination, underlying: error)
            }

            // Name the file per the naming policy (see captureFilenameBase):
            // "<app> <title> <date>" when "include title & app in filename" is
            // on, else a bare timestamp. Composed here, at capture time, so the
            // file is named correctly before it opens in an editor — no later
            // rename.
            let base = CaptureConfig.captureFilenameBase(
                title: title, app: app,
                includeTitle: FilenameIncludesTitlePreference().enabled,
                format: config.filenameFormat, at: Date())
            let name = CaptureConfig.uniqueName(base: base, ext: "seal") { candidate in
                FileManager.default.fileExists(
                    atPath: destination.appendingPathComponent(candidate).path)
            }
            // Directory-form URL for a .seal package so the saved URL compares
            // equal to the index/strip's `contentsOfDirectory`-sourced URLs —
            // otherwise a fresh capture's tile won't highlight as selected.
            let fileURL = destination.appendingPathComponent(
                name, isDirectory: false)
            do {
                packageKey = try writeSealPackage(
                    to: fileURL,
                    source: cgImage,
                    composite: cgImage,
                    annotations: [],
                    crop: nil,
                    crypto: SealPackageCryptoContext.current()
                )
                os_log("file write %{public}@", log: log, type: .info, fileURL.path)
                savedFileURL = fileURL
            } catch {
                os_log("file write failed at %{public}@: %{public}@",
                       log: log, type: .error, fileURL.path, String(describing: error))
                if writeClipboard {
                    return (clipboardWritten: clipboardWritten, savedFileURL: nil, packageKey: nil)
                }
                throw OutputError.fileWriteFailed(fileURL, underlying: error)
            }
        }

        return (clipboardWritten: clipboardWritten, savedFileURL: savedFileURL, packageKey: packageKey)
    }
}
