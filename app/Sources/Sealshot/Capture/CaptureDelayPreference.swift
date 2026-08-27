import Foundation

/// The user's chosen delayed-capture countdown length, persisted across
/// launches. Only the offered durations are valid; anything else (unset or a
/// stale/hand-edited value) reads back as the default. Pure + `UserDefaults`.
enum CaptureDelayPreference {

    /// Countdown lengths offered in the toolbar chooser, in seconds.
    static let durations = [3, 5, 10, 15]
    static let defaultDuration = 3

    private static let key = "captureDelaySeconds"

    /// The persisted duration, validated to one of `durations`.
    static func current(_ defaults: UserDefaults = .standard) -> Int {
        guard let stored = defaults.object(forKey: key) as? Int,
              durations.contains(stored) else { return defaultDuration }
        return stored
    }

    /// Persist a duration. Values outside `durations` fall back to the default.
    static func set(_ seconds: Int, into defaults: UserDefaults = .standard) {
        defaults.set(durations.contains(seconds) ? seconds : defaultDuration, forKey: key)
    }
}
