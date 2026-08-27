import AppKit
import os.log

private let log = OSLog(subsystem: "com.seal-shot.sealshot", category: "extract-window")

/// Field diagnostic for the "Extract Structured Data window has no horizontal
/// scroll bar" report. Snapshots every text scroll view in the window — clip
/// width, document width, what layout has actually measured, container config,
/// and the scroller's style/visibility/knob — at open, after each render, and
/// after resizes. The chain has five links that can each explain the symptom
/// (content fits / layout hasn't measured the wide row / container re-tracking
/// width / overlay-style scrollers that never show at rest / autohide
/// miscomputing), and the snapshot separates them. Mirrors `LaunchAtLoginDiag`:
/// plain file because `log show` has proven unreliable in the field;
/// self-trims; inert under XCTest.
final class ExtractWindowDiag: @unchecked Sendable {
    static let shared = ExtractWindowDiag()

    static var logFileURL: URL {
        AppSupportDirectory.file("diagnostics/extract-window.log")
    }

    static func note(_ message: String) { shared.write(message) }

    /// One line per text scroll view under `root`, plus one line of globals.
    @MainActor
    static func snapshot(_ root: NSView?, context: String) {
        guard let root else { note("\(context): no content view"); return }
        let styleName = NSScroller.preferredScrollerStyle == .overlay ? "overlay" : "legacy"
        let showBars = UserDefaults.standard.string(forKey: "AppleShowScrollBars") ?? "unset"
        note("\(context): preferredStyle=\(styleName) AppleShowScrollBars=\(showBars)")

        var queue: [NSView] = [root]
        var index = 0
        while let view = queue.popLast() {
            queue.append(contentsOf: view.subviews)
            guard let scroll = view as? NSScrollView,
                  let tv = scroll.documentView as? NSTextView else { continue }
            index += 1
            let container = tv.textContainer
            let used = tv.layoutManager?.usedRect(for: container!)
            let scroller = scroll.horizontalScroller
            let fmt: (CGFloat?) -> String = { $0.map { String(format: "%.1f", $0) } ?? "nil" }
            note("\(context): #\(index) clipW=\(fmt(scroll.contentView.bounds.width))"
                 + " docW=\(fmt(tv.frame.width))"
                 + " usedW=\(fmt(used?.width))"
                 + " containerW=\(fmt(container?.containerSize.width))"
                 + " wTracks=\(container?.widthTracksTextView == true ? 1 : 0)"
                 + " hRes=\(tv.isHorizontallyResizable ? 1 : 0)"
                 + " mask=\(tv.autoresizingMask.rawValue)"
                 + " hasH=\(scroll.hasHorizontalScroller ? 1 : 0)"
                 + " autohide=\(scroll.autohidesScrollers ? 1 : 0)"
                 + " style=\(scroll.scrollerStyle == .overlay ? "overlay" : "legacy")"
                 + " scrollerHidden=\(scroller?.isHidden != false ? 1 : 0)"
                 + " knob=\(fmt(scroller?.knobProportion))"
                 + " viewHidden=\(view.isHiddenOrHasHiddenAncestor ? 1 : 0)")
        }
        if index == 0 { note("\(context): no text scroll views found") }
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
