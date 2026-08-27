import Foundation
import CryptoKit
import AVFoundation

// MARK: - Public types

/// Result of reading a video `.seal` package (without decrypting the payload).
/// Where a recording's bytes actually live.
///
/// A legacy directory package holds the payload as its own file; a container
/// holds it as a stored entry at a known offset. Every consumer — playback,
/// export, drag-out, the summarizer — needs the same three facts, so they are
/// resolved once here rather than each one guessing at a path.
struct VideoPayloadLocation {
    /// The file to read: the payload itself, or the container holding it.
    let fileURL: URL
    /// Where the payload starts in that file (0 for a standalone payload).
    let offset: Int64
    /// How many bytes it runs for.
    let length: Int64

    var isInsideContainer: Bool { offset > 0 }

    /// Copy the payload out to a standalone file. Streamed in chunks — a
    /// recording is gigabytes — and only for consumers that genuinely need a
    /// file of their own (export to a chosen location, drag-out).
    /// `progress` reports (copied, total) as it goes and `isCancelled` aborts
    /// with `CancellationError` — an export of a gigabyte recording has to be
    /// both interruptible and answerable about how far along it is.
    func stream(to destination: URL,
                progress: (Int, Int) -> Void = { _, _ in },
                isCancelled: () -> Bool = { false }) throws {
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let input = try FileHandle(forReadingFrom: fileURL)
        guard let output = try? FileHandle(forWritingTo: destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? input.close(); try? output.close() }
        try input.seek(toOffset: UInt64(offset))
        let total = Int(length)
        var copied = 0
        progress(0, total)
        var remaining = length
        while remaining > 0 {
            if isCancelled() { throw CancellationError() }
            let want = Int(min(remaining, 1 << 20))
            guard let chunk = try input.read(upToCount: want), !chunk.isEmpty else { break }
            try output.write(contentsOf: chunk)
            copied += chunk.count
            remaining -= Int64(chunk.count)
            progress(copied, total)
        }
    }
}

struct VideoSealContents {
    /// Decoded manifest from the package.
    let manifest: SealManifest
    /// URL pointing to the `payload` entry inside the package directory.
    let payloadURL: URL
    /// Where the payload bytes are — the locator every consumer should use.
    let payload: VideoPayloadLocation
    /// Content-encryption key for the chunked payload; `nil` when the package is plaintext.
    let key: SymmetricKey?

    /// AVURLAsset for a PLAINTEXT payload (`key == nil`; encrypted payloads
    /// stream through `SealedRecordingPlayer` instead).
    ///
    /// The payload entry is a bare extension-less `payload` file, and
    /// AVFoundation infers the container format from the filename extension —
    /// handed the raw URL it refuses the file (-11828 "Cannot Open") even
    /// though the bytes are a valid movie. The MIME override names the
    /// container, sniffed from the ISO-BMFF `ftyp` box.
    /// A plaintext payload INSIDE a container has no URL of its own, so it
    /// plays through a range-serving resource loader instead — the same shape
    /// the encrypted path already uses. The loader is returned alongside
    /// because its delegate is held weakly; drop it and playback stalls.
    func plaintextPlaybackAsset() -> (asset: AVURLAsset, retain: AnyObject?) {
        let brand = VideoSealPackageIO.ftypMajorBrand(at: payload)
        let mime = VideoSealPackageIO.payloadMIMEType(ftypBrand: brand)
        if payload.isInsideContainer,
           let built = try? ContainerPayloadPlayer.asset(
               for: payload,
               contentType: VideoSealPackageIO.payloadUTI(ftypBrand: brand),
               named: payloadURL.lastPathComponent) {
            return (built.0, built.1)
        }
        return (AVURLAsset(url: payloadURL, options: [
            AVURLAssetOverrideMIMETypeKey: mime,
        ]), nil)
    }
}

// MARK: - Errors

enum VideoSealPackageIOError: Error {
    /// The package carries a `lock.json` but no identity was supplied to unwrap the CEK.
    case packageLocked
    /// The `payload` entry is absent from the package directory.
    case payloadMissing
}

// MARK: - I/O

/// Streaming writer + reader for a video `.seal` package.
///
/// The video payload may be gigabytes — it is **never** loaded into RAM.
/// - Encrypted path: `SealedChunkFile.encrypt` streams plaintext→ciphertext chunk by chunk.
/// - Plaintext path: `FileManager.moveItem` moves the file O(1) (same-volume rename).
///
/// Only the small `manifest.json` (≤ a few KB) and optional `thumbnail.png` are ever in memory.
/// Assembly happens in a same-volume temp directory; a single atomic rename puts it in place.
enum VideoSealPackageIO {

    // MARK: Entry name constants

    /// Internal (not private): the format converter must recognise a streamed
    /// payload by name without reading it.
    enum Entry {
        static let manifest  = "manifest.json"
        static let thumbnail = "thumbnail.png"
        static let payload   = "payload"
    }

    // MARK: - Write

    /// Assemble a video `.seal` package at `packageURL`.
    ///
    /// - `payloadTempURL` is **consumed**: on return it no longer exists on disk (moved in
    ///   the plaintext case, encrypted-then-removed in the encrypted case).
    /// - Streaming: the payload is never buffered in RAM.
    /// - Atomic: assembled in a same-volume temp directory, then renamed into place.
    ///   Any pre-existing package at `packageURL` is replaced atomically.
    static func write(
        to packageURL: URL,
        payloadTempURL: URL,
        originalUTI: String,
        manifest: SealManifest,
        thumbnailPNG: Data?,
        crypto: SealPackageCryptoContext
    ) throws {
        // A staging FILE beside the final package: same volume, so the swap
        // into place is a rename.
        let parent = packageURL.deletingLastPathComponent()
        let staging = parent.appendingPathComponent(
            ".\(packageURL.lastPathComponent).tmp-\(UUID().uuidString)", isDirectory: false)
        let fm = FileManager.default

        do {
            let manifestData = try manifest.encodeJSON()
            // The payload is STREAMED into the container from a file — never
            // loaded, because a recording is gigabytes.
            var sources: [(name: String, source: SealContainer.Source)] = []
            var consumable: [URL] = [payloadTempURL]

            if let pk = crypto.publicKey, let gen = crypto.generation {
                // ── Encrypted path ───────────────────────────────────────────
                var small: [String: Data] = [Entry.manifest: manifestData]
                if let thumb = thumbnailPNG { small[Entry.thumbnail] = thumb }
                // sealEntries AES-GCM-seals every value with a fresh CEK and
                // adds lock.json.
                let (sealed, cek) = try SealPackageCrypter.sealEntries(
                    small, publicKey: pk, generation: gen)
                for (name, data) in sealed { sources.append((name, .data(data))) }

                // Stream-encrypt the payload to a scratch file (never in RAM),
                // then stream that into the container.
                let encrypted = parent.appendingPathComponent(
                    ".\(packageURL.lastPathComponent).enc-\(UUID().uuidString)")
                try SealedChunkFile.encrypt(
                    plaintextURL: payloadTempURL,
                    to: encrypted,
                    key: cek,
                    originalUTI: originalUTI,
                    thumbnail: nil   // thumbnail lives as its own package entry
                )
                sources.append((Entry.payload, .file(encrypted)))
                consumable.append(encrypted)
            } else {
                // ── Plaintext path ───────────────────────────────────────────
                sources.append((Entry.manifest, .data(manifestData)))
                if let thumb = thumbnailPNG {
                    sources.append((Entry.thumbnail, .data(thumb)))
                }
                sources.append((Entry.payload, .file(payloadTempURL)))
            }

            try SealContainer.write(sources: sources, to: staging)
            // Temps are consumed either way — the bytes live in the container
            // now, and a stranded gigabyte scratch file is its own bug.
            for url in consumable { try? fm.removeItem(at: url) }

            if fm.fileExists(atPath: packageURL.path) {
                try fm.removeItem(at: packageURL)
            }
            try fm.moveItem(at: staging, to: packageURL)

        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    // MARK: - Container sniffing (plaintext payloads)

    /// Read the major brand from the `ftyp` box at the head of an ISO-BMFF file.
    /// Layout: [4-byte size][4 bytes "ftyp"][4-byte major brand]. Returns nil if absent.
    /// Sniff the ISO-BMFF major brand at a payload's start — which is the
    /// container's entry offset when it lives inside one, not byte zero.
    static func ftypMajorBrand(at location: VideoPayloadLocation) -> String? {
        guard let h = try? FileHandle(forReadingFrom: location.fileURL) else { return nil }
        defer { try? h.close() }
        if location.offset > 0 { try? h.seek(toOffset: UInt64(location.offset)) }
        guard let head = try? h.read(upToCount: 12), head.count == 12 else { return nil }
        guard head.subdata(in: 4..<8).elementsEqual("ftyp".utf8) else { return nil }
        return String(bytes: head.subdata(in: 8..<12), encoding: .ascii)
    }

    static func ftypMajorBrand(at url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let head = try? h.read(upToCount: 12), head.count == 12 else { return nil }
        guard head.subdata(in: 4..<8).elementsEqual("ftyp".utf8) else { return nil }
        return String(bytes: head.subdata(in: 8..<12), encoding: .ascii)
    }

    /// MIME type for a plaintext payload from its `ftyp` major brand. Unknown
    /// or unsniffable → quicktime, the recorder's default container.
    /// UTI for a plaintext payload from its `ftyp` major brand.
    ///
    /// A resource loader answers `contentInformationRequest.contentType` with a
    /// UTI, not a MIME type — the encrypted path passes the one recorded in the
    /// sealed header. Handing it a MIME string instead makes the asset simply
    /// report itself unplayable, with no error to explain why.
    static func payloadUTI(ftypBrand: String?) -> String {
        guard let brand = ftypBrand else { return "com.apple.quicktime-movie" }
        return brand == "qt  " ? "com.apple.quicktime-movie" : "public.mpeg-4"
    }

    static func payloadMIMEType(ftypBrand: String?) -> String {
        guard let brand = ftypBrand else { return "video/quicktime" }
        return brand == "qt  " ? "video/quicktime" : "video/mp4"
    }

    // MARK: - Read thumbnail

    /// Read the poster `thumbnail.png` entry from a video `.seal` package,
    /// decrypting with the package CEK when the package is encrypted.
    /// Cheap — never touches the payload.
    ///
    /// Returns `nil` when the entry is absent (no thumbnail was written).
    /// Throws `VideoSealPackageIOError.packageLocked` when the package is
    /// encrypted but no identity is available to unwrap the CEK.
    static func readThumbnailPNG(
        at packageURL: URL,
        crypto: SealPackageCryptoContext
    ) throws -> Data? {
        if let headerData = sealEntryData(LockHeader.filename, at: packageURL) {
            // ── Encrypted package ────────────────────────────────────────────────────────────
            guard let identity = crypto.identity else {
                throw VideoSealPackageIOError.packageLocked
            }
            let header = try JSONDecoder().decode(LockHeader.self, from: headerData)
            let cek    = try SealPackageCrypter.unwrapCEK(header, identity: identity)

            guard let sealedThumb = sealEntryData(Entry.thumbnail, at: packageURL) else {
                return nil
            }
            return try SealedBlob.open(sealedThumb, with: cek)

        } else {
            // ── Plaintext package ────────────────────────────────────────────
            return sealEntryData(Entry.thumbnail, at: packageURL)
        }
    }

    // MARK: - Read

    /// Resolve a video `.seal` package for playback or inspection.
    ///
    /// The payload is **not** decrypted; the caller receives the URL to the on-disk `payload`
    /// entry and the CEK (when encrypted) so it can hand them to `SealedChunkFile.Reader`
    /// or a resource-loader delegate.
    static func read(
        at packageURL: URL,
        crypto: SealPackageCryptoContext
    ) throws -> VideoSealContents {
        let payload = try payloadLocation(in: packageURL)

        if let headerData = sealEntryData(LockHeader.filename, at: packageURL) {
            // ── Encrypted package ────────────────────────────────────────────
            guard let identity = crypto.identity else {
                throw VideoSealPackageIOError.packageLocked
            }
            let header = try JSONDecoder().decode(LockHeader.self, from: headerData)
            let cek    = try SealPackageCrypter.unwrapCEK(header, identity: identity)

            guard let sealedManifest = sealEntryData(Entry.manifest, at: packageURL) else {
                throw VideoSealPackageIOError.payloadMissing
            }
            let manifestData = try SealedBlob.open(sealedManifest, with: cek)
            let manifest     = try SealManifest.decodeJSON(from: manifestData)

            return VideoSealContents(manifest: manifest, payloadURL: payload.fileURL,
                                     payload: payload, key: cek)

        } else {
            // ── Plaintext package ────────────────────────────────────────────
            guard let manifestData = sealEntryData(Entry.manifest, at: packageURL) else {
                throw VideoSealPackageIOError.payloadMissing
            }
            let manifest = try SealManifest.decodeJSON(from: manifestData)

            return VideoSealContents(manifest: manifest, payloadURL: payload.fileURL,
                                     payload: payload, key: nil)
        }
    }

    /// Resolve where the payload bytes live, for either package shape.
    static func payloadLocation(in packageURL: URL) throws -> VideoPayloadLocation {
        if SealContainer.isContainer(packageURL) {
            guard let entry = try SealContainer.Reader(url: packageURL).entry(Entry.payload) else {
                throw VideoSealPackageIOError.payloadMissing
            }
            return VideoPayloadLocation(fileURL: packageURL,
                                        offset: Int64(entry.dataOffset),
                                        length: Int64(entry.size))
        }
        let url = packageURL.appendingPathComponent(Entry.payload)
        guard let size = (try? FileManager.default.attributesOfItem(
            atPath: url.path)[.size] as? Int64) ?? nil else {
            throw VideoSealPackageIOError.payloadMissing
        }
        return VideoPayloadLocation(fileURL: url, offset: 0, length: size)
    }
}
