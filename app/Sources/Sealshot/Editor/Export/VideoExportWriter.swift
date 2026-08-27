import Foundation
import UniformTypeIdentifiers

/// Pure, UI-free export of a video `.seal` payload to a plaintext `.mov`/`.mp4`.
///
/// Streams: the payload (possibly gigabytes) is never buffered in RAM — the
/// encrypted path streams via `SealedChunkFile.decryptWhole`, the plaintext path
/// streams the raw entry chunk-by-chunk. Both report byte progress and honor
/// cancellation between chunks. Atomic: writes a sibling temp then renames into
/// `dest`, so a failure (or cancel) never leaves a half-written file at the destination.
enum VideoExportWriter {

    /// Resolve the output extension + content type for the exported file,
    /// preserving the original container. Reads only the small header — never the payload.
    static func outputType(for contents: VideoSealContents) -> (ext: String, type: UTType) {
        if let key = contents.key {
            // Encrypted: the SealedChunkFile header carries the original UTI.
            if let reader = try? SealedChunkFile.Reader(url: contents.payload.fileURL, key: key,
                                                       baseOffset: contents.payload.offset),
               let type = UTType(reader.originalUTI),
               let ext = type.preferredFilenameExtension {
                return (ext, type)
            }
        } else if let brand = VideoSealPackageIO.ftypMajorBrand(at: contents.payload) {
            // Plaintext: sniff the ISO-BMFF `ftyp` major brand.
            if brand == "qt  " { return ("mov", .quickTimeMovie) }
            return ("mp4", .mpeg4Movie)
        }
        return ("mov", .quickTimeMovie)   // fallback — recorder output is always .mov
    }

    /// Decrypt (or copy) the video payload out to `dest`.
    static func export(packageURL: URL, to dest: URL,
                       crypto: SealPackageCryptoContext,
                       progress: (Int, Int) -> Void = { _, _ in },
                       isCancelled: () -> Bool = { false }) throws {
        let contents = try VideoSealPackageIO.read(at: packageURL, crypto: crypto)
        let fm = FileManager.default
        let tmp = dest.deletingLastPathComponent()
            .appendingPathComponent(".\(dest.lastPathComponent).export-\(UUID().uuidString)")
        do {
            if let key = contents.key {
                // Decrypt straight out of the container — the payload is a
                // byte range in it, not a file of its own.
                try SealedChunkFile.decryptWhole(contents.payload.fileURL, to: tmp, key: key,
                                                 baseOffset: contents.payload.offset,
                                                 progress: progress, isCancelled: isCancelled)
            } else {
                try contents.payload.stream(to: tmp, progress: progress,
                                            isCancelled: isCancelled)
            }
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.moveItem(at: tmp, to: dest)
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }

    /// Copy a plaintext payload chunk-by-chunk (never buffering the whole file),
    /// reporting `(bytesCopied, total)` after each chunk and throwing
    /// `CancellationError` between chunks when `isCancelled()` returns true.
    private static func streamCopy(from src: URL, to dst: URL,
                                   progress: (Int, Int) -> Void,
                                   isCancelled: () -> Bool) throws {
        let fm = FileManager.default
        let total = (try? fm.attributesOfItem(atPath: src.path)[.size] as? Int) ?? 0
        let input = try FileHandle(forReadingFrom: src)
        defer { try? input.close() }
        fm.createFile(atPath: dst.path, contents: nil)
        guard let output = try? FileHandle(forWritingTo: dst) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? output.close() }

        let chunkSize = 1 << 20   // 1 MiB
        var copied = 0
        progress(0, total)
        while true {
            if isCancelled() { throw CancellationError() }
            let chunk = (try input.read(upToCount: chunkSize)) ?? Data()
            if chunk.isEmpty { break }
            try output.write(contentsOf: chunk)
            copied += chunk.count
            progress(copied, total)
        }
    }
}
