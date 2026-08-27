import Foundation

/// Single user toggle for the app's on-device AI features (capture tagging and
/// Smart Redaction augmentation). Defaults ON: everything runs on-device (no
/// privacy cost) and only does anything where the model is available — callers
/// still gate on `AIAvailability`.
struct AIFeaturePreference {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private enum Key { static let enabled = "ai.enabled" }

    var enabled: Bool {
        get { defaults.object(forKey: Key.enabled) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Key.enabled) }
    }
}
