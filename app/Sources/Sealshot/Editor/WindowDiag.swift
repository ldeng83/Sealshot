import AppKit
import os.log

/// Always-on trace of "should the editor window be on screen right now?".
///
/// Written to a FILE as well as the unified log, deliberately: the case this
/// exists for is an app that opens no window and logs nothing, and a unified
/// log under load (a parallel test run, say) drops messages — leaving no
/// evidence at all. A file cannot be throttled away.
///
///   ~/Library/Application Support/Sealshot/diagnostics/window-lifecycle.log
///
/// Every launch marks a session boundary, so a reproduction is one contiguous
/// block: launch → whether the editor was asked for → whether a window was
/// created → what a Dock click decided. Mirrors UndoDiag/ScrollDiag, including
/// the self-trim and the XCTest suppression (a test host opening windows must
/// not pollute a real reproduction).
enum WindowDiag {
    static var logFileURL: URL {
        AppSupportDirectory.file("diagnostics/window-lifecycle.log")
    }

    private static let log = OSLog(subsystem: "com.seal-shot.sealshot", category: "window-diag")
    private static let lock = NSLock()
    private static let disabled = NSClassFromString("XCTestCase") != nil
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func note(_ message: String) { write(message) }

    /// Launch marker: also records the two things that silently suppress the
    /// editor at startup — the XCTest guard, and an environment that looks like
    /// a test run even when it isn't one.
    static func launch(_ phase: String) {
        let xctestClass = NSClassFromString("XCTestCase") != nil
        let xctestEnv = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        write("=== \(phase) — pid \(ProcessInfo.processInfo.processIdentifier), "
              + "XCTestCase-class=\(xctestClass) XCTestEnv=\(xctestEnv) ===")
    }

    /// Snapshot of what the app actually has on screen. `where` names the call
    /// site so a before/after pair brackets one decision.
    static func windows(_ context: String) {
        // NO Int() conversions anywhere here. An off-screen or not-yet-placed
        // window can carry a NaN or out-of-range origin, and Int(Double.nan)
        // TRAPS — which is how the first version of this helper killed every
        // snapshot silently while the plain note() lines kept working.
        // %.0f prints NaN as "nan" and never traps.
        let all = NSApp?.windows ?? []
        let described = all.map { w -> String in
            let f = w.frame
            return String(format: "%@[vis=%@ mini=%@ frame=%.0f,%.0f %.0fx%.0f screen=%@]",
                          String(describing: type(of: w)),
                          w.isVisible ? "Y" : "n",
                          w.isMiniaturized ? "Y" : "n",
                          f.origin.x, f.origin.y, f.width, f.height,
                          w.screen == nil ? "none" : String(format: "%.0f", w.screen!.frame.origin.x))
        }
        write("windows @\(context): \(all.count) → \(described.joined(separator: " "))")
    }

    private static func write(_ message: String) {
        os_log("%{public}@", log: log, type: .default, message)
        guard !disabled else { return }
        lock.lock(); defer { lock.unlock() }

        let url = logFileURL
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        // Self-trim: past ~1 MB keep the newest ~300 KB (cheap, rare).
        if let size = (try? fm.attributesOfItem(atPath: url.path)[.size]) as? Int,
           size > 1_000_000, let data = try? Data(contentsOf: url) {
            try? data.suffix(300_000).write(to: url)
        }
        guard let data = "\(formatter.string(from: Date())) | \(message)\n".data(using: .utf8)
        else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
