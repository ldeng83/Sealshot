import AVFoundation
import Foundation
import CoreGraphics
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

struct ImportSummary: Equatable {
    var imported: Int
    var failed: [String]
    /// Destinations of the files that landed — drives the Import ⌘Z event.
    var importedURLs: [URL] = []
}

enum SharePackageImporter {

    // MARK: Library

    static func importToLibrary(_ unlocked: SealSharePackage.Unlocked,
                                saveFolder: URL,
                                filenameFormat: String,
                                crypto: SealPackageCryptoContext,
                                now: Date,
                                collectionID: UUID? = nil,
                                progress: @escaping @MainActor (Int, Int) -> Void) async throws -> ImportSummary {
        var imported = 0
        var failed: [String] = []
        var importedURLs: [URL] = []
        let entries = unlocked.manifest.entries
        for (index, entry) in entries.enumerated() {
            do {
                let sealURL: URL
                switch entry.kind {
                case .image:
                    sealURL = try await depositImage(entry, unlocked: unlocked, saveFolder: saveFolder,
                                                     filenameFormat: filenameFormat, crypto: crypto, now: now)
                case .video:
                    sealURL = try await depositVideo(entry, unlocked: unlocked, saveFolder: saveFolder,
                                                     filenameFormat: filenameFormat, crypto: crypto, now: now)
                }
                if let collectionID {
                    try? await SealMetadataStore.setCollections([collectionID], to: sealURL)
                }
                imported += 1
                importedURLs.append(sealURL)
            } catch {
                failed.append(entry.name)
            }
            await progress(index + 1, entries.count)
        }
        return ImportSummary(imported: imported, failed: failed, importedURLs: importedURLs)
    }

    // async because writeSealPackage is @MainActor
    private static func depositImage(_ entry: ShareManifestEntry, unlocked: SealSharePackage.Unlocked,
                                     saveFolder: URL, filenameFormat: String,
                                     crypto: SealPackageCryptoContext, now: Date) async throws -> URL {
        let data = try unlocked.imageData(forEntry: entry.name)
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let base = CaptureConfig.composeBase(subject: nil, format: filenameFormat, at: now)
        let name = CaptureConfig.uniqueName(base: base, ext: "seal") { candidate in
            FileManager.default.fileExists(atPath: saveFolder.appendingPathComponent(candidate).path)
        }
        let dest = saveFolder.appendingPathComponent(name)
        _ = try writeSealPackage(to: dest, source: image, composite: image,
                                 annotations: [], crop: nil, crypto: crypto)
        return dest
    }

    /// Deposit a shared video as a unified video `.seal` package (the same
    /// format the recorder writes) so it plays everywhere in-app. The old
    /// deposit minted legacy `.sealrec` / bare movie files, which the canvas
    /// player can no longer open. Lands in the main save folder alongside
    /// images, mirroring RecordingCoordinator.finalize.
    private static func depositVideo(_ entry: ShareManifestEntry, unlocked: SealSharePackage.Unlocked,
                                     saveFolder: URL, filenameFormat: String,
                                     crypto: SealPackageCryptoContext, now: Date) async throws -> URL {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
        // Kept on success too — VideoSealPackageIO.write consumes the temp;
        // this only mops up the failure paths.
        defer { try? FileManager.default.removeItem(at: temp) }
        try unlocked.extractVideo(forEntry: entry.name, to: temp)

        // Probe the payload (mirrors RecordingCoordinator.finalize): the
        // manifest carries duration/size/audio so the Library never has to
        // open the (possibly encrypted) payload for metadata.
        let asset = AVURLAsset(url: temp)
        let duration = (try? await asset.load(.duration))?.seconds ?? 0
        var frameSize = CGSize.zero
        if let track = (try? await asset.loadTracks(withMediaType: .video))?.first {
            frameSize = (try? await track.load(.naturalSize)) ?? .zero
        }
        let hasAudio = ((try? await asset.loadTracks(withMediaType: .audio))?.isEmpty == false)
        let thumbnail = await RecordingThumbnail.frame(for: temp)
            .flatMap { try? CaptureOutputWriter.encodePNG($0) }

        let fmt = ISO8601DateFormatter()
        let stamp = fmt.string(from: now)
        let manifest = SealManifest(
            version: SealManifest.currentVersion,
            createdISO8601: stamp,
            modifiedISO8601: stamp,
            sourceSize: SealManifest.Size(width: Int(frameSize.width),
                                          height: Int(frameSize.height)),
            sourceApp: nil,
            enhanceParams: nil,
            captureKind: .importedVideo,
            video: VideoInfo(durationSeconds: duration, hasAudio: hasAudio))

        let base = CaptureConfig.composeBase(subject: nil, format: filenameFormat, at: now)
        let name = CaptureConfig.uniqueName(base: base, ext: "seal") {
            FileManager.default.fileExists(atPath: saveFolder.appendingPathComponent($0).path)
        }
        let dest = saveFolder.appendingPathComponent(name)
        try VideoSealPackageIO.write(to: dest, payloadTempURL: temp, originalUTI: entry.uti,
                                     manifest: manifest, thumbnailPNG: thumbnail, crypto: crypto)
        return dest
    }

    // MARK: Folder

    static func importToFolder(_ unlocked: SealSharePackage.Unlocked,
                               destinationFolder: URL,
                               progress: @escaping @MainActor (Int, Int) -> Void) async throws -> ImportSummary {
        try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
        var imported = 0
        var failed: [String] = []
        var importedURLs: [URL] = []
        let entries = unlocked.manifest.entries
        for (index, entry) in entries.enumerated() {
            do {
                let fileName = uniqueFileName(safeFileName(for: entry), in: destinationFolder)
                let dest = destinationFolder.appendingPathComponent(fileName)
                switch entry.kind {
                case .image: try unlocked.imageData(forEntry: entry.name).write(to: dest, options: .atomic)
                case .video: try unlocked.extractVideo(forEntry: entry.name, to: dest)
                }
                imported += 1
                importedURLs.append(dest)
            } catch {
                failed.append(entry.name)
            }
            await progress(index + 1, entries.count)
        }
        return ImportSummary(imported: imported, failed: failed, importedURLs: importedURLs)
    }

    private static func safeFileName(for entry: ShareManifestEntry) -> String {
        let raw = (entry.name as NSString).lastPathComponent
        switch entry.kind {
        case .image:
            return (raw as NSString).pathExtension.lowercased() == "png" ? raw : raw + ".png"
        case .video:
            let ext = UTType(entry.uti)?.preferredFilenameExtension ?? "mov"
            return (raw as NSString).pathExtension.lowercased() == ext.lowercased() ? raw : raw + "." + ext
        }
    }

    private static func uniqueFileName(_ name: String, in folder: URL) -> String {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        return CaptureConfig.uniqueName(base: base, ext: ext) {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
    }
}
