import AppKit
import os.log

private let log = OSLog(subsystem: "com.seal-shot.sealshot", category: "canvas-paste")

/// Field diagnostic for "pasting a big image into a new canvas doesn't resize
/// the canvas".
///
/// The decision has four inputs — the paste reaching `handlePaste` at all, the
/// canvas being empty, the image being bigger than the canvas, and the source
/// reading as a blank drawing surface — and every one of them holds in a unit
/// test, so the disagreement is with the running document, not the logic. This
/// records all four plus the outcome, which separates them in one reproduction.
/// Mirrors `LaunchAtLoginDiag`: plain file because `log show` has proven
/// unreliable in the field; self-trims; inert under XCTest.
final class CanvasPasteDiag: @unchecked Sendable {
    static let shared = CanvasPasteDiag()

    static var logFileURL: URL {
        AppSupportDirectory.file("diagnostics/canvas-paste.log")
    }

    static func note(_ message: String) { shared.write(message) }

    /// One line per paste: what arrived, what it landed on, and what was done.
    @MainActor
    static func snapshot(image: CGImage, state: EditorState, grew: Bool) {
        let alpha: String
        switch image.alphaInfo {
        case .none: alpha = "none"
        case .premultipliedLast: alpha = "premulLast"
        case .premultipliedFirst: alpha = "premulFirst"
        case .last: alpha = "last"
        case .first: alpha = "first"
        case .noneSkipLast: alpha = "skipLast"
        case .noneSkipFirst: alpha = "skipFirst"
        case .alphaOnly: alpha = "alphaOnly"
        @unknown default: alpha = "?"
        }
        let src = state.sourceImage
        let srcAlpha = src.alphaInfo.rawValue
        note("paste: image=\(image.width)x\(image.height) alpha=\(alpha)"
             + " canvas=\(Int(state.visibleImageSize.width))x\(Int(state.visibleImageSize.height))"
             + " source=\(src.width)x\(src.height) srcAlphaRaw=\(srcAlpha)"
             + " srcBpp=\(src.bitsPerPixel) srcBpc=\(src.bitsPerComponent)"
             + " blank=\(NewCanvasFactory.isBlankCanvas(src) ? 1 : 0)"
             + " annotations=\(state.annotations.count)"
             + " cropped=\(state.croppedRect.map { "\(Int($0.width))x\(Int($0.height))" } ?? "nil")"
             + " readOnly=\(state.isReadOnly ? 1 : 0)"
             + " → \(grew ? "GREW" : "scaled onto canvas")")
    }

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
        // Self-trim: past ~1 MB keep the newest ~300 KB.
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
