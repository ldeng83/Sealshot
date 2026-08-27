import Foundation
import Darwin

extension Notification.Name {
    /// Posted after captures are permanently removed from disk (object: [URL]).
    /// The editor listens so an open/playing purged file leaves the canvas.
    static let capturesPermanentlyDeleted = Notification.Name("com.seal-shot.capturesPermanentlyDeleted")
    /// Posted after the Library moves captures into Deleted/ (object: [URL] —
    /// the ORIGINAL pre-move URLs). Same editor reaction as a purge: the file
    /// left the save folder, so it must leave the canvas too.
    static let capturesTrashed = Notification.Name("com.seal-shot.capturesTrashed")
}

/// File-mover for capture delete + restore. Moves a `.seal` (or `.png`)
/// between the save folder and its `Deleted/` subfolder. Handles
/// name conflicts with the smallest-unused-integer suffix (` 2`, ` 3`, …).
///
/// After every move, touches the file's mtime to "now" so the strip's
/// existing mtime-sort puts most-recently-deleted (in Deleted tab) and
/// most-recently-restored (in Recent tab) at position 0. Also writes
/// explicit xattrs (`com.seal-shot.deletedAt` / `restoredAt`) so the
/// timestamps survive any tool that might clobber mtime, and are
/// available for a future "details" UI.
@MainActor
enum SealDeleter {

    nonisolated static let deletedSubfolderName = "Deleted"
    nonisolated static let deletedAtXattr = "com.seal-shot.deletedAt"
    static let restoredAtXattr = "com.seal-shot.restoredAt"
    /// Snapshot of the file's mtime at the moment it was deleted, so that
    /// restore() can put it back at its original position in Recent's
    /// mtime-sorted strip. ISO8601 string.
    static let originalMtimeXattr = "com.seal-shot.originalMtime"
    /// The folder a capture was deleted FROM, relative to the save folder
    /// ("" = the library root, "Scratch" = the unkept-captures waiting room).
    ///
    /// Without this, everything restored to the library root — so deleting a
    /// scratch capture and undoing it silently FILED it, turning "undo a
    /// delete" into "keep", which is a different decision than the user made.
    /// Relative, not absolute: a library that moves or is renamed must not
    /// strand its trash.
    static let originalFolderXattr = "com.seal-shot.originalFolder"

    enum Error: Swift.Error {
        case sourceMissing(URL)
        case moveFailed(URL, to: URL, underlying: Swift.Error)
        case createFolderFailed(URL, underlying: Swift.Error)
    }

    /// Move `url` into `<saveFolder>/Deleted/`. Creates the subfolder on
    /// first call. Returns the URL the file ended up at (basename may be
    /// suffixed if a name conflict was resolved).
    static func delete(url: URL, saveFolder: URL) throws -> URL {
        // Capture the original mtime BEFORE the move so restore() can put
        // the file back at its original position in Recent's sort order.
        let originalMtime = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
            ?? Date()

        let deletedFolder = saveFolder.appendingPathComponent(deletedSubfolderName, isDirectory: true)
        try ensureFolder(deletedFolder)
        let target = uniqueDestination(in: deletedFolder, for: url.lastPathComponent)
        try moveFile(from: url, to: target)
        // Persist the original mtime as ISO8601 in an xattr, then stamp
        // the file's mtime to "now" so the Deleted tab sorts by delete time.
        writeXattr(originalMtimeXattr, value: ISO8601DateFormatter().string(from: originalMtime), at: target)
        writeXattr(originalFolderXattr,
                   value: originFolderName(of: url, saveFolder: saveFolder), at: target)
        stampNow(at: target, xattr: deletedAtXattr)
        return target
    }

    /// Move `url` from `<saveFolder>/Deleted/` back into `<saveFolder>/`.
    /// Returns the URL the file ended up at (basename may be suffixed).
    /// Restores the file's original mtime (from the `originalMtime` xattr
    /// saved at delete time) so the file slots back into its original
    /// position in Recent's mtime-sorted strip. Legacy files (deleted
    /// before the xattr feature shipped) fall back to "now".
    static func restore(url: URL, saveFolder: URL) throws -> URL {
        try restore(url: url, toFolder: originFolder(for: url, saveFolder: saveFolder))
    }

    /// Where a capture was deleted from, as a name relative to the save
    /// folder. Only the subfolders a capture can legitimately live in are
    /// recorded; anything else reads as the root.
    static func originFolderName(of url: URL, saveFolder: URL) -> String {
        let parent = url.deletingLastPathComponent().standardizedFileURL.lastPathComponent
        return parent == ScratchCapture.folderName ? ScratchCapture.folderName : ""
    }

    /// Resolve the recorded origin back to a folder. A trashed item from
    /// before this xattr existed has none, and restores to the save folder —
    /// the previous behaviour, which is the right fallback.
    ///
    /// Deliberately a whitelist rather than a stored path: an xattr is
    /// user-writable, and "restore wherever this file says" is a way to write
    /// outside the library.
    static func originFolder(for url: URL, saveFolder: URL) -> URL {
        guard let name = readTimestampXattr(originalFolderXattr, at: url),
              name == ScratchCapture.folderName else { return saveFolder }
        return ScratchCapture.folder(under: saveFolder)
    }

    /// Move `url` from `<saveFolder>/Deleted/` back into `toFolder`. Captures
    /// restore to the save folder; video recordings restore to `Recordings/`.
    /// Same mtime/xattr handling as `restore(url:saveFolder:)`.
    static func restore(url: URL, toFolder: URL) throws -> URL {
        // Read the saved original-mtime xattr BEFORE the move (the path
        // changes after moveItem).
        let originalMtime: Date? = {
            guard let iso = readTimestampXattr(originalMtimeXattr, at: url) else { return nil }
            return ISO8601DateFormatter().date(from: iso)
        }()

        try ensureFolder(toFolder)
        let target = uniqueDestination(in: toFolder, for: url.lastPathComponent)
        try moveFile(from: url, to: target)

        // Track restore time (metadata only, not used for sort).
        writeXattr(restoredAtXattr, value: ISO8601DateFormatter().string(from: Date()), at: target)

        // Restore the original mtime if we have one; otherwise stamp to
        // "now" as a fallback (legacy files without the xattr).
        if let originalMtime {
            try? FileManager.default.setAttributes(
                [.modificationDate: originalMtime],
                ofItemAtPath: target.path
            )
        } else {
            try? FileManager.default.setAttributes(
                [.modificationDate: Date()],
                ofItemAtPath: target.path
            )
        }
        return target
    }

    /// Permanently remove a file (or `.seal` file package) from disk.
    /// No recovery — caller must have confirmed with the user first.
    /// `FileManager.removeItem(at:)` recursively removes a directory,
    /// so `.seal` packages (which are directories on disk) work the
    /// same as plain `.png` files.
    static func permanentlyDelete(url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    /// Read the ISO8601 string stored at the given xattr (or nil if absent).
    nonisolated static func readTimestampXattr(_ name: String, at url: URL) -> String? {
        let path = url.path
        return name.withCString { namePtr -> String? in
            let size = getxattr(path, namePtr, nil, 0, 0, 0)
            guard size > 0 else { return nil }
            var buffer = [UInt8](repeating: 0, count: size)
            let read = getxattr(path, namePtr, &buffer, size, 0, 0)
            guard read == size else { return nil }
            return String(bytes: buffer, encoding: .utf8)
        }
    }

    // MARK: - Private

    private static func ensureFolder(_ url: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true
            )
        } catch {
            throw Error.createFolderFailed(url, underlying: error)
        }
    }

    private static func moveFile(from: URL, to: URL) throws {
        guard FileManager.default.fileExists(atPath: from.path) else {
            throw Error.sourceMissing(from)
        }
        do {
            try FileManager.default.moveItem(at: from, to: to)
        } catch {
            throw Error.moveFailed(from, to: to, underlying: error)
        }
    }

    /// Set the file's mtime to "now" and write an ISO8601 timestamp xattr.
    /// Both failures are swallowed — the move itself already succeeded;
    /// timestamp stamping is a sort-order + tracking nicety, not load-bearing.
    private static func stampNow(at url: URL, xattr name: String) {
        let now = Date()
        try? FileManager.default.setAttributes(
            [.modificationDate: now],
            ofItemAtPath: url.path
        )
        writeXattr(name, value: ISO8601DateFormatter().string(from: now), at: url)
    }

    /// Write an arbitrary string value to the given xattr. Failures are
    /// swallowed — xattr writes are advisory metadata.
    private static func writeXattr(_ name: String, value: String, at url: URL) {
        value.withCString { valuePtr in
            name.withCString { namePtr in
                _ = setxattr(url.path, namePtr, valuePtr, strlen(valuePtr), 0, 0)
            }
        }
    }

    /// Given a target folder and a desired filename, return a URL whose
    /// basename is unique within that folder. Tries the desired filename
    /// first; on conflict, suffixes the basename with ` 2`, ` 3`, …
    private static func uniqueDestination(in folder: URL, for filename: String) -> URL {
        let candidate = folder.appendingPathComponent(filename)
        if !FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        let nsName = filename as NSString
        let base = nsName.deletingPathExtension
        let ext = nsName.pathExtension
        var n = 2
        while true {
            let suffixed = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            let try_ = folder.appendingPathComponent(suffixed)
            if !FileManager.default.fileExists(atPath: try_.path) {
                return try_
            }
            n += 1
        }
    }
}
