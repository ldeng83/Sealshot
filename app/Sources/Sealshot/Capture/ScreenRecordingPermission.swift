import AppKit
import Observation
import ScreenCaptureKit
import os.log

private let log = OSLog(subsystem: "com.seal-shot.sealshot", category: "permission")

enum ScreenRecordingPermissionStatus: Equatable {
    case notDetermined
    case granted
    case denied
}

@MainActor
@Observable
final class ScreenRecordingPermission {
    private(set) var status: ScreenRecordingPermissionStatus

    init() {
        // CGPreflightScreenCaptureAccess() can't distinguish notDetermined from denied;
        // it just returns whether access is currently granted. We resolve denied vs
        // notDetermined ourselves once request() is called.
        status = CGPreflightScreenCaptureAccess() ? .granted : .notDetermined
    }

    func refresh() {
        let granted = CGPreflightScreenCaptureAccess()
        if granted {
            status = .granted
        } else if status == .granted {
            // Was granted before, now revoked — treat as denied.
            status = .denied
        }
        // If status was .notDetermined or .denied and still not granted, leave it.
    }

    /// LIVE functional check: CGPreflightScreenCaptureAccess can serve a
    /// stale, cached verdict to a running process across TCC changes —
    /// reporting granted after a revocation, which sends the capture into a
    /// session that fails silently. Asking ScreenCaptureKit for shareable
    /// content reflects exactly what a capture would do right now.
    static func liveGranted() async -> Bool {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
            return true
        } catch {
            return false
        }
    }

    /// Triggers the system prompt (first time) or no-ops (subsequent denials).
    @discardableResult
    func request() -> Bool {
        let granted = CGRequestScreenCaptureAccess()
        status = granted ? .granted : .denied
        os_log("Screen Recording request → %{public}@", log: log, type: .info, granted ? "granted" : "denied")
        return granted
    }

    /// Opens System Settings → Privacy & Security → Screen Recording.
    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
