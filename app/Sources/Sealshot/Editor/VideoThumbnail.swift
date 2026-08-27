import Foundation
import CoreGraphics
import ImageIO
import CryptoKit

/// Loads a thumbnail `CGImage` for a video item. For video `.seal` packages
/// (captureKind `.screenRecording` / `.importedVideo`), reads the `thumbnail.png`
/// entry directly from the package — no video decode. Falls back to `nil`
/// (film placeholder) on any error or missing thumbnail.
///
/// Legacy `.sealrec` and plain `.mov`/`.mp4` paths are preserved for slice 6
/// cleanup but are no longer reached for video `.seal` tiles.
@MainActor
enum VideoThumbnail {
    static func load(for url: URL) async -> CGImage? {
        if url.pathExtension.lowercased() == "seal" {
            guard let png = (try? VideoSealPackageIO.readThumbnailPNG(
                at: url, crypto: SealPackageCryptoContext.current())) ?? nil,
                  let src = CGImageSourceCreateWithData(png as CFData, nil)
            else { return nil }
            return CGImageSourceCreateImageAtIndex(src, 0, nil)
        }
        if url.pathExtension.lowercased() == RecordingsLibrary.encryptedExtension {
            guard let key = (try? EncryptionSession.shared.contentKey(for: .recordings)) ?? nil,
                  let reader = try? SealedChunkFile.Reader(url: url, key: key),
                  let png = reader.thumbnail(),
                  let src = CGImageSourceCreateWithData(png as CFData, nil)
            else { return nil }
            return CGImageSourceCreateImageAtIndex(src, 0, nil)
        }
        return await RecordingThumbnail.frame(for: url)
    }
}
