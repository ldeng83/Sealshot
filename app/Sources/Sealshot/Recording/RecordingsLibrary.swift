import Foundation

/// One screen recording on disk. Lighter than a Library item: recordings are a
/// distinct, unencrypted asset type (`.mov`/`.mp4` under `<saveFolder>/
/// Recordings/`) with no manifest, tags, or OCR, so they live in their own
/// section rather than the sealed screenshot index.
struct RecordingItem: Identifiable, Equatable {
    let url: URL
    let modified: Date
    let size: Int64
    /// True for `.sealrec` containers (encrypted at rest); false for plain
    /// `.mov`/`.mp4`. Drives thumbnail/playback path.
    let isEncrypted: Bool

    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }
}

/// Lists screen recordings in the Recordings folder, newest first.
enum RecordingsLibrary {
    static let plainExtensions: Set<String> = ["mov", "mp4"]
    static let encryptedExtension = "sealrec"
    static var videoExtensions: Set<String> { plainExtensions.union([encryptedExtension]) }

    /// `<saveFolder>/Recordings` — the same directory `RecordingCoordinator`
    /// writes to.
    static func folder(forSaveFolder saveFolder: URL) -> URL {
        saveFolder.appendingPathComponent("Recordings", isDirectory: true)
    }

    /// Video files in `folder`, sorted by modification date (newest first).
    /// Non-video files and unreadable entries are skipped; a missing folder
    /// yields an empty list.
    static func items(in folder: URL, fileManager: FileManager = .default) -> [RecordingItem] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let urls = try? fileManager.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) else { return [] }
        return urls.compactMap { url -> RecordingItem? in
            let ext = url.pathExtension.lowercased()
            guard videoExtensions.contains(ext) else { return nil }
            let vals = try? url.resourceValues(forKeys: Set(keys))
            return RecordingItem(url: url,
                                 modified: vals?.contentModificationDate ?? .distantPast,
                                 size: Int64(vals?.fileSize ?? 0),
                                 isEncrypted: ext == encryptedExtension)
        }
        .sorted { $0.modified > $1.modified }
    }
}
