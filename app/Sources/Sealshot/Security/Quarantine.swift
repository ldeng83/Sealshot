import Foundation
import os.log

private let log = OSLog(subsystem: "com.seal-shot.sealshot", category: "quarantine")

/// Where locked packages whose key is no longer reachable get set aside when the
/// user turns encryption off. They are never decrypted (we can't) and never
/// deleted (the bytes may still be recoverable elsewhere) — just moved out of the
/// way so disabling encryption can always complete.
enum Quarantine {
    static let folderName = "Locked-Unrecoverable"

    /// Move `packageURL` under `<saveFolder>/Locked-Unrecoverable/`, preserving the
    /// ciphertext. Collision-safe (appends `-1`, `-2`, …). Writes a README the
    /// first time the folder is created. Returns the destination URL.
    @discardableResult
    static func move(_ packageURL: URL, saveFolder: URL) throws -> URL {
        let folder = saveFolder.appendingPathComponent(folderName, isDirectory: true)
        let isNew = !FileManager.default.fileExists(atPath: folder.path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if isNew { writeReadme(in: folder) }

        let dest = uniqueDestination(for: packageURL.lastPathComponent, in: folder)
        try FileManager.default.moveItem(at: packageURL, to: dest)
        os_log("quarantined %{public}@", log: log, type: .info, packageURL.lastPathComponent)
        return dest
    }

    /// Collision-safe destination for `name` inside `folder`: `foo.json`,
    /// then `foo-1.json`, `foo-2.json`, … Shared with `LockoutReset`, whose
    /// restore-seed files (keystore/keyring/capsules) need the exact same
    /// never-clobber idiom that locked packages get above.
    static func uniqueDestination(for name: String, in folder: URL) -> URL {
        let candidate = folder.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        var i = 1
        while true {
            let suffixed = ext.isEmpty ? "\(base)-\(i)" : "\(base)-\(i).\(ext)"
            let url = folder.appendingPathComponent(suffixed)
            if !FileManager.default.fileExists(atPath: url.path) { return url }
            i += 1
        }
    }

    private static func writeReadme(in folder: URL) {
        let text = """
        DO NOT DELETE THIS FOLDER unless you are certain you no longer need
        these captures.

        Sealshot could not decrypt these captures when you turned off Enhanced
        Security, so they were moved here with their encrypted contents FULLY
        INTACT — nothing has been deleted. Common causes:

        • The key that encrypted them is no longer on this Mac. If you still
          have the recovery code AND the matching keystore, you can recover
          the key and reopen them.
        • A Sealshot bug failed to convert them. A future update may decrypt
          them — keeping this folder preserves that option.
        """
        try? Data(text.utf8).write(
            to: folder.appendingPathComponent("README.txt"), options: .atomic)
    }
}
