import Foundation
import KeyboardShortcuts

/// Remembers a binding set PER LAYOUT, so switching tabs restores what the user
/// left there rather than resetting to the layout's table.
///
/// A layout used to be a one-shot write: choosing one overwrote every governed
/// key, and any hand edit afterwards matched neither table, which is what the
/// third "Custom" segment existed to describe. Both consequences were wrong for
/// the way people actually use this — someone who moves two keys under System
/// numbers and glances at Letters should not lose the two keys, and should not
/// have to learn a third state to get back.
///
/// So the model is: the selection is STORED rather than inferred from the keys;
/// each layout owns its overrides on top of its table; an edit lands in the
/// selected layout; and Reset drops that layout's overrides. The picker then
/// always has exactly two answers, and neither of them destroys the other's.
///
/// Only `ShortcutLayout.governedNames` participate. The app shortcuts — editor,
/// Library, lock — mean the same thing in both layouts and are stored once by
/// KeyboardShortcuts itself, so recording them per layout would invent a
/// difference the user never asked for.
struct ShortcutLayoutStore {
    private let defaults: UserDefaults
    /// Injected so tests never touch the login session's real shortcuts: the
    /// test host shares the app's UserDefaults, so a stray write would rebind
    /// the USER's keys. Same reason `ShortcutLayout.apply(set:)` takes one.
    private let setShortcut: (KeyboardShortcuts.Shortcut?, KeyboardShortcuts.Name) -> Void
    private let getShortcut: (KeyboardShortcuts.Name) -> KeyboardShortcuts.Shortcut?

    init(defaults: UserDefaults = .standard,
         set: @escaping (KeyboardShortcuts.Shortcut?, KeyboardShortcuts.Name) -> Void
                = KeyboardShortcuts.setShortcut,
         get: @escaping (KeyboardShortcuts.Name) -> KeyboardShortcuts.Shortcut?
                = KeyboardShortcuts.getShortcut) {
        self.defaults = defaults
        self.setShortcut = set
        self.getShortcut = get
    }

    static let selectedKey = "shortcuts.layout.selected"
    static func overridesKey(_ layout: ShortcutLayout) -> String {
        "shortcuts.layout.\(layout.rawValue).overrides"
    }

    // MARK: Selection

    /// The layout the picker shows.
    ///
    /// Falls back to whichever layout the CURRENT bindings match, and only then
    /// to `.letters`: an install that predates this store has keys but no stored
    /// selection, and a user sitting on the numbers row should not be told they
    /// are on Letters.
    var selected: ShortcutLayout {
        if let raw = defaults.string(forKey: Self.selectedKey),
           let stored = ShortcutLayout(rawValue: raw) {
            return stored
        }
        return ShortcutLayout.current(get: getShortcut) ?? .letters
    }

    /// Switch layouts: remember the choice, then apply that layout's remembered
    /// bindings — its table with its own overrides on top.
    func select(_ layout: ShortcutLayout) {
        defaults.set(layout.rawValue, forKey: Self.selectedKey)
        apply(layout)
    }

    /// Write a layout's remembered bindings through to the live shortcuts.
    func apply(_ layout: ShortcutLayout) {
        for (name, shortcut) in bindings(for: layout) { setShortcut(shortcut, name) }
    }

    // MARK: Bindings

    /// What this layout should be showing: its table, with the user's edits for
    /// THIS layout applied over it. A key the user cleared is present with a nil
    /// value, so it stays cleared across a switch instead of springing back.
    func bindings(for layout: ShortcutLayout) -> [KeyboardShortcuts.Name: KeyboardShortcuts.Shortcut?] {
        var merged = layout.bindings.mapValues { Optional($0) }
        for (name, shortcut) in overrides(for: layout) { merged[name] = shortcut }
        return merged
    }

    /// Record an edit against the selected layout. Ungoverned names are ignored
    /// — they are the same in both layouts, so KeyboardShortcuts' own storage is
    /// the only copy that should exist.
    func record(_ shortcut: KeyboardShortcuts.Shortcut?, for name: KeyboardShortcuts.Name,
                in layout: ShortcutLayout? = nil) {
        let layout = layout ?? selected
        guard ShortcutLayout.governedNames.contains(name) else { return }
        var stored = overrides(for: layout)
        stored[name] = shortcut          // nil value, present key: deliberately cleared
        write(stored, for: layout)
    }

    // MARK: Reset

    /// Drop this layout's edits and put its table back. The SELECTION survives:
    /// the user asked for defaults, not for a different layout.
    func resetOverrides(for layout: ShortcutLayout) {
        defaults.removeObject(forKey: Self.overridesKey(layout))
        apply(layout)
    }

    /// Reset All: every layout back to its table, and the picker back to the
    /// shipped one.
    func resetEverything() {
        for layout in ShortcutLayout.allCases {
            defaults.removeObject(forKey: Self.overridesKey(layout))
        }
        defaults.removeObject(forKey: Self.selectedKey)
        apply(.letters)
    }

    // MARK: Storage

    /// `[name: shortcut?]` — a present key with a nil value means "cleared here",
    /// which is why this is not simply `[name: shortcut]`.
    private func overrides(for layout: ShortcutLayout)
        -> [KeyboardShortcuts.Name: KeyboardShortcuts.Shortcut?] {
        guard let data = defaults.data(forKey: Self.overridesKey(layout)),
              let raw = try? JSONDecoder().decode([String: KeyboardShortcuts.Shortcut?].self,
                                                  from: data)
        else { return [:] }
        var out: [KeyboardShortcuts.Name: KeyboardShortcuts.Shortcut?] = [:]
        for (key, shortcut) in raw {
            let name = KeyboardShortcuts.Name(.init(key))
            // Ignore names this layout no longer governs, so a renamed or
            // retired action cannot resurrect a binding nothing can reach.
            guard ShortcutLayout.governedNames.contains(name) else { continue }
            out[name] = shortcut
        }
        return out
    }

    private func write(_ overrides: [KeyboardShortcuts.Name: KeyboardShortcuts.Shortcut?],
                       for layout: ShortcutLayout) {
        var raw: [String: KeyboardShortcuts.Shortcut?] = [:]
        for (name, shortcut) in overrides { raw[name.rawValue] = shortcut }
        guard let data = try? JSONEncoder().encode(raw) else { return }
        defaults.set(data, forKey: Self.overridesKey(layout))
    }
}
