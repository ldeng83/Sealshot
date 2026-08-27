import Foundation

private let captureDateFormatter = ISO8601DateFormatter()

/// The time a capture was TAKEN, used for ordering the recent strip / library.
///
/// For a `.seal` this is the manifest's `createdISO8601`, which
/// `writeSealPackage` preserves across every re-save. That matters because each
/// save rewrites the package atomically, resetting BOTH the folder's
/// modification and creation dates to the save time — so ordering by those
/// makes a re-saved old capture jump above newer ones. Falls back to the file's
/// creation date and finally `fallback` (its mtime) for legacy PNGs or an
/// unreadable manifest.
func captureDate(of url: URL, fallback: Date) -> Date {
    if url.pathExtension.lowercased() == "seal" {
        if let data = sealEntryData("manifest.json", at: url),
           let manifest = try? SealManifest.decodeJSON(from: data),
           let created = captureDateFormatter.date(from: manifest.createdISO8601) {
            return created
        }
    }
    if let created = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate {
        return created
    }
    return fallback
}

/// Plain movie containers a recording can be saved as when the user turns off
/// the Sealshot package wrapper (Settings ▸ Recording). They are ordinary
/// files in the save folder, listed alongside captures rather than hidden in a
/// subfolder — a recording the app can't see is a recording the user thinks it
/// lost.
internal let plainMovieExtensions: Set<String> = ["mov", "mp4"]

/// Cheap stat-level scan of `folder`: every `.png` file, `.seal` package, and
/// plain `.mov`/`.mp4` recording with its mtime. No manifest reads — capture
/// dates come from the Library's index, or from `captureDate(of:)` for callers
/// that need them resolved here. Unsorted. Returns empty if the folder is
/// missing.
internal func scanCaptureFiles(
    in folder: URL,
    fileManager: FileManager = .default
) -> [(URL, Date)] {
    let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
    let contents = (try? fileManager.contentsOfDirectory(
        at: folder,
        includingPropertiesForKeys: keys,
        options: [.skipsHiddenFiles]
    )) ?? []

    return contents.compactMap { url in
        let ext = url.pathExtension.lowercased()
        guard ext == "png" || ext == "seal" || plainMovieExtensions.contains(ext)
        else { return nil }
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
        // .png and plain movies are regular files; .seal packages are
        // directories (file packages). Accept either.
        if ext != "seal" {
            guard values.isRegularFile == true else { return nil }
        }
        guard let mtime = values.contentModificationDate else { return nil }
        return (url, mtime)
    }
}

/// Scan `folder` and resolve each capture's date (see `captureDate`) — one
/// manifest read per `.seal`. The recent strip's ordering uses this; the
/// Library resolves dates from its index instead.
internal func listCaptures(
    in folder: URL,
    fileManager: FileManager = .default
) -> [(URL, Date)] {
    scanCaptureFiles(in: folder, fileManager: fileManager)
        .map { url, mtime in (url, captureDate(of: url, fallback: mtime)) }
}

/// Find PNG/seal captures in `folder` from the `coveringDays` most recent
/// calendar days that have captures. Returns URLs sorted newest first.
/// Pure function aside from the file-system read — see `RecentCaptureFinderTests`
/// for the day-window logic factored into `filterRecentCaptures`.
internal func findRecentCaptures(
    in folder: URL,
    coveringDays dayCount: Int = 7,
    fileManager: FileManager = .default
) -> [URL] {
    let candidates = listCaptures(in: folder, fileManager: fileManager)
    return filterRecentCaptures(candidates, coveringDays: dayCount)
}

/// Whether the strip must fall back to a direct disk scan rather than trust
/// the index listing.
///
/// `nil` means the index database failed to open. An EMPTY listing means it
/// opened cleanly but holds no rows — indistinguishable from "not built yet",
/// which is the state after a first run, an index reset, or an encryption-mode
/// change that orphans the previous index (`purgePlaintextIndex` drops the
/// plaintext file when encryption is switched on, so switching it back off
/// leaves nothing to read until a reconcile rebuilds it).
///
/// Both cases must scan: the fallback used to be reached only on open failure,
/// so an empty-but-healthy index left the strip blank while captures sat on
/// disk. The scan costs one folder listing, and only in that already-degraded
/// case — a populated index is trusted as before.
internal func stripNeedsDirectScan(indexed: [StripItem]?) -> Bool {
    indexed?.isEmpty ?? true
}

/// Whether a strip watching `folder` must reload for a `libraryIndexDidChange`
/// posting that reconciled `changedFolder`.
///
/// Scoped by folder so a save-folder reconcile doesn't churn the Deleted strip
/// (which watches `<save>/Deleted`) and vice versa. A posting with no folder is
/// treated as unknown scope and refreshes — staying stale is the worse failure.
/// Paths are compared standardized: a folder read back from UserDefaults
/// carries a trailing slash the picker's URL doesn't (see
/// `CaptureConfig.saveFolder`).
internal func stripShouldRefresh(forIndexChangeIn changedFolder: URL?,
                                 watching folder: URL) -> Bool {
    guard let changedFolder else { return true }
    return changedFolder.standardizedFileURL.path == folder.standardizedFileURL.path
}

/// The `dayCount` most recent calendar days (start-of-day keys) present in
/// `dates`. The recent window is "days WITH captures" rather than calendar
/// days back from now, so a library whose newest capture is weeks old still
/// fills the strip instead of going blank.
internal func recentCaptureDayWindow(
    _ dates: [Date],
    dayCount: Int,
    calendar: Calendar = .current
) -> Set<Date> {
    Set(Set(dates.map { calendar.startOfDay(for: $0) })
        .sorted(by: >)
        .prefix(dayCount))
}

/// Pure filter+sort over already-resolved (URL, date) pairs: keep captures
/// from the `dayCount` most recent capture days, newest first. Tested directly.
internal func filterRecentCaptures(
    _ candidates: [(URL, Date)],
    coveringDays dayCount: Int,
    calendar: Calendar = .current
) -> [URL] {
    let days = recentCaptureDayWindow(candidates.map { $0.1 },
                                      dayCount: dayCount, calendar: calendar)
    return candidates
        .filter { days.contains(calendar.startOfDay(for: $0.1)) }
        .sorted { $0.1 > $1.1 }    // newest first
        .map { $0.0 }
}
