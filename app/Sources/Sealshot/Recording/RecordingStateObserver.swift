import Foundation

/// Observes a `RecordingCoordinator`'s lifecycle so multiple UIs (the menu-bar
/// item, the floating HUD) can react to the same recording without competing
/// over a single callback.
@MainActor
protocol RecordingStateObserver: AnyObject {
    func recordingDidStart()
    func recordingDidStop()
    func recordingPausedChanged(_ paused: Bool)
}
