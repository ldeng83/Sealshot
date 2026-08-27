import AVFoundation
import AppKit

/// Permission needs for a recording config, plus a microphone authorization
/// wrapper. Screen Recording reuses `ScreenRecordingPermission`.
enum RecordingPermission {
    enum Need: Hashable { case screenRecording, microphone }

    static func required(micEnabled: Bool) -> [Need] {
        micEnabled ? [.screenRecording, .microphone] : [.screenRecording]
    }

    static var microphoneAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Prompts for mic access (no-op if already decided). Completion on main.
    static func requestMicrophone(_ done: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { done(granted) }
        }
    }

    /// Step the microphone grant forward from a permission-row Enable click:
    /// prompt when the user hasn't decided yet, otherwise open System Settings
    /// (a denied state never re-prompts).
    static func enableMicrophone() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            requestMicrophone { _ in }
        default:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
