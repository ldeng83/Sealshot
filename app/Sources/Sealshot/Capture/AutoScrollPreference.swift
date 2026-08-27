import Foundation

/// Whether scrolling capture drives the page itself (auto) or the user
/// scrolls (manual). Settings toggle; defaults to auto. Auto additionally
/// requires the Accessibility grant and a non-sandboxed build — this is the
/// user's *intent*, gated elsewhere by capability.
enum AutoScrollPreference {

    /// Internal so the Settings toggle can bind `@AppStorage` to the same key.
    static let key = "scrollCaptureAutoScroll"

    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }

    static func set(_ enabled: Bool, into defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: key)
    }
}
