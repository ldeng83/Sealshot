import AppKit
import os.log

private let log = OSLog(subsystem: "com.seal-shot.sealshot", category: "floating-drag")

/// Field diagnostic for "dragging a capture out of the floating panel bounces
/// back from Terminal". The drag has four links that can each explain a bounce
/// — export gate, promise-vs-eager choice, the eager render failing, and the
/// receiver refusing the offered types — and one line per drag records them
/// all, plus the session's FINAL operation (none = the receiver refused).
/// Mirrors `LaunchAtLoginDiag`: plain file, self-trims, inert under XCTest.
final class FloatingDragDiag: @unchecked Sendable {
    static let shared = FloatingDragDiag()

    static var logFileURL: URL {
        AppSupportDirectory.file("diagnostics/floating-drag.log")
    }

    static func note(_ message: String) { shared.write(message) }

    private let lock = NSLock()
    private let disabled: Bool
    private let formatter: DateFormatter

    private init() {
        disabled = NSClassFromString("XCTestCase") != nil
        formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        write("────── session start | \(AppInfo.versionString)")
    }

    private func write(_ message: String) {
        os_log("%{public}@", log: log, type: .default, message)
        guard !disabled else { return }
        lock.lock(); defer { lock.unlock() }
        let url = Self.logFileURL
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
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
