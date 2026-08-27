import Foundation

/// Remembers the folder the user last chose in a save/export panel so the next
/// panel opens there, instead of resetting to a fixed default (the source
/// file's folder or the capture save folder). Persisted in `UserDefaults`.
enum LastSaveDirectory {
    static let key = "lastSaveDirectory"

    /// The last folder the user saved into, or nil if there is none recorded
    /// (or it no longer exists). Setting nil clears it.
    static var url: URL? {
        get {
            guard let path = UserDefaults.standard.string(forKey: key) else { return nil }
            let dir = URL(fileURLWithPath: path, isDirectory: true)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir),
                  isDir.boolValue else { return nil }
            return dir
        }
        set { UserDefaults.standard.set(newValue?.path, forKey: key) }
    }

    /// Record the folder that `savedFileURL` lives in as the last save folder.
    static func remember(_ savedFileURL: URL) {
        url = savedFileURL.deletingLastPathComponent()
    }
}
