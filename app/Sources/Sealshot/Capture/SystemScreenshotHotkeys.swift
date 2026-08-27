import Foundation

/// Whether macOS still owns ⌘⇧3 / ⌘⇧4 / ⌘⇧5.
///
/// The system's screenshot keys are symbolic hot keys, handled below the app
/// layer: while one is enabled, Sealshot never receives the event at all, so
/// a numbers-layout binding on that key is silently dead. There is no
/// supported way to take them over programmatically — the user disables them
/// in System Settings ▸ Keyboard ▸ Keyboard Shortcuts ▸ Screenshots — but
/// their state CAN be read, which turns three dead keys into a labelled
/// condition with a button instead of an app that looks broken.
///
/// Read-only by design. Writing com.apple.symbolichotkeys is possible and
/// tempting, and is exactly the kind of system-settings mutation this app has
/// no business doing behind the user's back.
enum SystemScreenshotHotkeys {
    /// AppleSymbolicHotKeys ids for the plain (file-saving) screenshot keys.
    /// 29/31, the ⌃-clipboard variants, don't collide with ⌘⇧-only bindings.
    ///   28 = ⌘⇧3 (full screen), 30 = ⌘⇧4 (selection), 184 = ⌘⇧5 (toolbar).
    static let fullScreenID = "28", selectionID = "30", toolbarID = "184"
    static let allIDs = [fullScreenID, selectionID, toolbarID]

    /// The ids still enabled, given the AppleSymbolicHotKeys dictionary.
    /// An id with no entry is ENABLED — the plist only records deviations
    /// from the defaults, and the defaults are on.
    static func enabledIDs(in hotkeys: [String: Any]) -> [String] {
        allIDs.filter { id in
            guard let entry = hotkeys[id] as? [String: Any],
                  let enabled = entry["enabled"] as? Bool else { return true }
            return enabled
        }
    }

    /// The system screenshot keys currently enabled on this Mac.
    static func enabledIDs() -> [String] {
        let dict = CFPreferencesCopyAppValue(
            "AppleSymbolicHotKeys" as CFString,
            "com.apple.symbolichotkeys" as CFString) as? [String: Any] ?? [:]
        return enabledIDs(in: dict)
    }

    /// True when any of ⌘⇧3/4/5 still belongs to macOS — the condition the
    /// numbers layout warns about.
    static var systemStillOwnsAny: Bool { !enabledIDs().isEmpty }
}
