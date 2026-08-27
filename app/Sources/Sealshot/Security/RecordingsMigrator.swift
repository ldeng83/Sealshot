import Foundation
import CryptoKit
import os.log

private let log = OSLog(subsystem: "com.seal-shot.sealshot", category: "recordings-migrator")

/// Bulk encrypt/decrypt the Recordings folder when Enhanced security is toggled,
/// paralleling `SealMigrator` for screenshots. Recordings use the symmetric
/// `.recordings` content key (not the asymmetric capture-anytime key), so this
/// is a separate pass. Best-effort: a file that fails is logged and left as-is
/// (never half-converted) so enable/disable always completes; a plaintext is
/// deleted only after its `.sealrec` is written AND re-openable.
@MainActor
enum RecordingsMigrator {
    /// Encrypt every plaintext `.mov`/`.mp4` in the Recordings folder to
    /// `.sealrec`. `progress(done, total)` counts files.
    static func encryptAll(in saveFolder: URL, key: SymmetricKey,
                           progress: (Int, Int) -> Void = { _, _ in }) async {
        let folder = RecordingsLibrary.folder(forSaveFolder: saveFolder)
        let plain = RecordingsLibrary.items(in: folder).filter { !$0.isEncrypted }
        for (i, item) in plain.enumerated() {
            let out = item.url.deletingPathExtension().appendingPathExtension(RecordingsLibrary.encryptedExtension)
            let uti = utiForExtension(item.url.pathExtension)
            let thumbnail = await RecordingThumbnail.frame(for: item.url)
                .flatMap { try? CaptureOutputWriter.encodePNG($0) }
            do {
                try await Task.detached(priority: .utility) {
                    try SealedChunkFile.encrypt(plaintextURL: item.url, to: out, key: key,
                                                originalUTI: uti, thumbnail: thumbnail)
                    _ = try SealedChunkFile.Reader(url: out, key: key)   // verify before deleting source
                }.value
                try? FileManager.default.removeItem(at: item.url)
            } catch {
                try? FileManager.default.removeItem(at: out)             // drop a partial output
                os_log("recording encrypt failed for %{public}@: %{public}@", log: log, type: .error,
                       item.url.lastPathComponent, String(describing: error))
            }
            progress(i + 1, plain.count)
        }
    }

    /// Decrypt every `.sealrec` back to its original plaintext container.
    static func decryptAll(in saveFolder: URL, key: SymmetricKey,
                           progress: (Int, Int) -> Void = { _, _ in }) async {
        let folder = RecordingsLibrary.folder(forSaveFolder: saveFolder)
        let encrypted = RecordingsLibrary.items(in: folder).filter { $0.isEncrypted }
        for (i, item) in encrypted.enumerated() {
            do {
                let ext = try extForUTI(SealedChunkFile.Reader(url: item.url, key: key).originalUTI)
                let out = item.url.deletingPathExtension().appendingPathExtension(ext)
                try await Task.detached(priority: .utility) {
                    try SealedChunkFile.decryptWhole(item.url, to: out, key: key)
                }.value
                try? FileManager.default.removeItem(at: item.url)
            } catch {
                os_log("recording decrypt failed for %{public}@: %{public}@", log: log, type: .error,
                       item.url.lastPathComponent, String(describing: error))
            }
            progress(i + 1, encrypted.count)
        }
    }

    private static func utiForExtension(_ ext: String) -> String {
        ext.lowercased() == "mp4" ? "public.mpeg-4" : "com.apple.quicktime-movie"
    }
    private static func extForUTI(_ uti: String) -> String {
        uti == "public.mpeg-4" ? "mp4" : "mov"
    }
}
