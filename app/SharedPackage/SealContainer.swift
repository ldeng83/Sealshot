import Foundation

/// The single-file `.seal` container.
///
/// A capture used to be a directory package. macOS reserves thumbnailing for
/// types conforming to `com.apple.package` — its own `PackageExtension` answers
/// and no third party is ever consulted — so a package could never show its
/// picture in Finder. A flat file can. (This is exactly how Snagit's `.snagx`
/// gets Finder previews: a ZIP declared as image data, not a bundle.)
///
/// ZIP, with three deliberate constraints:
///
/// 1. **Every entry is STORED, never deflated.** PNG and H.264 payloads are
///    already compressed, so deflate would burn CPU for nothing — and, more
///    importantly, stored bytes live contiguously at a known offset, which is
///    what lets a multi-gigabyte recording keep streaming out of the container
///    instead of being extracted first. `SealedChunkFile.Reader` already seeks
///    by absolute offset; inside a container it simply gains a base.
///
/// 2. **The manifest is written LAST**, immediately before the central
///    directory. Metadata changes constantly — a tag, a title, an OCR pass —
///    and rewriting a 2 GB archive for a one-line edit would be unusable.
///    Because the manifest sits at the tail, `rewritingManifest` truncates
///    there and writes the manifest plus a fresh directory: cost proportional
///    to the metadata, not to the payload.
///
/// 3. **No compression means no dependency.** A stored-only reader and writer
///    is a few hundred lines under our own control, which beats pulling a
///    third-party archive library into the process that holds people's
///    encrypted captures.
///
/// Encryption is unchanged and orthogonal: entries arrive already sealed, and
/// `lock.json` is simply one of them. The container knows nothing about keys.
enum SealContainer {
    static let manifestEntry = "manifest.json"
    static let derivedEntry = "derived.json"

    /// Entries kept at the END of the archive, in this order, so either can be
    /// rewritten without touching a payload byte. Both change independently of
    /// the capture itself: the manifest on every tag/title/OCR edit, the
    /// derived sidecar whenever Live Text or extraction caches a result.
    /// `lock.json` is here for the same reason: a key rotation rewraps the
    /// content key and touches nothing else, so re-keying a library of
    /// multi-gigabyte recordings must not re-encode a single payload byte.
    static let lockEntry = "lock.json"
    static let tailEntries = [lockEntry, derivedEntry, manifestEntry]

    enum ContainerError: Error {
        case notAContainer
        case corruptDirectory
        case entryMissing(String)
        case entryCompressed(String)
        case notATailEntry(String)
        case writeFailed(underlying: Error)
    }

    /// One stored entry: where its bytes are and how many.
    struct Entry: Equatable {
        let name: String
        /// Absolute offset of the entry's DATA (past its local header).
        let dataOffset: UInt64
        let size: UInt64
        let crc32: UInt32
    }

    // MARK: Detecting the format

    /// Whether `url` is a container rather than the legacy directory package.
    /// Cheap: reads the four-byte signature, nothing else.
    static func isContainer(_ url: URL, fileManager: FileManager = .default) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let magic = (try? handle.read(upToCount: 4)) ?? Data()
        return magic == Data([0x50, 0x4B, 0x03, 0x04])
    }

    // MARK: Writing

    /// An entry's bytes, either in memory or still on disk.
    ///
    /// File-backed entries exist for one reason: a recording's payload is
    /// gigabytes, and loading it into `Data` to rewrite a package — which the
    /// encryption toggle does to every capture — would be a memory spike
    /// proportional to the video. Streamed in fixed chunks instead.
    enum Source {
        case data(Data)
        case file(URL)

        var byteCount: UInt64 {
            switch self {
            case .data(let d): return UInt64(d.count)
            case .file(let url):
                return (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]
                        as? UInt64) ?? 0
            }
        }
    }

    /// Streaming write: same layout as `write(entries:to:)`, but file-backed
    /// entries never land in memory whole.
    static func write(sources: [(name: String, source: Source)], to url: URL,
                      fileManager: FileManager = .default) throws {
        let ordered = sources.filter { !tailEntries.contains($0.name) }
            + tailEntries.compactMap { name in sources.first { $0.name == name } }
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        fileManager.createFile(atPath: temp.path, contents: nil)
        do {
            let out = try FileHandle(forWritingTo: temp)
            var headers: [(name: String, size: UInt64, crc: UInt32, offset: UInt64)] = []
            var offset: UInt64 = 0
            for entry in ordered {
                switch entry.source {
                case .data(let data):
                    let header = localHeader(name: entry.name, data: data)
                    try out.write(contentsOf: header)
                    try out.write(contentsOf: data)
                    headers.append((entry.name, UInt64(data.count), crc32(data), offset))
                    offset += UInt64(header.count) + UInt64(data.count)
                case .file(let source):
                    // Two passes: the local header must carry the CRC and size
                    // BEFORE the bytes (no data descriptors — they would break
                    // the "seek straight to a payload" property this whole
                    // format exists for).
                    let (crc, size) = try crc32AndSize(ofFileAt: source)
                    let header = localHeader(name: entry.name, size: size, crc: crc)
                    try out.write(contentsOf: header)
                    try streamFile(at: source, into: out)
                    headers.append((entry.name, size, crc, offset))
                    offset += UInt64(header.count) + size
                }
            }
            try out.write(contentsOf: centralDirectory(for: headers, startingAt: offset))
            try out.close()
            if fileManager.fileExists(atPath: url.path) {
                _ = try fileManager.replaceItemAt(url, withItemAt: temp)
            } else {
                try fileManager.moveItem(at: temp, to: url)
            }
        } catch {
            try? fileManager.removeItem(at: temp)
            throw ContainerError.writeFailed(underlying: error)
        }
    }

    private static let streamChunk = 4 * 1024 * 1024

    private static func crc32AndSize(ofFileAt url: URL) throws -> (UInt32, UInt64) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var c: UInt32 = 0xFFFF_FFFF
        var total: UInt64 = 0
        while let chunk = try handle.read(upToCount: streamChunk), !chunk.isEmpty {
            for byte in chunk { c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
            total += UInt64(chunk.count)
        }
        return (c ^ 0xFFFF_FFFF, total)
    }

    private static func streamFile(at url: URL, into out: FileHandle) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: streamChunk), !chunk.isEmpty {
            try out.write(contentsOf: chunk)
        }
    }

    /// Write `entries` as a container at `url`, atomically.
    ///
    /// Order is the caller's, except that the manifest is forced last so tail
    /// rewrites stay cheap. Written to a sibling temp file and moved into
    /// place: a half-written capture must never replace a whole one.
    static func write(entries: [(name: String, data: Data)], to url: URL,
                      fileManager: FileManager = .default) throws {
        let ordered = entries.filter { !tailEntries.contains($0.name) }
            + tailEntries.compactMap { name in entries.first { $0.name == name } }
        let archive = encode(ordered)
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try archive.write(to: temp, options: .atomic)
            if fileManager.fileExists(atPath: url.path) {
                _ = try fileManager.replaceItemAt(url, withItemAt: temp)
            } else {
                try fileManager.moveItem(at: temp, to: url)
            }
        } catch {
            try? fileManager.removeItem(at: temp)
            throw ContainerError.writeFailed(underlying: error)
        }
    }

    /// Replace one or more TAIL entries, leaving every payload byte untouched.
    ///
    /// The whole reason those entries go last: this keeps every payload
    /// exactly where it is and rewrites only from the first tail entry
    /// onward. Editing a tag on a 2 GB recording costs a few kilobytes of
    /// I/O rather than a full re-encode of the archive.
    ///
    /// `updates` may add a tail entry that was not there before (a first Live
    /// Text pass writing `derived.json`), replace one, or — with a nil value —
    /// remove it. Non-tail names are rejected: rewriting one of those in place
    /// would corrupt every offset after it.
    static func rewritingTail(_ updates: [String: Data?], in url: URL) throws {
        for name in updates.keys where !tailEntries.contains(name) {
            throw ContainerError.notATailEntry(name)
        }
        let reader = try Reader(url: url)
        var kept: [(name: String, data: Data)] = []
        // Everything before the tail stays byte-identical and is never read
        // back into memory — only its directory record is rebuilt.
        var preserved: [(name: String, size: UInt64, crc: UInt32, offset: UInt64)] = []
        var truncateAt = try FileHandle(forReadingFrom: url).seekToEnd()

        for entry in reader.entries where !tailEntries.contains(entry.name) {
            guard let offset = reader.localHeaderOffset(of: entry.name) else {
                throw ContainerError.corruptDirectory
            }
            preserved.append((entry.name, entry.size, entry.crc32, offset))
        }
        // The tail begins at the first tail entry present, or at the end of
        // the last payload when there is none yet.
        let tailOffsets = reader.entries
            .filter { tailEntries.contains($0.name) }
            .compactMap { reader.localHeaderOffset(of: $0.name) }
        if let first = tailOffsets.min() {
            truncateAt = first
        } else if let lastPayload = preserved.map({ $0.offset }).max(),
                  let entry = reader.entries.first(where: {
                      reader.localHeaderOffset(of: $0.name) == lastPayload
                  }) {
            truncateAt = entry.dataOffset + entry.size
        }

        // Carry forward whichever tail entries this call is not replacing.
        for name in tailEntries {
            if updates.keys.contains(name) {
                if let data = updates[name] ?? nil { kept.append((name, data)) }
            } else if reader.entry(name) != nil {
                kept.append((name, try reader.data(name)))
            }
        }

        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: truncateAt)
        try handle.seek(toOffset: truncateAt)

        var tail = Data()
        var headers = preserved
        for entry in kept {
            headers.append((entry.name, UInt64(entry.data.count), crc32(entry.data),
                            truncateAt + UInt64(tail.count)))
            tail.append(localHeader(name: entry.name, data: entry.data))
            tail.append(entry.data)
        }
        tail.append(centralDirectory(for: headers, startingAt: truncateAt + UInt64(tail.count)))
        try handle.write(contentsOf: tail)
    }

    /// Convenience for the commonest tail edit.
    static func rewritingManifest(_ manifest: Data, in url: URL) throws {
        try rewritingTail([manifestEntry: manifest], in: url)
    }

    // MARK: Reading

    /// Random access over a container. Holds the directory, not the payloads —
    /// a recording's bytes are read by range, never loaded whole.
    struct Reader {
        let url: URL
        let entries: [Entry]
        private let headerOffsets: [String: UInt64]

        init(url: URL) throws {
            guard SealContainer.isContainer(url) else { throw ContainerError.notAContainer }
            self.url = url
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let size = try handle.seekToEnd()
            // The end-of-directory record lives in the last 64KB (we write no
            // comment, so in practice the last 22 bytes — scan anyway).
            let tailSize = UInt64(min(size, 66_000))
            try handle.seek(toOffset: size - tailSize)
            let tail = (try handle.read(upToCount: Int(tailSize))) ?? Data()
            guard let eocd = SealContainer.findEOCD(in: tail) else {
                throw ContainerError.corruptDirectory
            }
            let count = Int(tail.u16(at: eocd + 10))
            let dirOffset = UInt64(tail.u32(at: eocd + 16))
            try handle.seek(toOffset: dirOffset)
            let dirSize = Int(tail.u32(at: eocd + 12))
            let directory = (try handle.read(upToCount: dirSize)) ?? Data()

            var parsed: [Entry] = []
            var offsets: [String: UInt64] = [:]
            var cursor = 0
            for _ in 0..<count {
                guard cursor + 46 <= directory.count,
                      directory.u32(at: cursor) == 0x0201_4b50 else {
                    throw ContainerError.corruptDirectory
                }
                let method = directory.u16(at: cursor + 10)
                let crc = directory.u32(at: cursor + 16)
                let compressed = UInt64(directory.u32(at: cursor + 20))
                let uncompressed = UInt64(directory.u32(at: cursor + 24))
                let nameLength = Int(directory.u16(at: cursor + 28))
                let extraLength = Int(directory.u16(at: cursor + 30))
                let commentLength = Int(directory.u16(at: cursor + 32))
                let headerOffset = UInt64(directory.u32(at: cursor + 42))
                let nameStart = cursor + 46
                guard nameStart + nameLength <= directory.count else {
                    throw ContainerError.corruptDirectory
                }
                let name = String(decoding: directory[nameStart..<nameStart + nameLength],
                                  as: UTF8.self)
                guard method == 0 else { throw ContainerError.entryCompressed(name) }
                // Data begins past the LOCAL header, whose name/extra lengths
                // may differ from the central copy's — read them there.
                try handle.seek(toOffset: headerOffset)
                let local = (try handle.read(upToCount: 30)) ?? Data()
                guard local.count == 30, local.u32(at: 0) == 0x0403_4b50 else {
                    throw ContainerError.corruptDirectory
                }
                let localName = Int(local.u16(at: 26))
                let localExtra = Int(local.u16(at: 28))
                parsed.append(Entry(name: name,
                                    dataOffset: headerOffset + 30 + UInt64(localName + localExtra),
                                    size: compressed == 0 ? uncompressed : compressed,
                                    crc32: crc))
                offsets[name] = headerOffset
                cursor = nameStart + nameLength + extraLength + commentLength
            }
            self.entries = parsed
            self.headerOffsets = offsets
        }

        func entry(_ name: String) -> Entry? { entries.first { $0.name == name } }
        func localHeaderOffset(of name: String) -> UInt64? { headerOffsets[name] }

        /// An entry's bytes. For payloads that belong in a stream (a
        /// recording), use `entry(_:)` and read the range instead.
        func data(_ name: String) throws -> Data {
            guard let entry = entry(name) else { throw ContainerError.entryMissing(name) }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: entry.dataOffset)
            return (try handle.read(upToCount: Int(entry.size))) ?? Data()
        }

        /// Stream one entry out to a standalone file, without loading it.
        /// The encryption toggle needs a recording's payload as a real file to
        /// re-key it, and that payload is gigabytes.
        func extract(_ name: String, to destination: URL) throws {
            guard let entry = entry(name) else { throw ContainerError.entryMissing(name) }
            FileManager.default.createFile(atPath: destination.path, contents: nil)
            let input = try FileHandle(forReadingFrom: url)
            let output = try FileHandle(forWritingTo: destination)
            defer { try? input.close(); try? output.close() }
            try input.seek(toOffset: entry.dataOffset)
            var remaining = entry.size
            while remaining > 0 {
                let want = Int(min(remaining, UInt64(4 * 1024 * 1024)))
                guard let chunk = try input.read(upToCount: want), !chunk.isEmpty else { break }
                try output.write(contentsOf: chunk)
                remaining -= UInt64(chunk.count)
            }
        }

        /// Every entry as a dictionary — the shape the old directory reader
        /// handed back, so callers port across unchanged.
        func allEntries() throws -> [String: Data] {
            var result: [String: Data] = [:]
            for entry in entries { result[entry.name] = try data(entry.name) }
            return result
        }
    }

    // MARK: ZIP encoding (stored only)

    private static func encode(_ entries: [(name: String, data: Data)]) -> Data {
        var archive = Data()
        var headers: [(name: String, size: UInt64, crc: UInt32, offset: UInt64)] = []
        for entry in entries {
            let offset = UInt64(archive.count)
            archive.append(localHeader(name: entry.name, data: entry.data))
            archive.append(entry.data)
            headers.append((entry.name, UInt64(entry.data.count), crc32(entry.data), offset))
        }
        archive.append(centralDirectory(for: headers, startingAt: UInt64(archive.count)))
        return archive
    }

    private static func localHeader(name: String, data: Data) -> Data {
        localHeader(name: name, size: UInt64(data.count), crc: crc32(data))
    }

    private static func localHeader(name: String, size: UInt64, crc: UInt32) -> Data {
        var header = Data()
        header.appendU32(0x0403_4b50)        // local file header
        header.appendU16(20)                 // version needed
        header.appendU16(0)                  // flags
        header.appendU16(0)                  // method: stored
        header.appendU16(0); header.appendU16(0)   // fixed mod time/date
        header.appendU32(crc)
        header.appendU32(UInt32(size))       // compressed == uncompressed
        header.appendU32(UInt32(size))
        let nameBytes = Array(name.utf8)
        header.appendU16(UInt16(nameBytes.count))
        header.appendU16(0)                  // extra length
        header.append(contentsOf: nameBytes)
        return header
    }

    private static func centralDirectory(
        for headers: [(name: String, size: UInt64, crc: UInt32, offset: UInt64)],
        startingAt start: UInt64
    ) -> Data {
        var directory = Data()
        for header in headers {
            directory.appendU32(0x0201_4b50)   // central file header
            directory.appendU16(20)            // version made by
            directory.appendU16(20)            // version needed
            directory.appendU16(0)             // flags
            directory.appendU16(0)             // method: stored
            directory.appendU16(0); directory.appendU16(0)
            directory.appendU32(header.crc)
            directory.appendU32(UInt32(header.size))
            directory.appendU32(UInt32(header.size))
            let nameBytes = Array(header.name.utf8)
            directory.appendU16(UInt16(nameBytes.count))
            directory.appendU16(0)             // extra
            directory.appendU16(0)             // comment
            directory.appendU16(0)             // disk number
            directory.appendU16(0)             // internal attrs
            directory.appendU32(0)             // external attrs
            directory.appendU32(UInt32(header.offset))
            directory.append(contentsOf: nameBytes)
        }
        let size = UInt32(directory.count)
        directory.appendU32(0x0605_4b50)       // end of central directory
        directory.appendU16(0); directory.appendU16(0)
        directory.appendU16(UInt16(headers.count))
        directory.appendU16(UInt16(headers.count))
        directory.appendU32(size)
        directory.appendU32(UInt32(start))
        directory.appendU16(0)                 // comment length
        return directory
    }

    private static func findEOCD(in tail: Data) -> Int? {
        guard tail.count >= 22 else { return nil }
        var index = tail.count - 22
        while index >= 0 {
            if tail.u32(at: index) == 0x0605_4b50 { return index }
            index -= 1
        }
        return nil
    }

    // MARK: CRC32

    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) == 1 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in data { c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}

// MARK: - Little-endian helpers

private extension Data {
    mutating func appendU16(_ value: UInt16) {
        append(UInt8(value & 0xFF)); append(UInt8((value >> 8) & 0xFF))
    }
    mutating func appendU32(_ value: UInt32) {
        append(UInt8(value & 0xFF)); append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF)); append(UInt8((value >> 24) & 0xFF))
    }
}

extension Data {
    /// Index-safe little-endian reads. `Data` slices keep their parent's
    /// indices, so every read is relative to `startIndex` — reading a slice
    /// with absolute offsets is a classic way to walk off the end.
    func u16(at offset: Int) -> UInt16 {
        let base = startIndex + offset
        guard base + 1 < endIndex else { return 0 }
        return UInt16(self[base]) | (UInt16(self[base + 1]) << 8)
    }
    func u32(at offset: Int) -> UInt32 {
        let base = startIndex + offset
        guard base + 3 < endIndex else { return 0 }
        return UInt32(self[base]) | (UInt32(self[base + 1]) << 8)
            | (UInt32(self[base + 2]) << 16) | (UInt32(self[base + 3]) << 24)
    }
}
