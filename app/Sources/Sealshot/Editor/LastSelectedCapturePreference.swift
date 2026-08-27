import Foundation

/// Remembers the capture (image or video) that was last open/selected, so the
/// app reopens it on the next launch instead of always jumping to the newest.
enum LastSelectedCapturePreference {

    private static let key = "lastSelectedCapturePath"

    /// Store the standardized path; pass nil to clear (e.g. a scratch canvas).
    static func store(_ url: URL?, into defaults: UserDefaults = .standard) {
        if let url {
            defaults.set(url.standardizedFileURL.path, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    /// The remembered capture, or nil if none / the file no longer exists /
    /// it now lives in the trash (callers fall back to the newest capture).
    static func load(deletedFolderName: String = "Deleted",
                     defaults: UserDefaults = .standard,
                     fileManager: FileManager = .default) -> URL? {
        guard let path = defaults.string(forKey: key) else { return nil }
        let url = URL(fileURLWithPath: path)
        guard fileManager.fileExists(atPath: url.path),
              url.deletingLastPathComponent().lastPathComponent != deletedFolderName
        else { return nil }
        return url
    }
}
