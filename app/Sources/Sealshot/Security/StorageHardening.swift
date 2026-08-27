import Foundation
import os.log

private let log = OSLog(subsystem: "com.seal-shot.sealshot", category: "hardening")

/// Non-crypto storage hardening, applied at launch regardless of the
/// encryption toggle: keep captures out of Spotlight and tighten POSIX
/// permissions. Deliberately does NOT exclude from Time Machine — encrypted
/// backups are desirable and carry keystore.json for recovery.
enum StorageHardening {
    static func apply(to folder: URL) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir),
              isDir.boolValue else { return }
        // Spotlight: a `.metadata_never_index` file stops mds from indexing
        // the folder's contents (captures must not surface in system search).
        let marker = folder.appendingPathComponent(".metadata_never_index")
        if !FileManager.default.fileExists(atPath: marker.path) {
            FileManager.default.createFile(atPath: marker.path, contents: Data())
        }
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: folder.path)
        } catch {
            os_log("hardening perms failed for %{public}@: %{public}@",
                   log: log, type: .error, folder.path, String(describing: error))
        }
    }
}
