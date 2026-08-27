import Foundation
import CryptoKit

/// A framed, random-access AES-256-GCM container for large files (recordings).
/// Unlike `SealedBlob` (whole-buffer, non-seekable), this seals fixed-size
/// plaintext chunks independently so a reader can decrypt only the chunks a
/// byte-range touches — what `AVAssetResourceLoaderDelegate` needs for seeking.
///
/// Layout:
///   magic "SREC" (4) | version (1) | sealedHeaderLength (4, LE)
///   sealedHeader  — AES.GCM combined, AAD = "header" — JSON `Header`
///   chunk 0 | chunk 1 | …            — each AES.GCM combined, AAD = index (8, LE)
///
/// Every non-final chunk holds exactly `chunkSize` plaintext bytes, so chunk
/// `i` begins at `dataStart + i*(chunkSize + 28)` (28 = 12-byte nonce + 16-byte
/// tag) — O(1) seek. The header is itself sealed, so geometry and the thumbnail
/// are hidden and tamper-evident; the chunk index in each chunk's AAD detects
/// reordering / truncation that per-chunk GCM alone would miss.
enum SealedChunkFile {
    enum Error: Swift.Error { case notSealed, unsupportedVersion(UInt8), corrupt }

    static let magic = Data("SREC".utf8)
    static let version: UInt8 = 1
    static let overhead = 28          // GCM nonce (12) + tag (16)
    static let defaultChunkSize = 1 << 20   // 1 MiB plaintext

    private struct Header: Codable {
        let chunkSize: Int
        let originalLength: Int64
        let originalUTI: String
        let thumbnailBase64: String?
    }

    // MARK: - Encrypt (streaming)

    /// Stream-encrypt `plaintextURL` into a `.sealrec` container at `outURL`.
    /// `thumbnail` (raw image bytes) is stored inside the sealed header.
    /// `progress(done, total)` reports plaintext bytes processed.
    static func encrypt(plaintextURL: URL, to outURL: URL, key: SymmetricKey,
                        originalUTI: String, thumbnail: Data? = nil,
                        chunkSize: Int = defaultChunkSize,
                        progress: (Int, Int) -> Void = { _, _ in }) throws {
        precondition(chunkSize > 0)
        let total = (try FileManager.default.attributesOfItem(atPath: plaintextURL.path)[.size] as? Int64) ?? 0
        let header = Header(chunkSize: chunkSize, originalLength: total, originalUTI: originalUTI,
                            thumbnailBase64: thumbnail?.base64EncodedString())
        let sealedHeader = try gcmSeal(try JSONEncoder().encode(header), key: key, aad: headerAAD)

        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        guard let out = try? FileHandle(forWritingTo: outURL) else { throw Error.corrupt }
        defer { try? out.close() }
        try out.write(contentsOf: magic + [version] + uint32LE(UInt32(sealedHeader.count)) + sealedHeader)

        let input = try FileHandle(forReadingFrom: plaintextURL)
        defer { try? input.close() }
        var index = 0
        var done = 0
        while true {
            let chunk = readExactly(input, chunkSize)
            if chunk.isEmpty { break }
            try out.write(contentsOf: try gcmSeal(chunk, key: key, aad: chunkAAD(index)))
            index += 1
            done += chunk.count
            progress(done, Int(total))
            if chunk.count < chunkSize { break }   // final (partial) chunk
        }
    }

    /// Decrypt an entire container back to a plaintext file (disable-migration / export).
    /// Throws `CancellationError` when `isCancelled()` returns true; leaves `outURL`
    /// in place on throw (the caller — writing to a temp — owns cleanup).
    static func decryptWhole(_ url: URL, to outURL: URL, key: SymmetricKey,
                             baseOffset: Int64 = 0,
                             progress: (Int, Int) -> Void = { _, _ in },
                             isCancelled: () -> Bool = { false }) throws {
        let reader = try Reader(url: url, key: key, baseOffset: baseOffset)
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        guard let out = try? FileHandle(forWritingTo: outURL) else { throw Error.corrupt }
        defer { try? out.close() }
        var offset: Int64 = 0
        while offset < reader.originalLength {
            if isCancelled() { throw CancellationError() }
            let n = min(reader.chunkSize, Int(reader.originalLength - offset))
            let plain = try reader.read(offset: offset, length: n)
            guard !plain.isEmpty else { break }
            try out.write(contentsOf: plain)
            offset += Int64(plain.count)
            progress(Int(offset), Int(reader.originalLength))
        }
    }

    // MARK: - Random-access reader

    /// Opens a container for on-demand reads. Decrypts only the chunks a
    /// requested byte-range covers.
    final class Reader {
        let chunkSize: Int
        let originalLength: Int64
        let originalUTI: String
        private let thumbnailData: Data?
        private let handle: FileHandle
        private let key: SymmetricKey
        private let dataStart: Int64

        /// `baseOffset` is where this sealed payload STARTS inside `url`.
        ///
        /// Zero for a standalone file. Non-zero when the payload is an entry
        /// inside a `.seal` container: entries are stored uncompressed and
        /// contiguous, so the reader's existing absolute seeks simply shift by
        /// the entry's offset — which is what lets a multi-gigabyte recording
        /// stream straight out of the container with no extraction.
        init(url: URL, key: SymmetricKey, baseOffset: Int64 = 0) throws {
            self.key = key
            let h = try FileHandle(forReadingFrom: url)
            self.handle = h
            if baseOffset > 0 { try h.seek(toOffset: UInt64(baseOffset)) }
            let prefix = readExactly(h, 9)
            guard prefix.count == 9 else { throw Error.notSealed }
            let bytes = [UInt8](prefix)
            guard Data(bytes[0..<4]) == SealedChunkFile.magic else { throw Error.notSealed }
            guard bytes[4] == SealedChunkFile.version else { throw Error.unsupportedVersion(bytes[4]) }
            let headerLen = Int(bytes[5]) | Int(bytes[6]) << 8 | Int(bytes[7]) << 16 | Int(bytes[8]) << 24
            let sealedHeader = readExactly(h, headerLen)
            guard sealedHeader.count == headerLen else { throw Error.corrupt }
            let headerJSON = try gcmOpen(sealedHeader, key: key, aad: headerAAD)
            let header = try JSONDecoder().decode(Header.self, from: headerJSON)
            self.chunkSize = header.chunkSize
            self.originalLength = header.originalLength
            self.originalUTI = header.originalUTI
            self.thumbnailData = header.thumbnailBase64.flatMap { Data(base64Encoded: $0) }
            self.dataStart = baseOffset + Int64(9 + headerLen)
        }

        deinit { try? handle.close() }

        func thumbnail() -> Data? { thumbnailData }

        /// Plaintext bytes in `[offset, offset+length)`, clamped to the file.
        func read(offset: Int64, length: Int) throws -> Data {
            let end = min(offset + Int64(max(0, length)), originalLength)
            guard offset >= 0, offset < originalLength, end > offset else { return Data() }
            let cs = Int64(chunkSize)
            let firstChunk = Int(offset / cs)
            let lastChunk = Int((end - 1) / cs)
            var result = Data()
            for i in firstChunk...lastChunk {
                let plain = try decryptChunk(i)
                let chunkStart = Int64(i) * cs
                let lo = Int(max(offset, chunkStart) - chunkStart)
                let hi = Int(min(end, chunkStart + Int64(plain.count)) - chunkStart)
                guard lo <= hi, hi <= plain.count else { throw Error.corrupt }
                result.append(plain.subdata(in: lo..<hi))
            }
            return result
        }

        private func decryptChunk(_ index: Int) throws -> Data {
            try handle.seek(toOffset: UInt64(dataStart + Int64(index) * Int64(chunkSize + overhead)))
            // Clamp to what this chunk actually holds. Reading a FULL chunk's
            // worth relied on EOF to stop short on the last one — true for a
            // standalone `.sealrec`, false inside a container, where the next
            // entry's bytes follow immediately and would be appended to the
            // ciphertext, failing authentication.
            let plainInChunk = Int(min(Int64(chunkSize),
                                       max(0, originalLength - Int64(index) * Int64(chunkSize))))
            let ct = readExactly(handle, plainInChunk + overhead)
            guard !ct.isEmpty else { throw Error.corrupt }
            return try gcmOpen(ct, key: key, aad: chunkAAD(index))
        }
    }

    // MARK: - Helpers

    private static let headerAAD = Data("header".utf8)
    private static func chunkAAD(_ index: Int) -> Data {
        var le = UInt64(index).littleEndian
        return withUnsafeBytes(of: &le) { Data($0) }
    }
    private static func uint32LE(_ v: UInt32) -> Data {
        Data([UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)])
    }
    private static func gcmSeal(_ pt: Data, key: SymmetricKey, aad: Data) throws -> Data {
        let box = try AES.GCM.seal(pt, using: key, authenticating: aad)
        guard let combined = box.combined else { throw Error.corrupt }
        return combined
    }
    private static func gcmOpen(_ ct: Data, key: SymmetricKey, aad: Data) throws -> Data {
        try AES.GCM.open(try AES.GCM.SealedBox(combined: ct), using: key, authenticating: aad)
    }
}

/// Read exactly `count` bytes (or until EOF), tolerating short `FileHandle`
/// reads so chunk boundaries stay fixed. Free function — used by both the
/// encoder and the reader.
private func readExactly(_ handle: FileHandle, _ count: Int) -> Data {
    var buffer = Data()
    buffer.reserveCapacity(count)
    while buffer.count < count {
        guard let part = try? handle.read(upToCount: count - buffer.count), !part.isEmpty else { break }
        buffer.append(part)
    }
    return buffer
}
