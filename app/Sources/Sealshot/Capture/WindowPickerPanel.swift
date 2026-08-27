import AppKit

final class WindowPickerPanel: NSPanel {
    /// `opaque` is for overlays whose content already covers the whole screen —
    /// the unified overlay's frozen backdrop does. A full-screen NON-opaque
    /// window makes the window server blend our surface with everything behind
    /// it on every refresh, which on a scaled Retina display means reblending
    /// 3360x2100 on integrated graphics. Measurement put 97% of the overlay's
    /// dropped refreshes outside our own code, with our work accounting for
    /// 0.39ms of a 16.7ms budget, so compositing is the remaining suspect.
    ///
    /// The window/display pickers must stay transparent: they overlay the LIVE
    /// screen and have nothing of their own behind the highlight.
    init(screen: NSScreen, opaque: Bool = false) {
        // `.nonactivatingPanel` is REQUIRED to overlay another app in native
        // full-screen mode: an activating panel gets bound to our own Space and
        // refuses to join the foreground full-screen Space, leaving the overlay
        // buried behind it. A non-activating palette floats onto whatever Space
        // is active. Esc/cancel come through the global `.pickerCancel` hotkey
        // and a local key-down monitor, so we don't depend on becoming key.
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        setFrame(screen.frame, display: false)
        // .screenSaver, not .statusBar: a native full-screen app lives in its
        // own Space and the WindowServer orders its window above ordinary
        // levels, so a .statusBar (25) overlay gets buried behind it. Match the
        // countdown/scroll overlays, which already float above full-screen apps.
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // Appear/disappear instantly: the default behavior fades the panel in,
        // and an alpha fade of a full-screen frozen-image backdrop reads as a
        // wave/shimmer sweeping the screen the moment the overlay shows.
        animationBehavior = .none
        isOpaque = opaque
        backgroundColor = opaque ? .black : .clear
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
