import Foundation

/// One-time gate for the first-launch welcome window (privacy tour,
/// shortcuts, Screen Recording walkthrough).
enum WelcomePreference {

    private static let key = "welcomeShown"

    static func hasShown(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key)
    }

    static func markShown(into defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: key)
    }

    /// Set the flag to an explicit value (used by the "don't show again" checkbox).
    static func setShown(_ value: Bool, into defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: key)
    }

    /// "Show the welcome tour at startup" — the inverse of the dismissal flag,
    /// so the Settings toggle and the welcome window's "don't show again"
    /// checkbox stay linked through the same stored value.
    static func tourEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        !hasShown(defaults)
    }

    static func setTourEnabled(_ enabled: Bool, into defaults: UserDefaults = .standard) {
        setShown(!enabled, into: defaults)
    }
}
