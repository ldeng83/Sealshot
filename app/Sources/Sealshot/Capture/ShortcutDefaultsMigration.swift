import KeyboardShortcuts

/// One-time repair when a SHIPPED DEFAULT keybinding changes.
///
/// The KeyboardShortcuts library persists each name's default into
/// UserDefaults on first registration, so a changed code default never
/// reaches an existing install — and can silently collide with the combo's
/// new owner (captureScroll kept its persisted ⌘⇧L while lockNow started
/// defaulting to ⌘⇧L: one keystroke fired both, and scroll capture's
/// permission preflight popped its checklist over the lock).
///
/// Rule: a stored value still equal to the OLD default is just the persisted
/// default → move it to the new one. Anything else is a user customization →
/// left alone. Idempotent (after moving, the guard no longer matches).
enum ShortcutDefaultsMigration {
    static func run() {
        // 2026-07-03: scrolling capture ⌘⇧L → ⌘⇧W (L now means Lock now).
        migrate(.captureScroll,
                from: .init(.l, modifiers: [.command, .shift]),
                to: .init(.w, modifiers: [.command, .shift]))
        // 2026-08-19: repeat-last-area ⌘⌥A → ⌘⇧A, so every capture shortcut
        // shares one modifier pair. Only ever shipped in a dev build, but the
        // rule is the same: the persisted value wins over the code default
        // until it is moved.
        migrate(.captureRepeat,
                from: .init(.a, modifiers: [.command, .option]),
                to: .init(.a, modifiers: [.command, .shift]))
        // ...and free the combo it is moving onto. `captureRegion` still holds
        // ⌘⇧A in every existing install, left over from when the region
        // overlay had its own shortcut. Nothing registers a handler for it, so
        // it fires nothing today — but a stored binding that duplicates a live
        // one is a trap for whoever re-registers that name later.
        if KeyboardShortcuts.getShortcut(for: .captureRegion)
            == .init(.a, modifiers: [.command, .shift]) {
            // `reset` would put the default BACK — the default is the very
            // combo being freed. Clearing means clearing.
            KeyboardShortcuts.setShortcut(nil, for: .captureRegion)
        }
    }

    private static func migrate(_ name: KeyboardShortcuts.Name,
                                from old: KeyboardShortcuts.Shortcut,
                                to new: KeyboardShortcuts.Shortcut) {
        guard KeyboardShortcuts.getShortcut(for: name) == old else { return }
        KeyboardShortcuts.setShortcut(new, for: name)
    }
}
