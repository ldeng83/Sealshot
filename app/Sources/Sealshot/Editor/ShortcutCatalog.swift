import KeyboardShortcuts

/// Every user-facing shortcut row, in Settings-tab order — the single source
/// the in-app duplicate check scans. The KeyboardShortcuts recorder already
/// rejects combos taken by macOS or by Sealshot's main menu; combos taken by
/// ANOTHER ROW here are the class it doesn't see (both handlers would fire on
/// one keystroke), so the Settings tab enforces it via `conflictingTitle`.
enum ShortcutCatalog {
    static let all: [(name: KeyboardShortcuts.Name, title: String)] = [
        (.captureUnified, "Unified capture"),
        (.captureDelayed, "Delayed capture"),
        (.captureScroll, "Scrolling capture"),
        (.captureRepeat, "Repeat last capture"),
        (.captureFullscreen, "Capture fullscreen"),
        (.captureLive, "Live capture"),
        (.captureSaveAs, "Save-as capture"),
        (.recordToggle, "Toggle recording"),
        (.recordSelection, "Record selection"),
        (.recordPause, "Pause/resume recording"),
        (.openEditor, "Open editor"),
        (.openLibrary, "Open Library"),
        (.newFromClipboard, "New from clipboard"),
        (.lockNow, "Lock now"),
    ]

    /// The title of the OTHER row already holding `shortcut`, or nil when the
    /// combo is free. `current` is injectable for tests; production reads the
    /// live KeyboardShortcuts store.
    static func conflictingTitle(
        for shortcut: KeyboardShortcuts.Shortcut,
        excluding name: KeyboardShortcuts.Name,
        current: (KeyboardShortcuts.Name) -> KeyboardShortcuts.Shortcut? = {
            KeyboardShortcuts.getShortcut(for: $0)
        }
    ) -> String? {
        all.first { $0.name != name && current($0.name) == shortcut }?.title
    }
}
