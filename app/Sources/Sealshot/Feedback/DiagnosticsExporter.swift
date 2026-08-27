import Foundation
import OSLog

/// Exports this session's Sealshot logs for the feedback email. The
/// OSLogStore read is scoped to the CURRENT PROCESS and filtered to our
/// subsystem — never system-wide. The resulting file is always shown to the
/// user (attached visibly or revealed in Finder) before anything is sent;
/// log lines can contain capture filenames, so nothing is included silently.
enum DiagnosticsExporter {

    struct Entry {
        let date: Date
        let category: String
        let level: String
        let message: String
    }

    static let subsystem = "com.seal-shot.sealshot"
    static let defaultLimit = 2_000

    /// Pure formatter: header + one line per entry, capped to the most
    /// recent `limit`.
    static func format(entries: [Entry], limit: Int = defaultLimit) -> String {
        var lines = ["Sealshot diagnostics — \(AppInfo.versionString) \(AppInfo.edition.label)"]
        if entries.isEmpty {
            lines.append("(no entries)")
            return lines.joined(separator: "\n")
        }
        if entries.count > limit {
            lines.append("(showing most recent \(limit) of \(entries.count) entries)")
        }
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm:ss.SSS"
        for e in entries.suffix(limit) {
            lines.append("\(timeFormatter.string(from: e.date)) [\(e.category)] \(e.level) \(e.message)")
        }
        return lines.joined(separator: "\n")
    }

    /// Thin OS layer: this session's subsystem entries from OSLogStore.
    static func collect() throws -> [Entry] {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        return try store.getEntries()
            .compactMap { $0 as? OSLogEntryLog }
            .filter { $0.subsystem == subsystem }
            .map { Entry(date: $0.date, category: $0.category,
                         level: levelName($0.level), message: $0.composedMessage) }
    }

    /// Write the formatted log to a temp `.txt` and return its URL.
    static func exportFile(entries: [Entry]? = nil) throws -> URL {
        let resolved = try entries ?? collect()
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withFullDate, .withTime]
        let name = "Sealshot-diagnostics-\(stamp.string(from: Date()).replacingOccurrences(of: ":", with: "")).txt"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try format(entries: resolved).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func levelName(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug: return "debug"
        case .info: return "info"
        case .notice: return "notice"
        case .error: return "error"
        case .fault: return "fault"
        default: return "log"
        }
    }
}
