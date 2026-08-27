import Foundation
import os.log

private let log = OSLog(subsystem: "com.seal-shot.sealshot", category: "undo-history")

/// Always-on structured trace for the unified undo/redo system, written to
/// `~/Library/Application Support/Sealshot/diagnostics/undo-history.log`.
///
/// Mirrors `ScrollDiag`'s design (plain file because `log show` has proven
/// unreliable in the field; self-trims at ~1 MB; inert under XCTest). Volume
/// is tiny — undo gestures, checkpoints, history load/save, and state swaps
/// each log one line — so it stays on permanently and a field report of
/// "redo disappeared" carries its own forensics.
final class UndoDiag: @unchecked Sendable {
    static let shared = UndoDiag()

    static var logFileURL: URL {
        AppSupportDirectory.file("diagnostics/undo-history.log")
    }

    /// One line in the trace. Static for terse call sites.
    static func note(_ message: String) { shared.write(message) }
    /// Section marker (visually scannable in the file).
    static func mark(_ message: String) { shared.write("────── " + message) }

    /// Short display form of a capture URL (basename only; nil-safe).
    static func name(_ url: URL?) -> String { url?.lastPathComponent ?? "none" }

    private let lock = NSLock()
    private let disabled: Bool
    private let formatter: DateFormatter

    private init() {
        disabled = NSClassFromString("XCTestCase") != nil
        formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    }

    private func write(_ message: String) {
        os_log("%{public}@", log: log, type: .default, message)
        guard !disabled else { return }
        lock.lock(); defer { lock.unlock() }

        let url = Self.logFileURL
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                withIntermediateDirectories: true)

        // Self-trim: past ~1 MB keep the newest ~300 KB (cheap, rare).
        if let size = (try? fm.attributesOfItem(atPath: url.path)[.size]) as? Int,
           size > 1_000_000,
           let data = try? Data(contentsOf: url) {
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
