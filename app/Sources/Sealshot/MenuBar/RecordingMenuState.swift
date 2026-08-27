import SwiftUI

/// Observable mirror of the recording lifecycle for SwiftUI menus (the main
/// menu bar's "Capture" menu). The AppKit status-item menu reads the
/// coordinator directly; SwiftUI `.commands` need a published source to
/// re-render when recording starts/stops/pauses. A shared singleton so the
/// `App` struct can observe it without threading it through init.
@MainActor
final class RecordingMenuState: ObservableObject, RecordingStateObserver {
    static let shared = RecordingMenuState()

    @Published private(set) var isRecording = false
    @Published private(set) var paused = false

    private init() {}

    func recordingDidStart() { isRecording = true; paused = false }
    func recordingDidStop() { isRecording = false; paused = false }
    func recordingPausedChanged(_ paused: Bool) { self.paused = paused }
}
