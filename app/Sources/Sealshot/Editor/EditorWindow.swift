import AppKit

/// Standard titled NSWindow for the editor. Customizations:
///
/// - `performKeyEquivalent` handles the editor keyboard shortcuts (export,
///   select-all, copy, cut, paste, undo/redo, zoom, delete) directly, so they
///   work regardless of where focus sits in the editor.
/// - The standard Edit-menu action methods (`undo:`/`redo:`/`cut:`/`copy:`/
///   `paste:`/`selectAll:`/`delete:`) are answered here and routed to the same
///   closures, so the app's Edit menu items (SwiftUI's default, dispatched via
///   the responder chain) are enabled and functional, not just the shortcuts.
///   When a chrome text field is focused, its field editor is earlier in the
///   responder chain and handles its own editing, so these only fire for the
///   canvas.
///
/// `⌘W` is handled by AppKit's default behavior (closes the window).
final class EditorWindow: NSWindow {

    var onExport: (() -> Void)?
    var onSelectAll: (() -> Void)?
    var onCopy: (() -> Void)?
    var onCut: (() -> Bool)?
    /// ⌘↩ — soft crop when a crop selection is active. Returns true if handled.
    var onSoftCrop: (() -> Bool)?
    var onPaste: (() -> Bool)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    /// ⌘F — enter/focus Find in Image while the Editor tab is active.
    var onFindInImage: (() -> Bool)?
    /// Edit→Delete: remove the selected annotation objects. Distinct from
    /// `onDeleteCurrent` (⌘⌫), which deletes the whole capture file.
    var onDeleteSelection: (() -> Void)?
    /// ⌘D — duplicate the selected annotation objects. Returns true if handled.
    var onDuplicateSelection: (() -> Bool)?

    /// Availability predicates for the Edit-menu items, so each menu item
    /// reflects real state (matching the editor toolbar) rather than merely
    /// "a handler exists". Evaluated each time the menu opens. When a predicate
    /// is nil the item is enabled as long as its handler is set.
    var canUndo: (() -> Bool)?
    var canRedo: (() -> Bool)?
    var canCopy: (() -> Bool)?
    var canCut: (() -> Bool)?
    var canPaste: (() -> Bool)?
    var canSelectAll: (() -> Bool)?
    var canDeleteSelection: (() -> Bool)?
    var onZoomIn: (() -> Void)?
    var onZoomOut: (() -> Void)?
    var onZoomReset: (() -> Void)?
    var onExportPNG: (() -> Void)?
    var onDeleteCurrent: (() -> Void)?
    var onClearSelection: (() -> Bool)?
    var onToggleStrip: (() -> Void)?

    /// While a text box is being edited, the canvas consumes editor shortcuts
    /// (⌘Z/⌘A/⌘C/⌘X/⌘V, Esc) so they act on the text, not annotations. Returns
    /// true if it handled the event.
    var routeKeyWhileEditingText: ((NSEvent) -> Bool)?

    /// Plain (no-modifier) arrow keys for list navigation — the recent strip
    /// (Editor tab) and the Library grid/list. Passed the keyCode (123 left,
    /// 124 right, 125 down, 126 up); the controller routes by active tab and
    /// returns true if it consumed the key.
    var onArrowKey: ((UInt16) -> Bool)?
    /// ⌘ + arrow — jump to the list extreme (recent strip: first/last tile;
    /// Library grid: row/column extreme). Same keyCodes as `onArrowKey`; the
    /// controller routes by active tab and returns true if it consumed the key.
    var onCommandArrowKey: ((UInt16) -> Bool)?
    /// ⌘]/⌘[/⌥⌘]/⌥⌘[ — depth reorder of the canvas selection. Returns true
    /// when consumed (canvas focused with a selection); false falls through
    /// so brackets keep working in text fields.
    var onReorder: ((ZOrderOperation) -> Bool)?

    /// Return/Enter with no modifiers — opens the highlighted Library item.
    /// Returns true if consumed.
    var onActivateSelection: (() -> Bool)?

    /// Space with no modifiers, not editing text — toggle Library Quick Look.
    var onSpaceKey: (() -> Bool)?
    /// Esc with no modifiers — close the Quick Look overlay if it's open. Checked
    /// BEFORE `onClearSelection` so Esc dismisses the preview before clearing.
    var onEscapePreview: (() -> Bool)?
    /// True while the Library Quick Look preview is open. When it is, the preview
    /// owns Space/arrows/Return even if focus has drifted into a text field —
    /// `AVPlayerView` (the video preview) bounces first responder to the search
    /// field, and without this the normal `!(firstResponder is NSText)` gate
    /// would swallow those keys and the preview couldn't be dismissed/navigated.
    var isQuickLookOpen: (() -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// A click that reaches the window (i.e. lands on empty chrome, not on a
    /// control) ends any in-progress text edit — clicking away from the canvas
    /// title or the info name field unfocuses and commits it.
    override func mouseDown(with event: NSEvent) {
        if firstResponder is NSText { _ = makeFirstResponder(nil) }
        super.mouseDown(with: event)
    }

    /// While the Library Quick Look preview is open, keep focus out of text
    /// fields. The video preview's `AVPlayerView` churns first responder and, on
    /// teardown during navigation, AppKit otherwise lands focus on the Library
    /// search field — stealing the caret / focus ring (and historically
    /// swallowing the preview's keys). Deny any text-field / field-editor
    /// first-responder change while the preview is up, resolving to the window
    /// instead; `AVPlayerView`'s own controls (not text) are unaffected.
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        if isQuickLookOpen?() == true, responder is NSText || responder is NSTextField {
            return super.makeFirstResponder(nil)
        }
        return super.makeFirstResponder(responder)
    }

    init(contentRect: NSRect, title: String) {
        super.init(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        self.title = title
        self.isReleasedWhenClosed = false
        // Floor so the editor (and the lock-screen overlay) can never collapse
        // to a sliver if it's ever created with a degenerate content rect.
        // 560 wide is reachable because the tool bar folds its clusters as the
        // window narrows (`EditorToolbarFit`); before that the bar's own
        // intrinsic width — over 1000pt — was the real minimum, and this
        // number never got a say.
        self.contentMinSize = NSSize(width: 560, height: 420)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if routeKeyWhileEditingText?(event) == true {
            return true
        }
        // Esc (keyCode 53) with no modifiers: ask the controller to clear
        // the strip's multi-selection. Returns true if it consumed; false
        // means no selection to clear → let the canvas's pending-crop Esc
        // handling run via the default chain.
        if event.keyCode == 53,
           event.modifierFlags.isDisjoint(with: [.command, .option, .control, .shift]) {
            if onEscapePreview?() == true { return true }
            if onClearSelection?() == true { return true }
        }
        // Plain arrow keys / Return / Space drive list navigation (recent strip,
        // Library) and the Quick Look preview. Skip while a text field is editing
        // — there the field editor (an NSText) owns the arrows for cursor
        // movement and Return — EXCEPT while the Quick Look preview is open, when
        // the preview owns these keys even if AVPlayerView bounced focus into the
        // search field (see `isQuickLookOpen`).
        if event.modifierFlags.isDisjoint(with: [.command, .option, .control, .shift]),
           !(firstResponder is NSText) || isQuickLookOpen?() == true {
            switch event.keyCode {
            case 123, 124, 125, 126:
                if onArrowKey?(event.keyCode) == true { return true }
            case 36, 76:   // Return, keypad Enter
                if onActivateSelection?() == true { return true }
            case 49:   // Space
                if onSpaceKey?() == true { return true }
            default:
                break
            }
        }

        // ⌘ + arrow: jump to the list extreme (strip: first/last tile; Library
        // grid: row/column extreme). Only plain ⌘ (no ⌥/⌃/⇧), and not while a
        // text field owns the arrows for line-start/end — unless Quick Look is up.
        if event.modifierFlags.intersection([.command, .option, .control, .shift]) == [.command],
           !(firstResponder is NSText) || isQuickLookOpen?() == true {
            switch event.keyCode {
            case 123, 124, 125, 126:
                if onCommandArrowKey?(event.keyCode) == true { return true }
            default:
                break
            }
        }

        guard event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        // Strip non-relevant modifiers; keep only command + shift + option for compare.
        let mods = event.modifierFlags.intersection([.command, .shift, .option])
        let chars = event.charactersIgnoringModifiers ?? ""

        // While a plain text field (canvas title / info name) is focused, its
        // field editor owns the standard editing shortcuts — select-all, copy,
        // cut, paste, undo/redo — so they act on the text, not the canvas/image.
        // (Canvas annotation text boxes are handled earlier by
        // `routeKeyWhileEditingText`, so this only catches the chrome fields.)
        if let text = firstResponder as? NSText {
            switch (chars.lowercased(), mods) {
            case ("a", [.command]): text.selectAll(nil); return true
            case ("c", [.command]): text.copy(nil); return true
            case ("x", [.command]): text.cut(nil); return true
            case ("v", [.command]): text.paste(nil); return true
            case ("z", [.command]): text.undoManager?.undo(); return true
            case ("z", [.command, .shift]): text.undoManager?.redo(); return true
            default: break
            }
        }

        switch (chars, mods) {
        case ("]", [.command]):
            if onReorder?(.forward) == true { return true }
            return super.performKeyEquivalent(with: event)
        case ("]", [.command, .option]):
            if onReorder?(.toFront) == true { return true }
            return super.performKeyEquivalent(with: event)
        case ("[", [.command]):
            if onReorder?(.backward) == true { return true }
            return super.performKeyEquivalent(with: event)
        case ("[", [.command, .option]):
            if onReorder?(.toBack) == true { return true }
            return super.performKeyEquivalent(with: event)
        case ("d", [.command]):
            if onDuplicateSelection?() == true { return true }
            return super.performKeyEquivalent(with: event)
        case ("s", [.command]):
            onExport?()
            return true
        case ("a", [.command]):
            onSelectAll?()
            return true
        case ("c", [.command]):
            onCopy?()
            return true
        case ("x", [.command]):
            if onCut?() == true { return true }
            return super.performKeyEquivalent(with: event)
        case ("v", [.command]):
            if onPaste?() == true { return true }
            return super.performKeyEquivalent(with: event)
        case ("z", [.command]):
            onUndo?()
            return true
        // ⌘⇧Z: AppKit reports the character as 'Z' (uppercase) when shift is
        // held — handle both forms defensively.
        case ("z", [.command, .shift]), ("Z", [.command, .shift]):
            onRedo?()
            return true
        case ("f", [.command]):
            if onFindInImage?() == true { return true }
            return super.performKeyEquivalent(with: event)
        case ("+", [.command]), ("=", [.command]):
            onZoomIn?()
            return true
        case ("-", [.command]):
            onZoomOut?()
            return true
        case ("0", [.command]):
            onZoomReset?()
            return true
        case ("e", [.command, .option]):
            onExportPNG?()
            return true
        case ("s", [.command, .option]):
            onToggleStrip?()
            return true
        case ("\u{7F}", [.command]):
            onDeleteCurrent?()
            return true
        // ⌘Return / ⌘Enter — soft crop when a crop selection is active.
        // Plain Return (no modifier) never reaches this switch (guard at line ~121
        // sends non-command events to super), so ⌘-only is matched here.
        case ("\r", [.command]), ("\u{3}", [.command]):
            if onSoftCrop?() == true { return true }
            return super.performKeyEquivalent(with: event)
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    // MARK: - Edit menu (responder-chain actions)
    //
    // The app's Edit menu fires these standard selectors down the responder
    // chain. Routing them to the editor closures keeps the menu items in lock
    // step with the keyboard shortcuts above. Text fields handle their own
    // editing earlier in the chain, so these fire only for the canvas.

    @objc func undo(_ sender: Any?) { onUndo?() }
    @objc func redo(_ sender: Any?) { onRedo?() }
    @objc func copy(_ sender: Any?) { onCopy?() }
    @objc func cut(_ sender: Any?) { _ = onCut?() }
    @objc func paste(_ sender: Any?) { _ = onPaste?() }
    @objc override func selectAll(_ sender: Any?) { onSelectAll?() }
    @objc func delete(_ sender: Any?) { onDeleteSelection?() }

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)):      return onUndo != nil && (canUndo?() ?? true)
        case #selector(redo(_:)):      return onRedo != nil && (canRedo?() ?? true)
        case #selector(copy(_:)):      return onCopy != nil && (canCopy?() ?? true)
        case #selector(cut(_:)):       return onCut != nil && (canCut?() ?? true)
        case #selector(paste(_:)):     return onPaste != nil && (canPaste?() ?? true)
        case #selector(selectAll(_:)): return onSelectAll != nil && (canSelectAll?() ?? true)
        case #selector(delete(_:)):    return onDeleteSelection != nil && (canDeleteSelection?() ?? true)
        default:                       return super.validateMenuItem(item)
        }
    }
}
