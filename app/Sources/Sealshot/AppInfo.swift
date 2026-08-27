import Foundation

enum AppEdition {
    case mas
    case direct

    static var current: AppEdition {
        let id = Bundle.main.bundleIdentifier ?? ""
        return id.hasSuffix(".direct") ? .direct : .mas
    }

    var label: String {
        switch self {
        case .mas: return "Mac App Store"
        case .direct: return "Direct"
        }
    }
}

enum AppInfo {
    static var edition: AppEdition { AppEdition.current }

    static var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    /// UTC day this build was released, stamped into Info.plist by
    /// scripts/release.sh (SEALSHOT_RELEASE_DATE → SealshotReleaseDate).
    /// nil for dev/MAS builds (empty or missing key) — callers fail open.
    static var releaseDate: Date? {
        guard let s = Bundle.main.infoDictionary?["SealshotReleaseDate"] as? String else {
            return nil
        }
        return UTCDay.parse(s)
    }
}
