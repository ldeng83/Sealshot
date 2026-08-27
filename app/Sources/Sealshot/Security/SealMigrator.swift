import Foundation
import CryptoKit
import os.log

private let log = OSLog(subsystem: "com.seal-shot.sealshot", category: "migrator")

/// Converts a whole library between plaintext (≤v4) and locked (v5)
/// packages. Per-package atomicity: transform into a temp sibling, then
/// atomic replace. Idempotent — already-converted packages are skipped, so
/// "resume after crash" is simply "run it again" (this is the journal).
/// File mtimes are preserved: the index keys freshness off mtime and the
/// Library sorts locked packages by it.
enum SealMigrator {
    /// Some packages could not be converted; the rest were. Each failed
    /// package is individually intact (old format). Rerunning after the
    /// cause is fixed converts only the stragglers (idempotent).
    enum Error: Swift.Error {
        case migrationIncomplete(failed: [URL], converted: Int)
    }

    /// A video package's streaming payload entry (`VideoSealPackageIO`'s
    /// layout). It is SealedChunkFile-encrypted — NOT a SealedBlob — and can
    /// be gigabytes, so both migration directions must stream it through a
    /// temp file instead of loading it like the other (small) entries.
    /// Treating it as a blob is exactly the bug that quarantined every video
    /// when encryption was turned off.
    static let videoPayloadEntry = "payload"

    /// Encrypt every plaintext .seal under `folder` (recursing into
    /// Deleted/). Returns how many were converted this run.
    @discardableResult
    static func encryptAll(in folder: URL, publicKey: IdentityPublicKey,
                           generation: KeyGeneration,
                           progress: (Int, Int) -> Void) async throws -> Int {
        let fm = FileManager.default
        let targets = sealPackages(in: folder).filter { !SealPackageCrypter.isLocked($0) }
        var done = 0
        var failed: [URL] = []
        for url in targets {
            var payloadTemp: URL?
            defer { if let payloadTemp { try? fm.removeItem(at: payloadTemp) } }
            do {
                let entries = try rawEntries(at: url, excluding: [Self.videoPayloadEntry])
                let (sealed, cek) = try SealPackageCrypter.sealEntries(
                    entries, publicKey: publicKey, generation: generation)
                // Video payload: stream-encrypt into the chunked container the
                // player expects (same CEK as the blob entries, like the
                // recorder's own encrypted-write path).
                var moving: [String: URL] = [:]
                let (payloadURL, payloadScratch) = try Self.payloadFile(in: url)
                defer { if let payloadScratch { try? fm.removeItem(at: payloadScratch) } }
                if let payloadURL {
                    let temp = url.deletingLastPathComponent().appendingPathComponent(
                        ".payload-\(UUID().uuidString).sealmig")
                    try SealedChunkFile.encrypt(
                        plaintextURL: payloadURL, to: temp, key: cek,
                        originalUTI: plaintextPayloadUTI(at: payloadURL))
                    payloadTemp = temp
                    moving[Self.videoPayloadEntry] = temp
                }
                try replacePackage(at: url, with: sealed, movingFiles: moving)
                payloadTemp = nil   // consumed by replacePackage
                done += 1
                progress(done, targets.count)
            } catch {
                os_log("encryptAll failed for %{public}@ — %{public}@",
                       log: log, type: .error, url.lastPathComponent, "\(error)")
                failed.append(url)
            }
            await Task.yield()
        }
        guard failed.isEmpty else {
            throw Error.migrationIncomplete(failed: failed, converted: done)
        }
        return done
    }

    /// UTI for a plaintext movie payload, from its ISO-BMFF `ftyp` brand —
    /// the recorder writes QuickTime by default; imports may be MP4.
    private static func plaintextPayloadUTI(at url: URL) -> String {
        VideoSealPackageIO.ftypMajorBrand(at: url) == "qt  "
            ? "com.apple.quicktime-movie" : "public.mpeg-4"
    }

    /// What a decrypt pass accomplished: how many packages it decrypted, and the
    /// ones it could NOT (their generation's key isn't reachable). Total — it
    /// never throws, so disabling encryption can always make progress.
    struct DecryptOutcome: Equatable { let decrypted: Int; let unrecoverable: [URL] }

    /// Decrypt every locked .seal under `folder`, resolving each package's key by
    /// its stamped generation via `keyFor`. Packages whose generation can't be
    /// resolved (or that fail to open) are returned in `unrecoverable` instead of
    /// aborting the pass — the caller quarantines them.
    @discardableResult
    static func decryptAll(in folder: URL,
                           keyFor: (UUID) -> IdentityKey?,
                           progress: (Int, Int) -> Void) async -> DecryptOutcome {
        let targets = sealPackages(in: folder).filter { SealPackageCrypter.isLocked($0) }
        var done = 0
        var unrecoverable: [URL] = []
        for url in targets {
            if decryptOne(at: url, keyFor: keyFor) {
                done += 1
                progress(done, targets.count)
            } else {
                unrecoverable.append(url)
            }
            await Task.yield()
        }
        return DecryptOutcome(decrypted: done, unrecoverable: unrecoverable)
    }

    /// What a re-key pass accomplished: how many package lids it rewrapped, and
    /// which it couldn't (their CEK didn't unwrap with the old identity).
    struct RekeyOutcome: Equatable { let rekeyed: Int; let failed: [URL] }

    /// Rewrite each locked package's lock.json CEK from `old` to `newPublic`+`gen`.
    /// ONLY the lid changes — the sealed entry bytes are untouched (the content key
    /// is unchanged). Total: a package that won't unwrap with `old` is left as-is
    /// and reported in `failed`.
    @discardableResult
    static func rekeyAll(in folder: URL, old: IdentityKey,
                         new newPublic: IdentityPublicKey,
                         generation: KeyGeneration) async -> RekeyOutcome {
        let targets = sealPackages(in: folder).filter { SealPackageCrypter.isLocked($0) }
        var rekeyed = 0
        var failed: [URL] = []
        for url in targets {
            // A rekey rewrites ONLY the lid. `lock.json` is a tail entry, so
            // this stays a few kilobytes of I/O even on a 2 GB recording.
            let writeLock: (Data) -> Bool = { encoded in
                if SealContainer.isContainer(url) {
                    return (try? SealContainer.rewritingTail(
                        [LockHeader.filename: encoded], in: url)) != nil
                }
                return (try? encoded.write(
                    to: url.appendingPathComponent(LockHeader.filename), options: .atomic)) != nil
            }
            if let data = sealEntryData(LockHeader.filename, at: url),
               let header = try? JSONDecoder().decode(LockHeader.self, from: data),
               let cek = try? SealPackageCrypter.unwrapCEK(header, identity: old),
               let capsule = try? newPublic.wrap(contentKey: cek, generation: generation),
               let encoded = try? JSONEncoder().encode(LockHeader(capsule: capsule)),
               writeLock(encoded) {
                rekeyed += 1
            } else {
                failed.append(url)
            }
            await Task.yield()
        }
        return RekeyOutcome(rekeyed: rekeyed, failed: failed)
    }

    /// Decrypt a single locked package in place. Returns false (never throws) when
    /// the header is unreadable, the generation's key isn't reachable, or opening
    /// fails — i.e. the package is unrecoverable on this Mac.
    private static func decryptOne(at url: URL, keyFor: (UUID) -> IdentityKey?) -> Bool {
        let fm = FileManager.default
        var payloadTemp: URL?
        defer { if let payloadTemp { try? fm.removeItem(at: payloadTemp) } }
        do {
            var entries = try rawEntries(at: url, excluding: [Self.videoPayloadEntry])
            guard let headerData = entries.removeValue(forKey: LockHeader.filename),
                  let header = try? JSONDecoder().decode(LockHeader.self, from: headerData),
                  let identity = keyFor(header.capsule.generationID)
            else { return false }
            let cek = try SealPackageCrypter.unwrapCEK(header, identity: identity)
            var opened: [String: Data] = [:]
            for (name, data) in entries {
                opened[name] = try SealedBlob.open(data, with: cek)
            }
            // Video payload: stream-decrypt the chunked container back to the
            // raw movie file (never through RAM).
            var moving: [String: URL] = [:]
            let (payloadURL, payloadScratch) = try Self.payloadFile(in: url)
            defer { if let payloadScratch { try? fm.removeItem(at: payloadScratch) } }
            if let payloadURL {
                let temp = url.deletingLastPathComponent().appendingPathComponent(
                    ".payload-\(UUID().uuidString).sealmig")
                try SealedChunkFile.decryptWhole(payloadURL, to: temp, key: cek)
                payloadTemp = temp
                moving[Self.videoPayloadEntry] = temp
            }
            try replacePackage(at: url, with: opened, movingFiles: moving)
            payloadTemp = nil   // consumed by replacePackage
            return true
        } catch {
            os_log("decryptAll could not decrypt %{public}@ — %{public}@",
                   log: log, type: .error, url.lastPathComponent, "\(error)")
            return false
        }
    }

    // MARK: helpers

    /// .seal directories directly in `folder` and `folder/Deleted`.
    private static func sealPackages(in folder: URL) -> [URL] {
        let fm = FileManager.default
        func packages(in dir: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "seal" }
        }
        return packages(in: folder) + packages(in: folder.appendingPathComponent("Deleted"))
    }

    /// The video payload as a real FILE, which is what `SealedChunkFile`
    /// needs to re-key it.
    ///
    /// Inside a container the payload is an entry, so it is streamed out to a
    /// scratch file first; the second return value is that file, for the
    /// caller to delete. A legacy directory package already has it as a file
    /// and gets nil.
    private static func payloadFile(in url: URL) throws -> (URL?, URL?) {
        if SealContainer.isContainer(url) {
            let reader = try SealContainer.Reader(url: url)
            guard reader.entry(videoPayloadEntry) != nil else { return (nil, nil) }
            let scratch = url.deletingLastPathComponent()
                .appendingPathComponent(".payload-src-\(UUID().uuidString).sealmig")
            try reader.extract(videoPayloadEntry, to: scratch)
            return (scratch, scratch)
        }
        let direct = url.appendingPathComponent(videoPayloadEntry)
        return (FileManager.default.fileExists(atPath: direct.path) ? direct : nil, nil)
    }

    /// Load a package's entries into memory, skipping `excluding` names (the
    /// streaming video payload must never be loaded as Data — it can be GBs).
    private static func rawEntries(at url: URL,
                                   excluding: Set<String> = []) throws -> [String: Data] {
        let fm = FileManager.default
        var out: [String: Data] = [:]
        if SealContainer.isContainer(url) {
            let reader = try SealContainer.Reader(url: url)
            for entry in reader.entries where !excluding.contains(entry.name) {
                out[entry.name] = try reader.data(entry.name)
            }
            return out
        }
        for file in try fm.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isRegularFileKey]) {
            if excluding.contains(file.lastPathComponent) { continue }
            // Fix 3 (M-1): reject non-regular files (directories, symlinks) inside a package;
            // caller's per-package catch will skip this package and report it in failed[].
            let rsrc = try file.resourceValues(forKeys: [.isRegularFileKey])
            guard rsrc.isRegularFile == true else {
                throw NSError(domain: "SealMigrator", code: 1,
                              userInfo: [NSLocalizedDescriptionKey:
                                "non-regular file inside package: \(file.lastPathComponent)"])
            }
            out[file.lastPathComponent] = try Data(contentsOf: file)
        }
        return out
    }

    /// Write `entries` as a temp package next to `url`, then atomically
    /// replace, restoring the original directory mtime. `movingFiles` are
    /// large streamed entries (the video payload) moved — not copied — into
    /// the temp package by name; they are consumed on success.
    private static func replacePackage(at url: URL, with entries: [String: Data],
                                       movingFiles: [String: URL] = [:]) throws {
        let fm = FileManager.default
        let mtime = try fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        // com.seal-shot.* xattrs carry the trash/restore timestamps
        // (SealDeleter). replaceItemAt swaps in a FRESH directory, which
        // silently dropped them — resetting every trashed item's retention
        // clock whenever encryption was toggled. Snapshot before, re-apply
        // after (like the mtime).
        let preservedXattrs = sealshotXattrs(at: url.path)
        let parent = url.deletingLastPathComponent()
        let name = url.lastPathComponent

        // Fix 1 (I-1): UUID-suffixed temp so a leftover from a prior crash can never be reused.
        let temp = parent.appendingPathComponent(
            ".\(name).\(UUID().uuidString).sealmig", isDirectory: false)

        // Sweep any stale temps from prior crashed runs (same base name, any UUID suffix).
        let siblings = (try? fm.contentsOfDirectory(
            at: parent, includingPropertiesForKeys: nil)) ?? []
        for stale in siblings
            where stale.lastPathComponent.hasPrefix(".\(name).")
               && stale.lastPathComponent.hasSuffix(".sealmig") {
            try? fm.removeItem(at: stale)
        }

        // A container: one file, written through the streaming API so a
        // recording's payload is never loaded whole to re-key it.
        var sources: [(name: String, source: SealContainer.Source)] =
            entries.map { ($0.key, .data($0.value)) }
        for (entryName, file) in movingFiles { sources.append((entryName, .file(file))) }
        try SealContainer.write(sources: sources, to: temp)
        for (_, file) in movingFiles { try? fm.removeItem(at: file) }

        // Fix 4 (M-2): replaceItemAt may legally return a URL that differs from the original
        // (e.g. on a case-insensitive volume), but here the package name is fixed and mtime is
        // restored via the original path, so the return value is intentionally discarded.
        // A legacy DIRECTORY package cannot be replaced by a file in place —
        // remove it first. Only ever reached mid-conversion, with the temp
        // already written and holding every entry.
        var wasDirectory: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &wasDirectory), wasDirectory.boolValue {
            try fm.removeItem(at: url)
            try fm.moveItem(at: temp, to: url)
        } else {
            _ = try fm.replaceItemAt(url, withItemAt: temp)
        }
        applyXattrs(preservedXattrs, at: url.path)
        if let mtime {
            try? fm.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        }
    }

    /// All `com.seal-shot.*` extended attributes on `path` (raw bytes).
    private static func sealshotXattrs(at path: String) -> [String: Data] {
        let listSize = listxattr(path, nil, 0, 0)
        guard listSize > 0 else { return [:] }
        var nameBuf = [CChar](repeating: 0, count: listSize)
        guard listxattr(path, &nameBuf, listSize, 0) == listSize else { return [:] }
        var out: [String: Data] = [:]
        var start = 0
        for i in 0..<listSize where nameBuf[i] == 0 {
            let name = String(cString: Array(nameBuf[start...i]))
            start = i + 1
            guard name.hasPrefix("com.seal-shot.") else { continue }
            let size = getxattr(path, name, nil, 0, 0, 0)
            guard size > 0 else { continue }
            var buf = [UInt8](repeating: 0, count: size)
            guard getxattr(path, name, &buf, size, 0, 0) == size else { continue }
            out[name] = Data(buf)
        }
        return out
    }

    private static func applyXattrs(_ attrs: [String: Data], at path: String) {
        for (name, data) in attrs {
            _ = data.withUnsafeBytes { setxattr(path, name, $0.baseAddress, data.count, 0, 0) }
        }
    }
}
