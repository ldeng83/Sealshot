import AppKit
import KeyboardShortcuts

/// Owns the app's persistent menu-bar status item (created at launch, so it
/// claims a stable slot before any recording starts — the whole reason the old
/// on-demand recording item vanished under the notch). Renders `MenuBarModel`
/// specs into the `NSMenu`, dispatches rows to the coordinators, and flips the
/// icon red while recording. Thin glue over the tested `MenuBarModel`.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate, RecordingStateObserver {
    private let statusItem: NSStatusItem
    private let capture: CaptureCoordinator
    private let recording: RecordingCoordinator

    private var isRecording = false
    private var paused = false
    // Elapsed = recorded time excluding pauses: sum of completed running
    // segments plus the current one. Computed lazily when the menu opens, so no
    // per-second timer is needed (the icon carries no timer text).
    private var accumulated: TimeInterval = 0
    private var segmentStart: Date?

    private let idleImage = MenuBarController.loadIcon()
    /// Re-render the (appearance-tinted) recording icon when the menu-bar
    /// theme flips between light and dark mid-recording.
    private var appearanceObserver: NSKeyValueObservation?

    init(capture: CaptureCoordinator, recording: RecordingCoordinator) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.capture = capture
        self.recording = recording
        super.init()

        statusItem.autosaveName = "SealshotStatusItem"   // remember position; ⌘-drag stays put
        statusItem.button?.toolTip = "Sealshot"
        updateIcon()
        // The idle icon is a template (system-tinted), so it auto-adapts. The
        // recording icon is hand-tinted (it carries a red dot), so re-render it
        // when the menu-bar appearance flips light↔dark.
        appearanceObserver = statusItem.button?.observe(\.effectiveAppearance, options: [.new]) {
            [weak self] _, _ in
            MainActor.assumeIsolated { if self?.isRecording == true { self?.updateIcon() } }
        }

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false                    // we set isEnabled explicitly
        statusItem.menu = menu
        // A hotkey pressed while this menu is open must dismiss it before the
        // capture flow may run — otherwise the menu's tracking session wedges
        // (see CaptureCoordinator.deferIfMenuTracking).
        capture.trackedMenus.append { [weak menu] in menu }

        recording.addObserver(self)
    }

    // MARK: - Recording state (RecordingStateObserver)

    func recordingDidStart() { enterRecording() }
    func recordingDidStop() { exitRecording() }
    func recordingPausedChanged(_ paused: Bool) { setPaused(paused) }

    private func enterRecording() {
        isRecording = true; paused = false
        accumulated = 0; segmentStart = Date()
        updateIcon()
    }

    private func exitRecording() {
        isRecording = false; paused = false
        accumulated = 0; segmentStart = nil
        updateIcon()
    }

    private func setPaused(_ paused: Bool) {
        guard isRecording else { return }
        if paused, let start = segmentStart {
            accumulated += Date().timeIntervalSince(start)
            segmentStart = nil
        } else if !paused, segmentStart == nil {
            segmentStart = Date()
        }
        self.paused = paused
    }

    private func elapsedSeconds() -> Int {
        var total = accumulated
        if let start = segmentStart { total += Date().timeIntervalSince(start) }
        return Int(total)
    }

    private func updateIcon() {
        statusItem.button?.image = isRecording ? makeRecordingImage() : idleImage
    }

    /// The recording icon, tinted for the CURRENT menu-bar appearance (white on
    /// a dark bar, near-black on a light one) plus the red dot — mirroring the
    /// idle template's auto-adaptation, which a red-badged icon can't get for
    /// free.
    private func makeRecordingImage() -> NSImage {
        let isDark = statusItem.button?.effectiveAppearance
            .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let seal = MenuBarController.tinted(idleImage, isDark ? .white : .black)
        return MenuBarController.withRecordingDot(seal)
    }

    private var state: MenuBarState {
        isRecording ? .recording(paused: paused, elapsedSeconds: elapsedSeconds()) : .idle
    }

    // MARK: - Menu (NSMenuDelegate)

    /// Conditional-row state, read fresh on every open (the menu rebuilds
    /// each time, so encryption toggles and Sparkle readiness stay current).
    private var context: MenuBarContext {
        MenuBarContext(
            updatesSupported: UpdaterController.shared.updatesAreSupported,
            updateCheckReady: UpdaterController.shared.canCheckForUpdates,
            encryptionEnabled: EncryptionSession.shared.isEnabled,
            sessionUnlocked: EncryptionSession.shared.isUnlocked,
            clipboardHasImage: NewCanvasFactory.clipboardHasImage())
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for spec in MenuBarModel.items(for: state, context: context) {
            if spec.isSeparator { menu.addItem(.separator()); continue }
            let item = NSMenuItem(
                title: spec.title,
                action: spec.action == nil ? nil : #selector(menuItemClicked(_:)),
                keyEquivalent: "")
            item.target = self
            item.isEnabled = spec.enabled
            item.representedObject = spec.action
            if let icon = spec.icon {
                item.image = NSImage(systemSymbolName: icon, accessibilityDescription: spec.title)
            }
            // Show the item's current global shortcut. Use the non-observer
            // overload (no NotificationCenter retain) and re-read each open, so
            // rebuilt menu items don't leak and the display stays current.
            if let action = spec.action, let name = Self.shortcutName(for: action) {
                item.setShortcut(KeyboardShortcuts.getShortcut(for: name))
            }
            menu.addItem(item)
        }
    }

    /// The global shortcuts shown in the menu. Disabled while the menu is open
    /// so a press routes through the menu item, not the buffered global handler.
    private static let shortcutNames: [KeyboardShortcuts.Name] =
        [.captureFullscreen, .captureUnified, .captureDelayed, .captureScroll, .captureRepeat,
         .captureSaveAs, .recordToggle, .recordSelection,
         .openEditor, .openLibrary, .newFromClipboard, .lockNow]

    private static func shortcutName(for action: MenuBarAction) -> KeyboardShortcuts.Name? {
        switch action {
        case .captureFullscreen: return .captureFullscreen
        case .captureUnified:    return .captureUnified
        case .captureDelayed:    return .captureDelayed
        case .captureScroll:     return .captureScroll
        case .captureRepeat:     return .captureRepeat
        case .captureLive:       return .captureLive
        case .captureSaveAs:     return .captureSaveAs
        case .recordScreen:      return .recordToggle
        case .recordSelection:   return .recordSelection
        case .openEditor:        return .openEditor
        case .openLibrary:       return .openLibrary
        case .newFromClipboard:  return .newFromClipboard
        case .lockNow:           return .lockNow
        default:                 return nil
        }
    }

    /// Ticks the recording header's elapsed time while the menu is open.
    /// Added in .common mode because menu tracking runs the event-tracking
    /// runloop mode, where default-mode timers don't fire.
    private var menuClockTimer: Timer?

    func menuWillOpen(_ menu: NSMenu) {
        // While the menu tracks, key events buffer and would fire the global
        // shortcut on close (double-trigger). Disable them for the duration.
        KeyboardShortcuts.disable(Self.shortcutNames)
        guard isRecording else { return }
        // Reach the menu through self (statusItem.menu) rather than capturing
        // the NSMenu in the @Sendable timer closure.
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isRecording,
                      let header = self.statusItem.menu?.items.first,
                      header.action == nil else { return }
                header.title = "Recording — \(MenuBarModel.elapsedString(self.elapsedSeconds()))"
            }
        }
        RunLoop.main.add(t, forMode: .common)
        menuClockTimer = t
    }

    func menuDidClose(_ menu: NSMenu) {
        menuClockTimer?.invalidate()
        menuClockTimer = nil
        KeyboardShortcuts.enable(Self.shortcutNames)
    }

    @objc private func menuItemClicked(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? MenuBarAction else { return }
        switch action {
        case .captureFullscreen: capture.triggerFullscreenCapture()
        case .captureUnified:    capture.triggerUnifiedCapture()
        case .captureDelayed:    capture.triggerDelayedCapture()
        case .captureScroll:     capture.triggerScrollCapture()
        case .captureRepeat:     capture.triggerRepeatCapture()
        case .captureLive:       capture.triggerLiveCapture()
        case .captureSaveAs:     capture.triggerSaveAsCapture()
        case .recordScreen:      recording.toggle()
        case .recordSelection:   recording.beginSelection()
        case .openEditor:        capture.triggerOpenEditor()
        case .openLibrary:       capture.editor.presentLibrary()
        case .newFromClipboard:  capture.openCanvasFromClipboard()
        case .importImage:       capture.presentImportPanel()
        case .settings:          capture.triggerOpenSettings()
        case .checkForUpdates:   UpdaterController.shared.checkForUpdates()
        case .lockNow:
            // Same guards as the global shortcut: no-op unless there is an
            // unlocked session to seal (the row is disabled then anyway).
            guard EncryptionSession.shared.isEnabled,
                  EncryptionSession.shared.isUnlocked else { return }
            EncryptionSession.shared.lock()
        case .quit:              NSApp.terminate(nil)
        case .pauseResume:       recording.togglePause()
        case .stopRecording:     recording.stopRecording()
        }
    }

    // MARK: - Icon images

    /// The seal + viewfinder brackets artwork, sized larger than the default
    /// menu-bar glyph. Flagged as a TEMPLATE so the system tints it to match the
    /// menu bar — white on a dark bar, near-black on a light one — instead of
    /// staying white-only (which read faint on a light bar). The shape flattens
    /// to a silhouette, standard for a menu-bar glyph.
    private static func loadIcon() -> NSImage {
        let image = NSImage(named: "MenuBarIcon")
            ?? NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Sealshot")
            ?? NSImage()
        image.size = NSSize(width: 24, height: 24)
        image.isTemplate = true
        return image
    }

    /// Recolor `base`'s opaque shape to `color` (used to tint the recording
    /// seal, since its red dot rules out the system template path).
    private static func tinted(_ base: NSImage, _ color: NSColor) -> NSImage {
        let rect = NSRect(origin: .zero, size: base.size)
        let out = NSImage(size: base.size)
        out.lockFocus()
        base.draw(in: rect)
        color.set()
        rect.fill(using: .sourceAtop)
        out.unlockFocus()
        return out
    }

    /// The icon with a red recording dot badge in the lower-right corner — a
    /// detailed (non-silhouette) icon can't be tinted red cleanly.
    private static func withRecordingDot(_ base: NSImage) -> NSImage {
        let out = NSImage(size: base.size)
        out.lockFocus()
        base.draw(in: NSRect(origin: .zero, size: base.size))
        let d = base.size.width * 0.5
        let dot = NSRect(x: base.size.width - d, y: 0, width: d, height: d)
        NSColor.white.setFill(); NSBezierPath(ovalIn: dot).fill()            // halo
        NSColor.systemRed.setFill(); NSBezierPath(ovalIn: dot.insetBy(dx: 1.5, dy: 1.5)).fill()
        out.unlockFocus()
        out.isTemplate = false
        return out
    }
}
