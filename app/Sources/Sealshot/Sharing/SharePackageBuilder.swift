import Foundation
import CoreGraphics
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

struct SharePackageSource: Equatable, Sendable {
    var url: URL
    var displayName: String
    var isVideo: Bool
}

enum ShareEncryption: Sendable, Equatable {
    case none
    case passphrase(String, hint: String?)
}

struct SharePackageRequest: Sendable {
    var sources: [SharePackageSource]
    var encryption: ShareEncryption
    var note: String?
    var expiresAt: Date?
    var includeOriginal: Bool
    var destination: URL
    var collection: ShareCollectionDescriptor?

    init(sources: [SharePackageSource], encryption: ShareEncryption, note: String?,
         expiresAt: Date?, includeOriginal: Bool, destination: URL,
         collection: ShareCollectionDescriptor? = nil) {
        self.sources = sources; self.encryption = encryption; self.note = note
        self.expiresAt = expiresAt; self.includeOriginal = includeOriginal
        self.destination = destination; self.collection = collection
    }
}

enum SharePackageBuildError: Error, Equatable {
    case nothingToExport
    case sourceLocked(URL)
    case sourceUnreadable(URL)
    case recordingsKeyUnavailable(URL)
    case encodingFailed
    case writeFailed(String)
}

enum SharePackageBuilder {
    /// Prepares entries and writes a `.sealshare` package. Safe to call from a
    /// detached task. `onBytes` is called with the on-disk byte size of each
    /// source after its entry is prepared; `onItem` is called once per source
    /// completed (for an item-count readout). Throws `CancellationError` if the
    /// calling `Task` is cancelled between sources.
    static func build(_ request: SharePackageRequest,
                      crypto: SealPackageCryptoContext,
                      recordingsKey: SymmetricKey?,
                      onBytes: (@Sendable (Int64) -> Void)? = nil,
                      onItem: (@Sendable () -> Void)? = nil) async throws {
        guard !request.sources.isEmpty else { throw SharePackageBuildError.nothingToExport }

        var entries: [SealSharePackage.EntryInput] = []
        var temps: [URL] = []
        defer { for u in temps { try? FileManager.default.removeItem(at: u) } }

        for src in request.sources {
            if Task.isCancelled { throw CancellationError() }
            if src.isVideo {
                try appendVideo(src, recordingsKey: recordingsKey, crypto: crypto, into: &entries, temps: &temps)
            } else {
                try await appendImage(src, includeOriginal: request.includeOriginal, crypto: crypto, into: &entries)
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: src.url.path)[.size] as? Int64) ?? 0
            onBytes?(size)
            onItem?()
        }

        let recipients: [SealSharePackage.Recipient]
        switch request.encryption {
        case .none:                      recipients = []
        case .passphrase(let pw, let h): recipients = [.passphrase(pw, hint: h)]
        }
        let options = SealSharePackage.BuildOptions(
            recipients: recipients,
            expiresAt: request.expiresAt,
            note: request.note,
            includesOriginal: request.includeOriginal,
            collection: request.collection)
        do {
            try SealSharePackage.write(entries: entries, options: options, to: request.destination)
        } catch {
            try? FileManager.default.removeItem(at: request.destination)
            throw SharePackageBuildError.writeFailed(String(describing: error))
        }
    }

    private static func appendImage(_ src: SharePackageSource, includeOriginal: Bool,
                                    crypto: SealPackageCryptoContext,
                                    into entries: inout [SealSharePackage.EntryInput]) async throws {
        if SealPackageCrypter.isLocked(src.url) && crypto.identity == nil {
            throw SharePackageBuildError.sourceLocked(src.url)
        }
        let contents: SealPackageContents
        do { contents = try await MainActor.run { try readSealPackage(at: src.url, crypto: crypto) } }
        catch { throw SharePackageBuildError.sourceUnreadable(src.url) }

        entries.append(.init(name: "\(src.displayName).png", kind: .image, uti: "public.png",
                             title: src.displayName, tags: [],
                             imageData: try pngData(from: contents.composite), videoURL: nil))
        if includeOriginal {
            entries.append(.init(name: "\(src.displayName)-original.png", kind: .image, uti: "public.png",
                                 title: "\(src.displayName) (original)", tags: [],
                                 imageData: try pngData(from: contents.source), videoURL: nil))
        }
    }

    private static func appendVideo(_ src: SharePackageSource, recordingsKey: SymmetricKey?,
                                    crypto: SealPackageCryptoContext,
                                    into entries: inout [SealSharePackage.EntryInput],
                                    temps: inout [URL]) throws {
        let videoURL: URL
        let uti: String
        switch src.url.pathExtension.lowercased() {
        case "seal":
            // A recording stored as a `.seal` package: its movie lives in the
            // encrypted `payload` entry, NOT as raw bytes at the package URL.
            // Extract it to a temp movie (mirrors VideoExportWriter).
            (videoURL, uti) = try extractSealVideo(src, crypto: crypto, temps: &temps)
        case "sealrec":
            guard let key = recordingsKey else {
                throw SharePackageBuildError.recordingsKeyUnavailable(src.url)
            }
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
            temps.append(temp)
            do { try SealedChunkFile.decryptWhole(src.url, to: temp, key: key) }
            catch { throw SharePackageBuildError.sourceUnreadable(src.url) }
            videoURL = temp
            uti = "com.apple.quicktime-movie"
        default:
            videoURL = src.url
            uti = UTType(filenameExtension: src.url.pathExtension)?.identifier ?? "public.movie"
        }
        entries.append(.init(name: src.displayName, kind: .video, uti: uti,
                             title: src.displayName, tags: [], imageData: nil, videoURL: videoURL))
    }

    /// Decrypt a video `.seal` package's payload out to a temp plaintext movie.
    /// Returns the temp URL (tracked in `temps` for cleanup) and its UTI.
    private static func extractSealVideo(_ src: SharePackageSource, crypto: SealPackageCryptoContext,
                                         temps: inout [URL]) throws -> (URL, String) {
        let contents: VideoSealContents
        do { contents = try VideoSealPackageIO.read(at: src.url, crypto: crypto) }
        catch VideoSealPackageIOError.packageLocked { throw SharePackageBuildError.sourceLocked(src.url) }
        catch { throw SharePackageBuildError.sourceUnreadable(src.url) }
        let out = VideoExportWriter.outputType(for: contents)
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension(out.ext)
        temps.append(temp)
        do { try VideoExportWriter.export(packageURL: src.url, to: temp, crypto: crypto) }
        catch { throw SharePackageBuildError.sourceUnreadable(src.url) }
        return (temp, out.type.identifier)
    }

    /// Rendered ZIP entries: image → composite PNG; video → raw (decrypted) bytes.
    /// Names are sanitized (no path separators / leading dots) and deduped within the archive.
    /// Safe to call from a detached task. `onBytes` is called with the on-disk byte size of each
    /// source after its entry is rendered; throws `CancellationError` if cancelled between sources.
    static func prepareZipEntries(_ sources: [SharePackageSource],
                                  includeOriginal: Bool,
                                  crypto: SealPackageCryptoContext,
                                  recordingsKey: SymmetricKey?,
                                  onBytes: (@Sendable (Int64) -> Void)? = nil,
                                  onItem: (@Sendable () -> Void)? = nil) async throws
        -> [(name: String, data: Data)] {
        guard !sources.isEmpty else { throw SharePackageBuildError.nothingToExport }
        var out: [(name: String, data: Data)] = []
        var used = Set<String>()
        var temps: [URL] = []
        defer { for u in temps { try? FileManager.default.removeItem(at: u) } }

        func add(_ base: String, ext: String, _ data: Data) {
            let name = CaptureConfig.uniqueName(base: safeZipName(base), ext: ext) { used.contains($0) }
            used.insert(name)
            out.append((name: name, data: data))
        }

        for src in sources {
            if Task.isCancelled { throw CancellationError() }
            if src.isVideo {
                let (data, ext) = try videoBytesForZip(src, recordingsKey: recordingsKey, crypto: crypto, temps: &temps)
                add(src.displayName, ext: ext, data)
            } else {
                if SealPackageCrypter.isLocked(src.url) && crypto.identity == nil {
                    throw SharePackageBuildError.sourceLocked(src.url)
                }
                let contents: SealPackageContents
                do { contents = try await MainActor.run { try readSealPackage(at: src.url, crypto: crypto) } }
                catch { throw SharePackageBuildError.sourceUnreadable(src.url) }
                add(src.displayName, ext: "png", try pngData(from: contents.composite))
                if includeOriginal {
                    add(src.displayName + "-original", ext: "png", try pngData(from: contents.source))
                }
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: src.url.path)[.size] as? Int64) ?? 0
            onBytes?(size)
            onItem?()
        }
        return out
    }

    private static func videoBytesForZip(_ src: SharePackageSource, recordingsKey: SymmetricKey?,
                                         crypto: SealPackageCryptoContext,
                                         temps: inout [URL]) throws -> (Data, String) {
        switch src.url.pathExtension.lowercased() {
        case "seal":
            let (temp, uti) = try extractSealVideo(src, crypto: crypto, temps: &temps)
            let ext = UTType(uti)?.preferredFilenameExtension ?? temp.pathExtension
            return (try Data(contentsOf: temp), ext.isEmpty ? "mov" : ext)
        case "sealrec":
            guard let key = recordingsKey else { throw SharePackageBuildError.recordingsKeyUnavailable(src.url) }
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
            temps.append(temp)
            do { try SealedChunkFile.decryptWhole(src.url, to: temp, key: key) }
            catch { throw SharePackageBuildError.sourceUnreadable(src.url) }
            return (try Data(contentsOf: temp), "mov")
        default:
            let ext = src.url.pathExtension.isEmpty ? "mov" : src.url.pathExtension.lowercased()
            do { return (try Data(contentsOf: src.url), ext) }
            catch { throw SharePackageBuildError.sourceUnreadable(src.url) }
        }
    }

    /// Sanitize a display name into a safe relative zip entry base (no path separators / leading dots).
    private static func safeZipName(_ s: String) -> String {
        var n = FriendlyFilename.sanitize(s)
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
        while n.hasPrefix(".") { n.removeFirst() }
        return n.isEmpty ? "file" : n
    }

    private static func pngData(from image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw SharePackageBuildError.encodingFailed
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw SharePackageBuildError.encodingFailed }
        return data as Data
    }
}
