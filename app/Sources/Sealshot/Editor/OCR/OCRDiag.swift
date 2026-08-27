import Foundation
import CoreGraphics
import os.log

/// Opt-in tracing for the Live Text recognition pipeline, for the case where
/// recognized text is MISSING and the question is which stage lost it.
///
/// Two things make that hard to investigate without this:
///   * the layout is cached twice (in memory, then inside the `.seal`), so
///     reopening a capture re-draws the OLD boxes and never re-runs anything —
///     including after the recognizer itself has been improved;
///   * the pipeline drops lines in four different places (tile de-dup, seam
///     absorption, row stitching, column repair), and only the last of them
///     logged its decisions.
///
/// Enable:  defaults write com.seal-shot.sealshot.direct SealshotOCRDiag -bool YES
/// Disable: defaults delete com.seal-shot.sealshot.direct SealshotOCRDiag
///
/// While enabled, BOTH caches are bypassed (every open re-recognizes, which is
/// slow by design) and each stage logs its line count plus every line's text
/// and x-range, so a lost line can be attributed to the exact stage that
/// removed it. Off by default and read fresh each time, so turning it on needs
/// no relaunch.
///
/// Written to a FILE as well as the unified log:
///
///   ~/Library/Application Support/Sealshot/diagnostics/ocr.log
///
/// The unified log drops messages under load, and a stage dump is hundreds of
/// lines arriving in a burst — precisely the shape that gets throttled away.
/// A reproduction that has to be repeated because the evidence was dropped is
/// worse than a slightly slower recognizer. Mirrors ScrollDiag/WindowDiag,
/// including the self-trim.
enum OCRDiag {
    static let key = "SealshotOCRDiag"
    private static let log = OSLog(subsystem: "com.seal-shot.sealshot", category: "ocr")
    private static let lock = NSLock()
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static var logFileURL: URL {
        AppSupportDirectory.file("diagnostics/ocr.log")
    }

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: key) }

    /// One pipeline stage's output. `label` names the stage; the dump is one
    /// line per recognized line so a diff between consecutive stages shows
    /// exactly what disappeared.
    static func stage(_ label: String, _ items: [(line: RecognizedLine, conf: Float)]) {
        guard isEnabled else { return }
        write("stage \(label) → \(items.count) lines")
        for item in items {
            // %.3f throughout, never Int(): a degenerate box can carry a NaN
            // and Int(Double.nan) traps, which would take the app down in the
            // middle of the reproduction it exists to record.
            write(String(format: "  [%@] x[%.3f…%.3f] y%.3f conf%.2f %@",
                         label, item.line.box.minX, item.line.box.maxX,
                         item.line.box.minY, item.conf, item.line.text))
        }
    }

    /// Tiling geometry — a line cut mid-word almost always means a seam ran
    /// through it, and that is only checkable against the actual rects.
    static func tiles(_ tiles: [CGRect], imageW: CGFloat, imageH: CGFloat) {
        guard isEnabled else { return }
        write(String(format: "image %.0fx%.0f, %d tiles", imageW, imageH, tiles.count))
        for (i, t) in tiles.enumerated() {
            write(String(format: "  tile[%d] x[%.0f…%.0f] y[%.0f…%.0f]",
                         i, t.minX, t.maxX, t.minY, t.maxY))
        }
    }

    static func note(_ message: String) {
        guard isEnabled else { return }
        write(message)
    }

    /// Marks the start of one recognition pass, so a log holding several
    /// reproductions can be split by eye into the runs that produced them.
    static func pass(_ context: String) {
        guard isEnabled else { return }
        write("=== recognition pass — \(context) ===")
    }

    private static func write(_ message: String) {
        os_log("OCRDIAG %{public}@", log: log, type: .info, message)
        lock.lock(); defer { lock.unlock() }

        let url = logFileURL
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        // Self-trim: past ~4 MB keep the newest ~1 MB. Roomier than the other
        // diags on purpose — one pass over a dense screenshot is thousands of
        // lines, and trimming mid-reproduction would discard the evidence.
        if let size = (try? fm.attributesOfItem(atPath: url.path)[.size]) as? Int,
           size > 4_000_000, let data = try? Data(contentsOf: url) {
            try? data.suffix(1_000_000).write(to: url)
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
