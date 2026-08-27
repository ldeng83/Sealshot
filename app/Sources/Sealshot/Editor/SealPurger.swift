import Foundation
import os.log

private let log = OSLog(subsystem: "com.seal-shot.sealshot", category: "purger")

/// Auto-purges old captures from `<saveFolder>/Deleted/`. Fired from
/// `AppDelegate.applicationDidFinishLaunching` on a detached, low-QoS
/// task so it never blocks the main thread.
enum SealPurger {

    static let deletedSubfolderName = SealDeleter.deletedSubfolderName

    /// Scan `<saveFolder>/Deleted/` and remove every entry whose
    /// modification date is more than `olderThan` days before `now`.
    /// Returns the count of files removed. Idempotent — safe to call
    /// repeatedly; safe if the folder doesn't exist.
    @discardableResult
    static func purgeDeletedFolder(
        in saveFolder: URL,
        olderThan days: Int,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) -> Int {
        let deleted = saveFolder.appendingPathComponent(deletedSubfolderName, isDirectory: true)
        guard fileManager.fileExists(atPath: deleted.path) else { return 0 }

        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        let entries = (try? fileManager.contentsOfDirectory(
            at: deleted,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )) ?? []

        let iso = ISO8601DateFormatter()
        let candidates: [(URL, Date)] = entries.compactMap { url in
            // Age by the EXPLICIT trashed-at stamp SealDeleter writes at move
            // time. mtime is only the legacy fallback: it doubles as "last
            // content rewrite", so an encryption enable/disable (which
            // rebuilds every package) used to reset every trash item's
            // retention clock.
            if let stamp = SealDeleter.readTimestampXattr(SealDeleter.deletedAtXattr, at: url),
               let trashedAt = iso.date(from: stamp) {
                return (url, trashedAt)
            }
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            guard let mtime = values.contentModificationDate else { return nil }
            return (url, mtime)
        }

        let toRemove = purgeCandidates(candidates, olderThan: days, now: now)

        var removed = 0
        for url in toRemove {
            do {
                try fileManager.removeItem(at: url)
                removed += 1
            } catch {
                os_log("purge: failed to remove %{public}@: %{public}@",
                       log: log, type: .error,
                       url.path, String(describing: error))
            }
        }
        if removed > 0 {
            os_log("purge: removed %{public}d files older than %{public}d days from %{public}@",
                   log: log, type: .info,
                   removed, days, deleted.path)
        }
        return removed
    }

    /// Pure date-cutoff filter, exposed for unit tests. Returns the URLs
    /// whose mtime is strictly older than `now - days`.
    static func purgeCandidates(
        _ entries: [(URL, Date)],
        olderThan days: Int,
        now: Date
    ) -> [URL] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        return entries.compactMap { (url, mtime) in
            mtime < cutoff ? url : nil
        }
    }
}
