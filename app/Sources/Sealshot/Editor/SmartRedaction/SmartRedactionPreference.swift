import Foundation

/// Whether the editor scans every newly opened image for sensitive content
/// automatically (the Smart Redact button always works regardless). Off by
/// default — a scan inspects the whole image, and surfacing a review panel
/// unasked would be noisy for users who never share screenshots.
enum SmartRedactionPreference {
    private static let autoScanKey = "smartRedactionAutoScan"

    static func autoScanEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: autoScanKey)
    }

    static func setAutoScan(_ enabled: Bool, into defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: autoScanKey)
    }
}
