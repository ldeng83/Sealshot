import AppKit

/// Opens System Settings at the Apple Intelligence pane.
///
/// The URL is a private System Settings scheme and is not API — it can change
/// between macOS releases.
enum AISystemSettingsLink {

    /// Apple Intelligence & Siri pane (macOS 26).
    private static let url = URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")!

    /// Whether *something* on this Mac claims the `x-apple.systempreferences`
    /// URL scheme — NOT whether `com.apple.Siri-Settings.extension` is a real,
    /// current pane identifier. `NSWorkspace.urlForApplication(toOpen:)`
    /// resolves the scheme handler (System Settings.app), and it will return
    /// true for that handler regardless of whether the pane id after the
    /// colon exists, so this cannot detect a bogus or renamed pane id. Because
    /// of that, callers must not treat `canOpen == true` as proof the button
    /// will land anywhere useful — the guidance copy names the pane in text
    /// as well, so the user can always get there by hand.
    static var canOpen: Bool {
        NSWorkspace.shared.urlForApplication(toOpen: url) != nil
    }

    @discardableResult
    static func open() -> Bool {
        NSWorkspace.shared.open(url)
    }
}
