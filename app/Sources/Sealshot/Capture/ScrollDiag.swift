import Foundation
import CoreGraphics
import AppKit
import os.log

private let log = OSLog(subsystem: "com.seal-shot.sealshot", category: "scroll-capture")

/// Always-on structured trace for scrolling-capture sessions, written to
/// `~/Library/Application Support/Sealshot/diagnostics/scroll-capture.log`.
///
/// A plain file because `log show` has proven unreliable for this app in the
/// field — a diagnosis channel that can silently return nothing is worse than
/// none. Volume is tiny (~1 line per scroll step, a few KB per session) and
/// the file self-trims at ~1 MB. Mirrored to os_log too. Thread-safe; inert
/// under XCTest so unit tests never touch the real Application Support.
final class ScrollDiag: @unchecked Sendable {
    static let shared = ScrollDiag()

    static var logFileURL: URL {
        AppSupportDirectory.file("diagnostics/scroll-capture.log")
    }

    /// One line in the session trace. Static for terse call sites.
    static func note(_ message: String) { shared.write(message) }
    /// Session boundary marker (visually scannable in the file).
    static func session(_ message: String) { shared.write("────── " + message) }

    private let lock = NSLock()
    private let disabled: Bool
    private let formatter: DateFormatter

    private init() {
        disabled = NSClassFromString("XCTestCase") != nil
        formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    }

    // MARK: - Scroll-event sniffer (diagnostic)

    /// Listen-only tap logging every scrollWheel event on the system —
    /// deltas, phases, momentum, cadence, posting PID. Purpose: capture the
    /// exact event recipe of OTHER tools' scroll captures (Shottr) so the
    /// wheel injector can replicate it. Enable with
    /// `defaults write com.seal-shot.sealshot.direct ScrollSniffer -bool true`
    /// and relaunch. Never enabled in normal use.
    private static var snifferTap: CFMachPort?
    static func installSnifferIfEnabled() {
        guard UserDefaults.standard.bool(forKey: "ScrollSniffer"), snifferTap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        let callback: CGEventTapCallBack = { _, _, event, _ in
            let pt = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
            let line = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
            let phase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
            let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
            let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous)
            let pid = event.getIntegerValueField(.eventSourceUnixProcessID)
            let tag = event.getIntegerValueField(.eventSourceUserData)
            let loc = event.location
            ScrollDiag.note("sniff: dY(pt)=\(String(format: "%.1f", pt)) dY(line)=\(line) "
                + "phase=\(phase) momentum=\(momentum) cont=\(continuous) "
                + "srcPID=\(pid) tag=\(String(tag, radix: 16)) at(\(Int(loc.x)),\(Int(loc.y)))")
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .listenOnly, eventsOfInterest: mask,
            callback: callback, userInfo: nil) else {
            note("sniff: TAP CREATION FAILED (permissions?)")
            return
        }
        snifferTap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        note("sniff: scroll-event sniffer ACTIVE")
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
