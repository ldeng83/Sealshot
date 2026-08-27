import AppKit
import AVFoundation
import CryptoKit
import UniformTypeIdentifiers

enum ExportImageError: Error { case locked, renderFailed, frameExtractionFailed }

/// Renders one library/strip item to PNG: image → composite, video → first frame.
enum ExportImageRenderer {

    @MainActor
    static func pngData(for source: SharePackageSource,
                        crypto: SealPackageCryptoContext,
                        recordingsKey: SymmetricKey?) async throws -> Data {
        if source.isVideo {
            return try await videoFirstFramePNG(url: source.url, crypto: crypto, recordingsKey: recordingsKey)
        }
        return try imagePNG(url: source.url, crypto: crypto)
    }

    @MainActor
    private static func imagePNG(url: URL, crypto: SealPackageCryptoContext) throws -> Data {
        let contents: SealPackageContents
        do {
            contents = try readSealPackage(at: url, crypto: crypto)
        } catch SealPackageIOError.packageLocked {
            throw ExportImageError.locked
        }
        return try pngData(from: contents.composite)
    }

    private static func videoFirstFramePNG(url: URL, crypto: SealPackageCryptoContext,
                                           recordingsKey: SymmetricKey?) async throws -> Data {
        var tempToClean: URL?
        defer { if let t = tempToClean { try? FileManager.default.removeItem(at: t) } }
        // A container payload plays through a resource loader whose delegate is
        // held weakly; retained until the frame has been rendered.
        var payloadLoader: AnyObject?

        /// Decrypt an encrypted chunk payload to a temp movie (correct container
        /// extension so AVFoundation can open it) and return its asset.
        func decryptedAsset(payload: URL, key: SymmetricKey, ext: String) throws -> AVURLAsset {
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("export-frame-\(UUID().uuidString).\(ext)")
            tempToClean = temp                       // register BEFORE the throwing work
            try SealedChunkFile.decryptWhole(payload, to: temp, key: key)
            return AVURLAsset(url: temp)
        }

        let asset: AVURLAsset
        switch url.pathExtension.lowercased() {
        case "sealrec":
            // Legacy standalone encrypted recording.
            guard let key = recordingsKey else { throw ExportImageError.locked }
            asset = try decryptedAsset(payload: url, key: key, ext: "mov")
        case "seal":
            // Modern recording package: read the payload (encrypted → decrypt
            // whole to a temp movie; plaintext → the MIME-hinted playback asset).
            // Pointing AVAsset at the `.seal` directory is what failed before.
            let contents: VideoSealContents
            do {
                contents = try VideoSealPackageIO.read(at: url, crypto: crypto)
            } catch VideoSealPackageIOError.packageLocked {
                throw ExportImageError.locked
            }
            if let key = contents.key {
                asset = try decryptedAsset(payload: contents.payloadURL, key: key,
                                           ext: VideoExportWriter.outputType(for: contents).0)
            } else {
                let built = contents.plaintextPlaybackAsset()
                asset = built.asset
                payloadLoader = built.retain
                _ = payloadLoader   // held for the render below
            }
        default:
            asset = AVURLAsset(url: url)   // bare movie (very old import)
        }

        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .positiveInfinity   // first decodable frame at/after 0
        do {
            let cg = try await gen.image(at: .zero).image       // full resolution (no maximumSize)
            return try pngData(from: cg)
        } catch {
            throw ExportImageError.frameExtractionFailed
        }
    }

    private static func pngData(from image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
            throw ExportImageError.renderFailed
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw ExportImageError.renderFailed }
        return data as Data
    }
}
