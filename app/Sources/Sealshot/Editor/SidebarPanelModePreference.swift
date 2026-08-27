import Foundation

/// Persistence for which stable mode the editor's right sidebar opens in
/// (Properties vs Info). Find in Image is transient and is never restored.
/// A thin `UserDefaults` wrapper mirroring
/// `SidebarWidthPreference`. Defaults to `.properties` — a fresh install opens
/// the sidebar on tool properties, not file info.
enum SidebarPanelModePreference {

    private static let key = "sidebarPanelMode"

    /// Persisted mode, falling back to `.properties` when nothing is stored or
    /// the stored value is unrecognized.
    static func load(_ defaults: UserDefaults = .standard) -> SidebarPanelMode {
        guard let raw = defaults.string(forKey: key),
              let mode = SidebarPanelMode(rawValue: raw),
              !mode.isImageTextSearch else { return .properties }
        return mode
    }

    /// Persist the mode.
    static func store(_ mode: SidebarPanelMode, into defaults: UserDefaults = .standard) {
        defaults.set(mode.isImageTextSearch ? SidebarPanelMode.properties.rawValue : mode.rawValue,
                     forKey: key)
    }
}
