import Foundation

/// Captures that are NOT kept in the Library.
///
/// With "Add captures to Library" off, a capture writes into
/// `<saveFolder>/Scratch/` instead of the save folder itself. The Library is a
/// per-folder projection of the save folder, so a subfolder is invisible to it
/// by construction — the same mechanism that keeps `Deleted/` out. Everything
/// else about the capture is unchanged: it opens in the editor, hits the
/// clipboard per the output setting, and is written through the same package
/// writer, so Enhanced Security encrypts a scratch capture exactly like a
/// library one. A toggle that quietly wrote plaintext would be the opposite of
/// what this app promises.
///
/// Scratch is a waiting room, not a second library: items are purged after
/// `retentionDays`, and the editor offers "Add to Library" as the explicit
/// keep gesture — a rename into the save folder, cheap because Scratch lives
/// on the same volume.
enum ScratchCapture {
    static let folderName = "Scratch"

    /// How long an unkept capture lives. Deliberately a constant rather than a
    /// setting: the number only matters as "long enough to change your mind,
    /// short enough that Scratch never becomes a shadow library".
    static let retentionDays = 7

    static func folder(under saveFolder: URL) -> URL {
        saveFolder.appendingPathComponent(folderName, isDirectory: true)
    }

    /// Whether `url` is a scratch capture — the test the editor menu, the
    /// capture-landed announcement, and Add to Library all share.
    static func isScratch(_ url: URL) -> Bool {
        url.deletingLastPathComponent().lastPathComponent == folderName
    }

    /// Where a capture should be written, given the user's choice.
    static func destination(saveFolder: URL, addToLibrary: Bool) -> URL {
        addToLibrary ? saveFolder : folder(under: saveFolder)
    }

    /// The library home for a kept scratch capture: same name, deduped the
    /// way fresh captures dedupe, so keeping can never overwrite an existing
    /// capture that happens to share the name.
    static func libraryDestination(
        for scratchURL: URL, saveFolder: URL,
        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL {
        let ext = scratchURL.pathExtension
        let base = scratchURL.deletingPathExtension().lastPathComponent
        let name = CaptureConfig.uniqueName(base: base, ext: ext) { candidate in
            exists(saveFolder.appendingPathComponent(candidate))
        }
        return saveFolder.appendingPathComponent(name, isDirectory: false)
    }

    /// Move a scratch capture into the Library and report where it landed.
    /// The caller posts `.captureFilesImported` and re-points the editor —
    /// this only moves the file.
    static func keep(_ scratchURL: URL, saveFolder: URL,
                     fileManager: FileManager = .default) throws -> URL {
        let dest = libraryDestination(for: scratchURL, saveFolder: saveFolder) {
            fileManager.fileExists(atPath: $0.path)
        }
        try fileManager.moveItem(at: scratchURL, to: dest)
        return dest
    }

    /// Remove scratch entries older than `retentionDays`, by modification
    /// date. mtime is honest enough here: a full-library re-encrypt rewrites
    /// packages and resets the clock, which for a 7-day waiting room merely
    /// grants a stay — the Deleted folder needs its explicit trashed-at stamp
    /// because deletion promises a POLICY, and this promises housekeeping.
    @discardableResult
    static func purge(in saveFolder: URL, olderThan days: Int = retentionDays,
                      now: Date = Date(),
                      fileManager: FileManager = .default) -> Int {
        let scratch = folder(under: saveFolder)
        guard fileManager.fileExists(atPath: scratch.path) else { return 0 }
        let entries = (try? fileManager.contentsOfDirectory(
            at: scratch, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []
        let cutoff = now.addingTimeInterval(-Double(days) * 24 * 3600)
        var removed = 0
        for url in entries {
            let mtime = (try? url.resourceValues(
                forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now
            guard mtime < cutoff else { continue }
            if (try? fileManager.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }
}

/// The Settings toggles. Default ON for both — captures and recordings joining
/// the Library is the behaviour every user has today, and scratch is the opt-in.
///
/// Two switches rather than one: throwaway screenshots are an everyday thing
/// and throwaway RECORDINGS much less so, and the consequence of the 7-day
/// sweep differs by orders of magnitude — a few hundred KB against several GB.
/// Someone may reasonably want a scratch pile of screenshots while every
/// recording is filed.
struct ScratchCapturePreference {
    static let key = "CaptureAddsToLibrary"
    static let recordingKey = "RecordingAddsToLibrary"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var addsToLibrary: Bool {
        defaults.object(forKey: Self.key) as? Bool ?? true
    }

    var recordingsAddToLibrary: Bool {
        defaults.object(forKey: Self.recordingKey) as? Bool ?? true
    }
}

extension ScratchCapture {
    /// Total bytes waiting in Scratch, for the Library header. Recordings make
    /// this worth showing: a pile of unkept videos is measured in GB, and the
    /// sweep that will delete them should never be a surprise.
    static func totalSize(in saveFolder: URL, fileManager: FileManager = .default) -> Int64 {
        let scratch = folder(under: saveFolder)
        guard let entries = try? fileManager.contentsOfDirectory(
            at: scratch, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]) else { return 0 }
        return entries.reduce(0) { total, url in total + size(of: url, fileManager: fileManager) }
    }

    /// A `.seal` is a directory package, so its size is the sum of its parts.
    private static func size(of url: URL, fileManager: FileManager) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        if values?.isDirectory == true {
            let inner = (try? fileManager.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
                options: [.skipsHiddenFiles])) ?? []
            return inner.reduce(0) { $0 + size(of: $1, fileManager: fileManager) }
        }
        return Int64(values?.fileSize ?? 0)
    }
}
