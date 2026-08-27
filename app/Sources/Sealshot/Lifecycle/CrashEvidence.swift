import Foundation
import os.log

private let log = OSLog(subsystem: "com.seal-shot.sealshot", category: "lifecycle")

/// A breadcrumb written at launch and removed on clean quit. Still present at
/// the next launch ⇒ the previous session ended uncleanly (crash, force-quit,
/// power loss). On its own it does NOT mean "crash" — `CrashReportLocator`
/// corroborates it against a real macOS crash report before anyone is told.
struct SessionMarker: Codable, Equatable {
    let launchDate: Date
    let appVersion: String
    let pid: Int32
}

/// Reads/writes the session marker under Application Support. Failures never
/// throw and degrade to "clean launch" — crash visibility must never itself
/// break a launch (same stance as `HistoryStore`).
struct SessionMarkerStore {

    let directory: URL

    init(directory: URL = SessionMarkerStore.defaultDirectory) {
        self.directory = directory
    }

    static var defaultDirectory: URL {
        AppSupportDirectory.sealshot
    }

    var fileURL: URL { directory.appendingPathComponent("session.json") }

    /// The marker left behind by the previous session, or nil if it quit
    /// cleanly. Unreadable/corrupt markers read as nil (treated as clean).
    func readStale() -> SessionMarker? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(SessionMarker.self, from: data)
    }

    /// Write this session's marker, creating the directory on demand.
    func writeFresh(_ marker: SessionMarker) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(marker)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            os_log("session marker write failed: %{public}@",
                   log: log, type: .error, String(describing: error))
        }
    }

    /// Remove the marker — this session is ending cleanly.
    func clearOnCleanQuit() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

/// Finds the macOS crash report (`.ips`) that corroborates a stale session
/// marker. Only a report for THIS app (matching bundle ID), written at or
/// after that session's launch, counts — so a force-quit never prompts, and
/// a MAS-build crash on the same Mac never triggers the Direct build.
/// Every failure path returns nil (no prompt).
struct CrashReportLocator {

    let reportsDirectory: URL
    let bundleID: String

    init(reportsDirectory: URL = CrashReportLocator.defaultReportsDirectory,
         bundleID: String = Bundle.main.bundleIdentifier ?? "") {
        self.reportsDirectory = reportsDirectory
        self.bundleID = bundleID
    }

    static var defaultReportsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
    }

    /// The newest `Sealshot*.ips` modified at or after `marker.launchDate`
    /// whose header bundle ID is ours, or nil.
    func reportMatching(_ marker: SessionMarker) -> URL? {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: reportsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles) else { return nil }

        return entries
            .filter {
                // Both editions' executables are named "Sealshot", so the
                // filename prefix can NOT distinguish MAS from Direct — the
                // bundleID check in headerMatches is what prevents one
                // build's crash from prompting the other. Keep both gates.
                $0.lastPathComponent.hasPrefix("Sealshot")
                    && $0.pathExtension == "ips"
            }
            .compactMap { url -> (url: URL, date: Date)? in
                guard
                    let date = (try? url.resourceValues(
                        forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                    date >= marker.launchDate,
                    headerMatches(url)
                else { return nil }
                return (url, date)
            }
            .max { $0.date < $1.date }?
            .url
    }

    /// An `.ips` file's first line is a JSON header containing `bundleID`.
    /// Corrupt or foreign headers ⇒ false (file is skipped). Reads at most
    /// 8 KB — headers are well under 1 KB and the payload can be megabytes.
    private func headerMatches(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 8192) else { return false }
        let firstLine = Data(data.prefix(while: { $0 != UInt8(ascii: "\n") }))
        guard
            let header = (try? JSONSerialization.jsonObject(with: firstLine))
                as? [String: Any],
            let reportBundleID = header["bundleID"] as? String
        else { return false }
        return reportBundleID == bundleID
    }
}
