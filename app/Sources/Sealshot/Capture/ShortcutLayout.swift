import KeyboardShortcuts

/// The two shortcut layouts a user can toggle between in Settings ▸ Shortcuts.
///
/// `letters` is Sealshot's shipped scheme: ⌘⇧ + a mnemonic letter per action.
/// `numbers` mirrors the macOS screenshot row and extends it — ⌘⇧3 full
/// screen and ⌘⇧4 area mean exactly what the system keys mean, recording sits
/// on ⌘⇧5 where the system's recording toolbar lives, and the remaining
/// actions fill out the row the way CleanShot users already expect (previous
/// area on 6, scrolling on 7, timer on 8).
///
/// A layout is a TABLE, not a mode: choosing one simply writes each binding
/// through the same persistence a hand-edited shortcut uses, so individual
/// keys can still be customized afterwards — the picker then shows neither
/// layout as selected. Only the capture/recording row participates; the app
/// shortcuts (editor, Library, lock…) mean the same thing in both layouts and
/// keep their keys.
enum ShortcutLayout: String, CaseIterable {
    case letters, numbers

    var title: String {
        switch self {
        case .letters: return "Letters"
        case .numbers: return "System numbers"
        }
    }

    /// Every name a layout governs. One list for both layouts — a name bound
    /// in one but forgotten in the other would keep its previous binding
    /// across a switch and quietly corrupt the layout it lands in.
    static let governedNames: [KeyboardShortcuts.Name] = [
        .captureUnified, .captureFullscreen, .captureDelayed, .captureScroll,
        .captureRepeat, .captureLive, .captureSaveAs,
        .recordToggle, .recordSelection, .newFromClipboard,
    ]

    var bindings: [KeyboardShortcuts.Name: KeyboardShortcuts.Shortcut] {
        switch self {
        case .letters:
            // The shipped defaults, spelled out rather than read from
            // `defaultShortcut` so a future default change is a CONSCIOUS
            // edit here too — the layouts test pins the two in agreement.
            return [
                .captureUnified: .init(.c, modifiers: [.command, .shift]),
                .captureFullscreen: .init(.f, modifiers: [.command, .shift]),
                .captureDelayed: .init(.d, modifiers: [.command, .shift]),
                .captureScroll: .init(.w, modifiers: [.command, .shift]),
                .captureRepeat: .init(.a, modifiers: [.command, .shift]),
                .captureLive: .init(.x, modifiers: [.command, .shift]),
                .captureSaveAs: .init(.s, modifiers: [.command, .shift]),
                .recordToggle: .init(.v, modifiers: [.command, .shift]),
                .recordSelection: .init(.r, modifiers: [.command, .shift]),
                .newFromClipboard: .init(.q, modifiers: [.command, .shift]),
            ]
        case .numbers:
            // 3/4/5 carry their system meanings; 6–0 then 1–2 extend the row.
            // ⌘⇧2 for New-from-Clipboard retires ⌘⇧Q, which shadows the macOS
            // Log Out shortcut — a long-accepted trade-off the letters layout
            // still makes.
            return [
                .captureFullscreen: .init(.three, modifiers: [.command, .shift]),
                .captureUnified: .init(.four, modifiers: [.command, .shift]),
                .recordToggle: .init(.five, modifiers: [.command, .shift]),
                .captureRepeat: .init(.six, modifiers: [.command, .shift]),
                .captureScroll: .init(.seven, modifiers: [.command, .shift]),
                .captureDelayed: .init(.eight, modifiers: [.command, .shift]),
                .recordSelection: .init(.nine, modifiers: [.command, .shift]),
                .captureLive: .init(.zero, modifiers: [.command, .shift]),
                .captureSaveAs: .init(.one, modifiers: [.command, .shift]),
                .newFromClipboard: .init(.two, modifiers: [.command, .shift]),
            ]
        }
    }

    /// Write this layout's bindings. `set` is injected so tests exercise the
    /// logic against a dictionary instead of the login session's real
    /// shortcuts — the test host shares the app's UserDefaults, so calling
    /// KeyboardShortcuts.setShortcut from a test would rebind the USER's keys.
    func apply(set: (KeyboardShortcuts.Shortcut?, KeyboardShortcuts.Name) -> Void
                = KeyboardShortcuts.setShortcut) {
        for (name, shortcut) in bindings { set(shortcut, name) }
    }

    /// The layout the current bindings exactly match, or nil when the user has
    /// customized any governed key — the Settings picker then selects neither.
    static func current(get: (KeyboardShortcuts.Name) -> KeyboardShortcuts.Shortcut?
                          = KeyboardShortcuts.getShortcut) -> ShortcutLayout? {
        allCases.first { layout in
            let table = layout.bindings
            return governedNames.allSatisfy { get($0) == table[$0] }
        }
    }
}
