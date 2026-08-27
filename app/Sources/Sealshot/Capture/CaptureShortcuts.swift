import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    // NOTE: hidden (unregistered) — nothing has registered a handler for it
    // since the region overlay was folded into unified capture, and its old
    // ⌘⇧A default now belongs to repeat-last-area. No default here on purpose:
    // a shipped default on a dead name is a shortcut the app advertises (the
    // editor's Capture-region pill shows it in a tooltip) and then ignores.
    static let captureRegion = Self("captureRegion")
    // NOTE: hidden (unregistered) — its old ⌘⇧W default now belongs to
    // scrolling capture, so re-adding this row needs a fresh combo.
    static let captureWindow = Self(
        "captureWindow",
        default: .init(.w, modifiers: [.command, .shift])
    )
    static let captureFullscreen = Self(
        "captureFullscreen",
        default: .init(.f, modifiers: [.command, .shift])
    )
    /// Unified capture: one overlay where hovering highlights the window under
    /// the cursor (click to capture it) and dragging selects an area.
    static let captureUnified = Self(
        "captureUnified",
        default: .init(.c, modifiers: [.command, .shift])
    )
    static let captureSaveAs = Self(
        "captureSaveAs",
        default: .init(.s, modifiers: [.command, .shift])
    )

    /// Delayed unified capture: runs an on-screen countdown, then the unified
    /// overlay. Duration is `CaptureDelayPreference.current`.
    static let captureDelayed = Self(
        "captureDelayed",
        default: .init(.d, modifiers: [.command, .shift])
    )

    /// Scrolling capture: select a viewport, scroll it yourself, Sealshot
    /// stitches the frames into one tall image ("long" capture).
    /// ⌘⇧W (was ⌘⇧L, which now means Lock now).
    static let captureScroll = Self(
        "captureScroll",
        default: .init(.w, modifiers: [.command, .shift])
    )

    /// Bound to plain Return only while a scrolling-capture session records
    /// (set/cleared by `ScrollCaptureController`), mirroring `pickerCancel`.
    static let scrollCaptureFinish = Self("scrollCaptureFinish")

    /// Keypad-Enter twin of `scrollCaptureFinish` — a different key code, and
    /// one Name holds one shortcut, so the numeric keypad needs its own
    /// session-scoped binding. Set/cleared together with the main one.
    static let scrollCaptureFinishKeypad = Self("scrollCaptureFinishKeypad")

    /// Captures the last area again, with no overlay and no selection.
    ///
    /// ⌘⇧A, keeping every capture shortcut on one modifier pair. The combo
    /// looks taken — `captureRegion` above declares it — but that name has had
    /// no handler registered since the region overlay was folded into unified
    /// capture, so nothing has fired on ⌘⇧A for a long time. `A` for area is
    /// the mnemonic it always was; repeating one is now what it does.
    ///
    /// If `captureRegion` is ever re-registered, it needs a different combo,
    /// and its stale persisted binding needs the same migration treatment this
    /// one got — see `ShortcutDefaultsMigration`.
    static let captureRepeat = Self(
        "captureRepeat",
        default: .init(.a, modifiers: [.command, .shift])
    )

    /// Opens the editor directly with the most recent capture loaded —
    /// lets the user browse and edit past screenshots without taking a
    /// new one first.
    static let openEditor = Self(
        "openEditor",
        default: .init(.e, modifiers: [.command, .shift])
    )

    /// Bound to plain Esc only while a picker session is active. Lets the
    /// user cancel after Cmd+Tab to another app without first switching
    /// back to Sealshot. The binding is set in
    /// `WindowPickerController.startSession` and cleared in `complete`.
    static let pickerCancel = Self("pickerCancel")

    /// Opens the editor window on the Library tab — straight to browsing/
    /// organizing, without going through the last capture. B = Browse.
    static let openLibrary = Self(
        "openLibrary",
        default: .init(.b, modifiers: [.command, .shift])
    )

    /// Opens the clipboard image as a new canvas from anywhere — the source
    /// app is usually the focused one at that moment. NOTE: ⌘⇧Q shadows the
    /// macOS Log Out shortcut while Sealshot runs (accepted trade-off).
    static let newFromClipboard = Self(
        "newFromClipboard",
        default: .init(.q, modifiers: [.command, .shift])
    )

    /// Locks the Enhanced-Security session immediately (the "walking away
    /// from my desk" key). No-op while encryption is off or already locked.
    static let lockNow = Self(
        "lockNow",
        default: .init(.l, modifiers: [.command, .shift])
    )

    /// Live capture: grabs the current window layout as movable layers on one
    /// canvas. No default combo assigned yet.
    static let captureLive = Self(
        "captureLive",
        default: .init(.x, modifiers: [.command, .shift])
    )
}
