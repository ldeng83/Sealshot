/// Web rendering engine behind a browser bundle ID. Drives which scroll-capture
/// strategy applies: `.chromium`/`.webkit` can be driven via `do JavaScript`;
/// `.gecko`/`.notBrowser` use the existing AX/CGEvent path.
enum BrowserEngine: Equatable {
    case chromium
    case webkit
    case gecko
    case notBrowser
}

/// Single source of truth mapping a window's owning bundle ID to its engine.
enum BrowserIdentifier {
    /// Chromium-family prefixes (Chrome + channels, Edge, Brave, Arc, Opera, Vivaldi).
    private static let chromiumPrefixes = [
        "com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser",
        "company.thebrowser", "com.operasoftware", "com.vivaldi", "com.kagi", "com.duckduckgo",
    ]
    /// WebKit-family prefixes (Safari + Technology Preview).
    private static let webkitPrefixes = ["com.apple.Safari"]
    /// Gecko (Firefox + forks under org.mozilla).
    private static let geckoPrefixes = ["org.mozilla"]

    static func engine(for bundleID: String?) -> BrowserEngine {
        guard let bundleID else { return .notBrowser }
        if chromiumPrefixes.contains(where: bundleID.hasPrefix) { return .chromium }
        if webkitPrefixes.contains(where: bundleID.hasPrefix) { return .webkit }
        if geckoPrefixes.contains(where: bundleID.hasPrefix) { return .gecko }
        return .notBrowser
    }

    static func isBrowser(_ bundleID: String?) -> Bool {
        engine(for: bundleID) != .notBrowser
    }
}
