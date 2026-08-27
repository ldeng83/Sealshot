import KeyboardShortcuts

/// The parts of the first-launch tour that must not be written by hand.
///
/// Shortcut chips used to be literal strings in `WelcomeView`, which drifted:
/// the tour taught ⌘⇧L for scrolling capture long after that combo became
/// "Lock now" and scrolling capture moved to ⌘⇧W. Reading the live binding
/// means the tour also shows the user's OWN keys when they rebind one.
enum WelcomeTourCopy {

    /// Modifier glyphs render as their own chip; whatever follows is the key,
    /// which may be several characters ("Space", "Return") and stays one chip.
    private static let modifierGlyphs: Set<Character> = ["⌃", "⌥", "⇧", "⌘"]

    static func chips(for display: String) -> [String] {
        var chips: [String] = []
        var rest = Substring(display)
        while let first = rest.first, modifierGlyphs.contains(first) {
            chips.append(String(first))
            rest = rest.dropFirst()
        }
        if !rest.isEmpty { chips.append(String(rest)) }
        return chips
    }

    /// `Name.shortcut` reads UserDefaults, which the `Name` initializer seeds
    /// from the default — but fall back explicitly so a name that has never
    /// been registered still renders instead of showing an empty row.
    @MainActor
    static func shortcutChips(for name: KeyboardShortcuts.Name) -> [String] {
        guard let shortcut = name.shortcut ?? name.defaultShortcut else { return [] }
        return chips(for: shortcut.description)
    }

    /// Every shortcut the tour promises. Tested as a set so a card can't
    /// advertise a name that has no combo behind it.
    static let advertisedShortcuts: [KeyboardShortcuts.Name] = [
        .captureUnified, .captureDelayed, .captureScroll, .captureLive,
        .recordToggle, .recordSelection,
    ]

    // MARK: - How it's paid for (Direct edition only)

    /// Only the direct build is free: a Mac App Store copy was already bought,
    /// and telling that buyer the app is free would be a strange greeting.
    static func showsFreeUseRow(edition: AppEdition = AppInfo.edition) -> Bool {
        edition == .direct
    }

    static let freeUseTitle = "Free to use"

    static let freeUseDetail =
        "Every feature is unlocked and nothing expires. Donations fund the "
        + "work — Sealshot will ask, occasionally, and never insist."
}
