import Foundation

/// The descriptive head of a capture name: the app first, then the cleaned
/// window/tab title when one exists ("Google Chrome - Stripe Dashboard"),
/// else whichever part exists, else "Screenshot". Pure; shared by the
/// filename builder and the rule-based generator's window-title path.
enum CaptureSubject {

    /// Strip a trailing " - App" / " — App" suffix and collapse whitespace.
    /// Returns nil when empty after cleaning.
    static func clean(_ windowTitle: String?) -> String? {
        guard var t = windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !t.isEmpty else { return nil }
        for sep in [" - ", " \u{2014} "] {
            if let r = t.range(of: sep, options: .backwards) {
                t = String(t[..<r.lowerBound])
            }
        }
        t = t.split(whereSeparator: { $0 == " " || $0 == "\n" }).joined(separator: " ")
        let trimmed = t.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// An app name to attribute a capture to, dropping Sealshot itself — a
    /// capture invoked from within Sealshot must never be named after Sealshot.
    static func nonSelfAppName(_ name: String?, bundleID: String?, ownBundleID: String?) -> String? {
        if let bundleID, bundleID == ownBundleID { return nil }
        return name
    }

    /// App first, then `" - "` + cleaned title when it exists and isn't just
    /// the app name again (some apps title windows with their own name).
    /// Capped to `maxLength` characters so a long tab title can't produce an
    /// absurd filename.
    static func subject(windowTitle: String?, appName: String?, maxLength: Int = 50) -> String {
        let app: String? = {
            let trimmed = appName?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false ? trimmed : nil
        }()
        let title = clean(windowTitle)
        let raw: String
        switch (app, title) {
        case let (.some(app), .some(title)) where title != app: raw = "\(app) - \(title)"
        case let (.some(app), _): raw = app
        case let (nil, .some(title)): raw = title
        case (nil, nil): raw = "Screenshot"
        }
        return raw.count > maxLength ? String(raw.prefix(maxLength)) : raw
    }
}
