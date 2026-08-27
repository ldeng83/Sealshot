import AppKit
import Foundation
import ServiceManagement
import os.log

private let log = OSLog(subsystem: "com.seal-shot.sealshot", category: "launch-at-login")

/// Field diagnostic for the "Launch at login switches itself off when the app
/// loses focus" report: traces every SMAppService status observation (logging
/// transitions, not per-render noise), every register/unregister request with
/// before/after status, and app activate/deactivate events — the reported
/// trigger. Written to
/// `~/Library/Application Support/Sealshot/diagnostics/launch-at-login.log`.
/// Mirrors `UndoDiag`'s design (plain file because `log show` has proven
/// unreliable in the field; self-trims at ~1 MB; inert under XCTest).
final class LaunchAtLoginDiag: @unchecked Sendable {
    static let shared = LaunchAtLoginDiag()

    static var logFileURL: URL {
        AppSupportDirectory.file("diagnostics/launch-at-login.log")
    }

    /// One line in the trace. Static for terse call sites.
    static func note(_ message: String) { shared.write(message) }

    static func statusName(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered: return "notRegistered"
        case .enabled: return "enabled"
        case .requiresApproval: return "requiresApproval"
        case .notFound: return "notFound"
        @unknown default: return "unknown(\(status.rawValue))"
        }
    }

    /// Read the current status and record the observation. `context` says who
    /// looked (binding.get, didResignActive, …).
    ///
    /// Every read is logged — for the settings toggle this doubles as a
    /// render trace, which is the point: it tells "SwiftUI re-read and got
    /// false" apart from "SwiftUI never re-read", the two explanations for a
    /// switch whose graphic disagrees with the OS. Bursts of identical reads
    /// within one second are coalesced into a `xN` count so a render storm
    /// can't drown the file.
    static func observedStatus(context: String,
                               service: LaunchAtLoginService = MainAppLaunchAtLoginService())
        -> SMAppService.Status {
        let status = service.status
        shared.recordObservation(status, context: context)
        return status
    }

    private let lock = NSLock()
    private let disabled: Bool
    private let formatter: DateFormatter
    private var lastObserved: SMAppService.Status?
    private var observers: [NSObjectProtocol] = []
    /// Burst coalescing for repeated identical reads (see `observedStatus`).
    private var pendingContext: String?
    private var pendingStatus: SMAppService.Status?
    private var pendingCount = 0
    private var pendingSince = Date.distantPast

    private init() {
        disabled = NSClassFromString("XCTestCase") != nil
        formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"

        // SMAppService is bundle-path sensitive — a second copy of the app
        // (DerivedData build vs /Applications) is a classic cause of status
        // flapping, so anchor the trace with who we are and where we run.
        write("────── session start | \(Bundle.main.bundleIdentifier ?? "nil-bundle-id") "
              + "v\(AppInfo.versionString) | \(Bundle.main.bundlePath)")

        // The report says the toggle flips when focus leaves Sealshot — log
        // the SMAppService status at every app activation boundary so the
        // trace shows whether the OS status changed there or the UI merely
        // re-read a status that had already changed.
        let center = NotificationCenter.default
        for (name, tag) in [(NSApplication.didBecomeActiveNotification, "didBecomeActive"),
                            (NSApplication.didResignActiveNotification, "didResignActive")] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                let status = SMAppService.mainApp.status
                Self.shared.recordObservation(status, context: tag, always: true)
            })
        }
    }

    private func recordObservation(_ status: SMAppService.Status, context: String,
                                   always: Bool = false) {
        let now = Date()
        lock.lock()
        let previous = lastObserved
        lastObserved = status
        let changed = previous != nil && previous != status

        // A repeat of the same (context, status) within a second is a render
        // burst: count it instead of writing a line. Anything else reports
        // how many were suppressed, then logs normally.
        let isRepeat = !changed && !always
            && pendingContext == context && pendingStatus == status
            && now.timeIntervalSince(pendingSince) <= 1
        var line: String?
        if isRepeat {
            pendingCount += 1
        } else {
            let suppressed = pendingCount
            pendingContext = context; pendingStatus = status
            pendingSince = now; pendingCount = 0
            line = "\(context): status=\(Self.statusName(status))"
                + (changed ? " (was \(Self.statusName(previous!)))" : "")
                + (suppressed > 0 ? " [+\(suppressed) suppressed repeats]" : "")
        }
        lock.unlock()

        if let line { write(line) }
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
