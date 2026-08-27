import Foundation
import os.log

private let oslog = OSLog(subsystem: "com.seal-shot.sealshot", category: "scene")

/// Always-on trace for Live Capture scene identity, written to
/// `~/Library/Application Support/Sealshot/diagnostics/scene.log`.
///
/// Mirrors `UndoDiag` (plain file — `log show` is unreliable in the field;
/// self-trims; inert under XCTest). Exists to catch the "reopened scene
/// reverts to a blank canvas" class of bug: every seam where sceneLayers /
/// sceneOriginalFrames / image assets are written, preserved, hydrated, or
/// consumed logs one line, so a field repro carries its own forensics.
final class SceneDiag: @unchecked Sendable {
    static let shared = SceneDiag()

    static var logFileURL: URL {
        AppSupportDirectory.file("diagnostics/scene.log")
    }

    static func note(_ message: String) { shared.write(message) }
    static func mark(_ message: String) { shared.write("────── " + message) }
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
        os_log("%{public}@", log: oslog, type: .default, message)
        guard !disabled else { return }
        lock.lock(); defer { lock.unlock() }
        let url = Self.logFileURL
        let line = "\(formatter.string(from: Date())) \(message)\n"
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            if !fm.fileExists(atPath: url.path) {
                try line.data(using: .utf8)?.write(to: url)
                return
            }
            // Self-trim at ~1 MB: keep the newest half.
            if let size = try? fm.attributesOfItem(atPath: url.path)[.size] as? Int,
               size > 1_000_000,
               let data = try? Data(contentsOf: url) {
                try data.suffix(500_000).write(to: url)
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            if let data = line.data(using: .utf8) { try handle.write(contentsOf: data) }
        } catch {
            // Diagnostics must never break the feature they observe.
        }
    }
}
