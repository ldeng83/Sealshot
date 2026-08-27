import Foundation

/// UserDefaults-backed recording settings. Mirrors the pattern of the other
/// `*Preference` types in the app.
struct RecordingPreference {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private enum Key {
        static let format = "recording.format"
        static let fps = "recording.frameRate"
        static let sysAudio = "recording.systemAudio"
        static let mic = "recording.microphone"
        static let cursor = "recording.showsCursor"
        static let countdown = "recording.countdownSeconds"
        static let reduceMicNoise = "recording.reduceMicNoise"
        static let askBefore = "recording.askBeforeRecording"
    }

    var format: RecordingFormat {
        get { defaults.string(forKey: Key.format).flatMap(RecordingFormat.init) ?? .hevcMov }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Key.format) }
    }
    var frameRate: Int {
        get { defaults.object(forKey: Key.fps) as? Int ?? 30 }
        nonmutating set { defaults.set(newValue, forKey: Key.fps) }
    }
    var capturesSystemAudio: Bool {
        get { defaults.object(forKey: Key.sysAudio) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Key.sysAudio) }
    }
    var capturesMicrophone: Bool {
        get { defaults.bool(forKey: Key.mic) }   // default false
        nonmutating set { defaults.set(newValue, forKey: Key.mic) }
    }
    var showsCursor: Bool {
        get { defaults.object(forKey: Key.cursor) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Key.cursor) }
    }
    var countdownSeconds: Int {
        // Default to a 3-second pre-roll so the user can get the screen ready
        // (and the editor finishes hiding) before recording starts.
        get { defaults.object(forKey: Key.countdown) as? Int ?? 3 }
        nonmutating set { defaults.set(newValue, forKey: Key.countdown) }
    }
    var reducesMicNoise: Bool {
        get { defaults.object(forKey: Key.reduceMicNoise) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Key.reduceMicNoise) }
    }
    /// Whether to show the settings confirmation prompt before each recording.
    var asksBeforeRecording: Bool {
        get { defaults.object(forKey: Key.askBefore) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Key.askBefore) }
    }
}
