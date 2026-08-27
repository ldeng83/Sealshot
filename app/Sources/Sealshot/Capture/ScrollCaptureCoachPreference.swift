import Foundation

/// One-time gate for the scrolling-capture coach card: the card explains the
/// flow (select → auto-scroll → ⏎ finish / takeover) the first time the user
/// triggers ⌘⇧L, then never again.
enum ScrollCaptureCoachPreference {

    private static let key = "scrollCaptureCoachShown"

    static func hasShown(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key)
    }

    static func markShown(into defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: key)
    }
}
