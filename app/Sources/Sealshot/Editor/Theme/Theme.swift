import AppKit

/// Centralized visual tokens for the editor's theme. Colors use
/// `NSColor(name:dynamicProvider:)` so they automatically flip in
/// dark mode without per-call-site `appearance` checks.
enum Theme {

    // MARK: - Colors

    /// Window backdrop / canvas-area background — warm light gray in
    /// light mode, soft dark gray in dark mode.
    static let backdropColor = NSColor(name: "SealshotBackdrop") { appearance in
        if isDark(appearance) {
            return NSColor(srgbRed: 42/255, green: 41/255, blue: 43/255, alpha: 1.0)
        } else {
            return NSColor(srgbRed: 244/255, green: 241/255, blue: 244/255, alpha: 1.0)
        }
    }

    /// Color of the faint hex grid drawn on top of `backdropColor`.
    /// Use the alpha to keep the pattern at ~30% strength.
    static let hexPatternColor = NSColor(name: "SealshotHexPattern") { appearance in
        if isDark(appearance) {
            return NSColor(srgbRed: 58/255, green: 57/255, blue: 59/255, alpha: 0.3)
        } else {
            return NSColor(srgbRed: 232/255, green: 229/255, blue: 232/255, alpha: 0.3)
        }
    }

    /// Pure white in light mode, near-black in dark mode. Used for
    /// sidebar / meta-row / thumbnail cards.
    static let surfaceColor = NSColor(name: "SealshotSurface") { appearance in
        if isDark(appearance) {
            return NSColor(srgbRed: 31/255, green: 30/255, blue: 32/255, alpha: 1.0)
        } else {
            return NSColor.white
        }
    }

    /// Library **list view** table background — a soft ~95%-lightness gray in
    /// light mode, a darker mirror in dark mode. Softer than `surfaceColor`
    /// (pure white); sits behind the list rows + sticky column header so they
    /// read as a solid table instead of the hex backdrop showing through.
    static let listTableColor = NSColor(name: "SealshotListTable") { appearance in
        if isDark(appearance) {
            return NSColor(srgbRed: 50/255, green: 49/255, blue: 51/255, alpha: 1.0)
        } else {
            return NSColor(srgbRed: 242/255, green: 240/255, blue: 242/255, alpha: 1.0)
        }
    }

    /// 1pt hairline border color separating surfaces from the backdrop.
    static let surfaceBorderColor = NSColor(name: "SealshotSurfaceBorder") { appearance in
        if isDark(appearance) {
            return NSColor(srgbRed: 58/255, green: 57/255, blue: 59/255, alpha: 1.0)
        } else {
            return NSColor(srgbRed: 229/255, green: 226/255, blue: 229/255, alpha: 1.0)
        }
    }

    /// Brand accent color — defers to user's system accent (Settings →
    /// Appearance → Accent color).
    static let accentColor = NSColor.controlAccentColor

    // MARK: - Fonts

    /// "DIMENSIONS", "FILE INFO" — 10pt medium, applied to a string
    /// uppercased by the caller. Use `Theme.sectionHeaderKern` for the
    /// `.kern` attribute.
    static let sectionHeaderFont = NSFont.systemFont(ofSize: 10, weight: .medium)
    static let sectionHeaderKern: CGFloat = 1.2

    /// Field labels ("Width", "Format") — 11pt regular.
    static let labelFont = NSFont.systemFont(ofSize: 11, weight: .regular)

    /// Field values ("1920 px", "PNG") — 12pt medium.
    static let valueFont = NSFont.systemFont(ofSize: 12, weight: .medium)

    /// Sidebar header ("Properties") — 14pt semibold.
    static let panelTitleFont = NSFont.systemFont(ofSize: 14, weight: .semibold)

    // MARK: - Private

    private static func isDark(_ appearance: NSAppearance) -> Bool {
        let match = appearance.bestMatch(from: [
            .aqua,
            .darkAqua,
            .vibrantDark,
            .vibrantLight,
            .accessibilityHighContrastAqua,
            .accessibilityHighContrastDarkAqua,
        ])
        return match == .darkAqua
            || match == .vibrantDark
            || match == .accessibilityHighContrastDarkAqua
    }
}
