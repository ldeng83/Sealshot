import Foundation

/// Pure string building for the feedback email: subject, body template, and
/// the `mailto:` fallback URL. Everything here is deterministic and testable;
/// presentation (alerts, sharing services) lives in `FeedbackComposer`.
enum FeedbackBody {

    static let address = "feedback@seal-shot.com"

    static func subject(version: String = AppInfo.versionString,
                        edition: String = AppInfo.edition.label) -> String {
        "Sealshot \(version) \(edition) — Feedback"
    }

    /// The user types above the divider; environment facts sit below it.
    static func body(version: String = AppInfo.versionString,
                     edition: String = AppInfo.edition.label,
                     osVersion: String = ProcessInfo.processInfo.operatingSystemVersionString,
                     arch: String = currentArchitecture()) -> String {
        """


        (Describe your feedback above this line)
        ---
        Sealshot \(version) — \(edition) edition
        macOS \(osVersion) — \(arch)
        ---
        """
    }

    /// `mailto:` URL with percent-encoded subject/body query items.
    static func mailtoURL(to address: String = FeedbackBody.address,
                          subject: String,
                          body: String) -> URL? {
        var comps = URLComponents()
        comps.scheme = "mailto"
        comps.path = address
        comps.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body),
        ]
        return comps.url
    }

    /// Hardware architecture ("arm64" / "x86_64") via utsname.
    static func currentArchitecture() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
    }
}
