import AppKit
import SwiftUI
import ScreenCaptureKit
import KeyboardShortcuts
import os.log

private let log = OSLog(subsystem: "com.seal-shot.sealshot", category: "capture")

// Display handles (NSScreen / SCDisplay / displayID) are resolved fresh at
// each capture trigger and never stored on this coordinator, so hot-plug or
// resolution changes between captures cannot produce a stale-handle capture.
@MainActor
final class CaptureCoordinator {
    let permission = ScreenRecordingPermission()
    private let config = CaptureConfig()
    /// Convenience read-through for the save folder so callers
    /// (e.g., AppDelegate's purge task) don't need access to private config.
    var saveFolder: URL { config.saveFolder }
    /// Read-through so AppDelegate's purge uses the user's retention setting.
    var retentionDays: Int { config.retentionDays }
    private let overlay = OverlayController()
    private let capturer: RegionCapturer
    private let windowCapturer: WindowCapturer
    /// The area of the last capture, for repeating it. Read here and written
    /// by `RegionCapturer` — the one point every area capture passes through.
    private let lastRegion = LastCaptureRegionStore()
    private let fullscreenCapturer: FullscreenCapturer
    let editor: EditorController
    private let windowPicker = WindowPickerController()
    private let unifiedOverlay = UnifiedOverlayController()
    private let countdown = CaptureCountdownController()
    /// Shared with the recording flow so its countdown reuses the same panel
    /// and global-Esc cancel wiring (see `.pickerCancel` handler).
    var sharedCountdown: CaptureCountdownController { countdown }

    /// Whether a screen recording is running — injected (the recording
    /// coordinator is a sibling, wired in AppDelegate). A recording blocks
    /// new capture sessions just like an in-flight capture does.
    var isRecordingActive: () -> Bool = { false }

    /// True while the in-flight capture was started from the floating capture
    /// window. Set immediately before the trigger call and cleared when the
    /// capture resolves; `presentCaptured` reads it to keep the editor closed.
    var captureOriginIsFloatingWindow = false

    /// Tell the floating window a capture landed, and where it was saved, so
    /// its count and thumbnail strip update. Injected by `AppDelegate` — with
    /// the editor suppressed these are the user's only proof anything happened.
    /// `nil` for a clipboard-only capture, which has no file to show.
    var floatingWindowCaptureLanded: (URL?) -> Void = { _ in }

    /// Show or hide the floating capture window. Injected rather than held as a
    /// reference, so the coordinator does not depend on AppKit panel types it
    /// otherwise never touches.
    var toggleFloatingWindowHandler: () -> Void = {}

    /// Both entry routes — the editor's toolbar button and the View menu — call
    /// this, so they can never disagree about the panel's state.
    func toggleFloatingWindow() {
        toggleFloatingWindowHandler()
    }

    /// Open the library folder in Finder.
    ///
    /// Some people would rather manage files in Finder than in any app's
    /// browser, and until now the only way there was "Show in Finder" on a
    /// single capture. Opens the folder itself rather than selecting anything,
    /// so it behaves like any other "reveal my documents" command.
    func openLibraryFolderInFinder() {
        let folder = saveFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    /// Bring the floating window back somewhere visible. Injected for the same
    /// reason as the toggle above.
    var resetFloatingWindowPositionHandler: () -> Void = {}

    func resetFloatingWindowPosition() {
        resetFloatingWindowPositionHandler()
    }

    /// True while ANY capture session owns the screen: the unified overlay,
    /// the legacy window picker, a delayed/recording countdown, a
    /// scrolling-capture session, or fullscreen's click-a-monitor overlay.
    var isCaptureSessionActive: Bool {
        unifiedOverlay.isRunning || windowPicker.isRunning
            || countdown.isRunning || scrollCapture?.isRunning == true
            || displayPicker?.isRunning == true
    }

    /// Why a new capture/recording start is rejected right now (nil = allowed).
    /// Pure so the one-session-at-a-time policy is unit-testable.
    enum BusyReason: String {
        case captureSession = "capture session"
        case recording = "recording"
    }
    nonisolated static func busyReason(captureSessionActive: Bool,
                                       recordingActive: Bool) -> BusyReason? {
        if captureSessionActive { return .captureSession }
        if recordingActive { return .recording }
        return nil
    }

    /// Soft lock: encryption is ON and the session isn't unlocked. Content
    /// actions (open editor/library, new-from-clipboard) no-op while locked;
    /// capture/record stay enabled (write-only encrypted `.seal`).
    static var isLocked: Bool {
        EncryptionSession.shared.isEnabled && !EncryptionSession.shared.isUnlocked
    }

    /// The busy gate every capture trigger passes: logs and eats the trigger
    /// while another session/recording is in progress (silent no-op — the
    /// active overlay or recording HUD already explains why).
    private func blockedByActiveSession(_ label: String) -> Bool {
        guard let reason = Self.busyReason(captureSessionActive: isCaptureSessionActive,
                                           recordingActive: isRecordingActive()) else {
            return false
        }
        os_log("capture %{public}@ blocked — %{public}@ in progress",
               log: log, type: .info, label, reason.rawValue)
        endFloatingWindowCapture()
        return true
    }

    /// Reuse the capture overlay to pick a region or window to RECORD. The
    /// freeze is only for the pick; recording captures the live content in that
    /// area afterward. Returns nil if the user cancels (Esc) or the source
    /// can't be resolved.
    func pickRecordingSource() async -> RecordingSession.Source? {
        let frames: FrozenFrameSet
        do {
            frames = try await FrozenFrameGrabber.captureAll()
        } catch {
            os_log("recording source freeze failed: %{public}@", log: log, type: .error,
                   String(describing: error))
            return nil
        }
        switch await unifiedOverlay.select(frames: frames, hints: CrosshairRender.Hints.unified) {
        case .cancelled:
            return nil
        case .window(let win, _, let span):
            SignpostMetrics.end(span)
            return .window(win)
        case .region(let region):
            guard let display = await Self.scDisplay(for: region.screen) else { return nil }
            return .region(display, Self.displayLocalTopLeftRect(region.globalRect,
                                                                 screenFrame: region.screen.frame))
        }
    }

    /// The `SCDisplay` backing an `NSScreen`, matched by display id.
    private static func scDisplay(for screen: NSScreen) async -> SCDisplay? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        else { return nil }
        return content.displays.first { $0.displayID == number.uint32Value }
    }

    /// Weak wrapper for wiring a self-referencing closure during init
    /// (capturing `self` directly is illegal before all properties are set).
    final class WeakRef<T: AnyObject> { weak var value: T? }

    /// Global AppKit rect (bottom-left origin) → display-local, top-left points,
    /// which is what `SCStreamConfiguration.sourceRect` expects. Internal so the
    /// flip math can be unit-tested without an NSScreen.
    static func displayLocalTopLeftRect(_ global: CGRect, screenFrame: CGRect) -> CGRect {
        CGRect(x: global.minX - screenFrame.minX,
               y: screenFrame.maxY - global.maxY,
               width: global.width, height: global.height)
    }

    /// Per-session injector for scrolling capture. Sandboxed (MAS) → nil
    /// (manual only, unchanged). Otherwise Accessibility position-setting
    /// when the target exposes a scroll bar (native apps — exact positions
    /// and bottom detection), else synthetic wheel events. The JS-over-
    /// AppleScript browser tier was removed: it needed the browsers'
    /// off-by-default "Allow JavaScript from Apple Events" dev setting plus
    /// an Automation consent prompt, and the wheel path now handles the
    /// pages it was insurance for.
    static func resolveScrollInjector(for region: SelectedRegion) async -> ScrollInjecting? {
        if AccessibilityPermission.isSandboxed { return nil }
        if let ax = await AXScrollDriver.make(atGlobal: CGPoint(x: region.globalRect.midX,
                                                                y: region.globalRect.midY)) {
            ScrollDiag.note("injector: AXScrollDriver (Accessibility position-set)")
            return ax
        }
        ScrollDiag.note("injector: CGScrollInjector (synthetic wheel)")
        return CGScrollInjector()
    }

    private var scrollCapture: ScrollCaptureController?
    private let saveAs: SaveAsCoordinator
    private var permissionWindow: NSWindow?

    init() {
        self.capturer = RegionCapturer(config: config)
        self.windowCapturer = WindowCapturer(config: config)
        self.fullscreenCapturer = FullscreenCapturer(config: config)
        self.editor = EditorController(config: config)
        self.saveAs = SaveAsCoordinator(config: config)
        let capturer = self.capturer
        self.scrollCapture = ScrollCaptureController(
            makeSampler: { region in
                try await capturer.frameSampler(for: region)
            },
            makeInjector: { region in
                await CaptureCoordinator.resolveScrollInjector(for: region)
            }
        )

        // The generic "Capture New" entry points (empty-editor button + the
        // Library button) use the unified (merged) capture. Region/window
        // capture are hidden for now; their dedicated triggers stay defined so
        // they can be re-exposed later.
        self.editor.setOnCaptureRequested { [weak self] in
            self?.triggerUnifiedCapture()
        }
        self.editor.setOnWindowCaptureRequested { [weak self] in
            self?.triggerWindowCapture()
        }
        self.editor.setOnUnifiedCaptureRequested { [weak self] in
            self?.triggerUnifiedCapture()
        }
        self.editor.setOnDelayedCaptureRequested { [weak self] in
            self?.triggerDelayedCapture()
        }
        self.editor.setOnScrollCaptureRequested { [weak self] in
            self?.triggerScrollCapture()
        }
        self.editor.setOnLiveCaptureRequested { [weak self] in
            self?.triggerLiveCapture()
        }
        self.editor.setOnFullscreenCaptureRequested { [weak self] choice in
            self?.triggerFullscreenCapture(choice: choice)
        }
        self.editor.setOnNewCanvasRequested { [weak self] in
            self?.openNewCanvas()
        }
        self.editor.setOnNewFromClipboardRequested { [weak self] in
            self?.openCanvasFromClipboard()
        }
        self.editor.setOnImportRequested { [weak self] in
            self?.presentImportPanel()
        }
        self.editor.setOnImportFilesRequested { [weak self] urls, revealInLibrary in
            self?.importFiles(urls, revealInLibrary: revealInLibrary)
        }

        // Region/window shortcuts are intentionally not registered for now —
        // re-add KeyboardShortcuts.onKeyUp(for: .captureRegion / .captureWindow)
        // to bring them back.
        KeyboardShortcuts.onKeyUp(for: .captureFullscreen) { [weak self] in
            self?.triggerFullscreenCapture()
        }
        KeyboardShortcuts.onKeyUp(for: .captureUnified) { [weak self] in
            self?.triggerUnifiedCapture()
        }
        KeyboardShortcuts.onKeyUp(for: .captureDelayed) { [weak self] in
            self?.triggerDelayedCapture()
        }
        KeyboardShortcuts.onKeyUp(for: .captureScroll) { [weak self] in
            self?.triggerScrollCapture()
        }
        KeyboardShortcuts.onKeyUp(for: .captureLive) { [weak self] in
            self?.triggerLiveCapture()
        }
        KeyboardShortcuts.onKeyUp(for: .captureRepeat) { [weak self] in
            self?.triggerRepeatCapture()
        }
        // Return finishes a scrolling-capture session; bound dynamically by
        // ScrollCaptureController, same pattern as pickerCancel. Keypad Enter
        // is a separate key code with its own session-scoped binding.
        KeyboardShortcuts.onKeyDown(for: .scrollCaptureFinish) { [weak self] in
            self?.scrollCapture?.finishFromGlobalReturn()
        }
        KeyboardShortcuts.onKeyDown(for: .scrollCaptureFinishKeypad) { [weak self] in
            self?.scrollCapture?.finishFromGlobalReturn()
        }
        KeyboardShortcuts.onKeyUp(for: .captureSaveAs) { [weak self] in
            self?.triggerSaveAsCapture()
        }
        // These open/edit existing or decrypted content — no-op while locked
        // (soft lock). Capture/record shortcuts above stay live (write-only
        // encrypted .seal). The menus disable the matching rows too.
        KeyboardShortcuts.onKeyUp(for: .openEditor) { [weak self] in
            guard !Self.isLocked else { return }
            self?.triggerOpenEditor()
        }
        KeyboardShortcuts.onKeyUp(for: .openLibrary) { [weak self] in
            guard !Self.isLocked else { return }
            self?.editor.presentLibrary()
        }
        KeyboardShortcuts.onKeyUp(for: .newFromClipboard) { [weak self] in
            guard !Self.isLocked else { return }
            self?.openCanvasFromClipboard()
        }
        // The "walking away from my desk" key — seal the library instantly.
        // No-op while encryption is off or already locked.
        KeyboardShortcuts.onKeyUp(for: .lockNow) {
            guard EncryptionSession.shared.isEnabled,
                  EncryptionSession.shared.isUnlocked else { return }
            EncryptionSession.shared.lock()
        }
        // Plain-Esc handler used only during picker sessions; the
        // controller toggles the binding on/off so we don't steal Esc
        // system-wide outside the picker.
        KeyboardShortcuts.onKeyDown(for: .pickerCancel) { [weak self] in
            // Only the active session (picker or unified) responds; each guards
            // on having a live continuation.
            self?.windowPicker.cancelFromGlobalEsc()
            self?.unifiedOverlay.cancelFromGlobalEsc()
            self?.countdown.cancelFromGlobalEsc()
            self?.scrollCapture?.cancelFromGlobalEsc()
        }
        os_log("CaptureCoordinator registered ⌘⇧F / ⌘⇧S / ⌘⇧E / ⌘⇧C", log: log, type: .info)
    }

    // MARK: - Selection loop

    private enum SelectionMode {
        case region
        case window
    }

    private enum SelectionLoopResult {
        case region(SelectedRegion)
        case window(SCWindow, NSScreen, SignpostMetrics.Token)
    }

    /// Loop between region overlay and window picker, returning a single
    /// successful selection or nil for cancel. The hotkey token is ended by
    /// the first mode shown; subsequent cycles begin fresh spans internally.
    private func runSelectionLoop(
        startMode: SelectionMode,
        hotkeyToken: SignpostMetrics.Token
    ) async -> SelectionLoopResult? {
        var mode = startMode
        var pendingHotkeyToken: SignpostMetrics.Token? = hotkeyToken

        while true {
            switch mode {
            case .region:
                // If we arrived here via cycle, begin a fresh hotkey-to-overlay span
                let token = pendingHotkeyToken ?? SignpostMetrics.begin("hotkey-to-overlay")
                pendingHotkeyToken = nil
                let result = await overlay.select(hotkeyToken: token)
                switch result {
                case .region(let region):
                    return .region(region)
                case .cycle:
                    mode = .window
                    continue
                case .cancelled:
                    return nil
                }
            case .window:
                let token = pendingHotkeyToken ?? SignpostMetrics.begin("hotkey-to-picker")
                pendingHotkeyToken = nil
                let result = await windowPicker.selectWindow(hotkeyToken: token)
                switch result {
                case .picked(let win, let screen, let span):
                    return .window(win, screen, span)
                case .cycle:
                    mode = .region
                    continue
                case .cancelled:
                    return nil
                }
            }
        }
    }

    // MARK: - Region

    // MARK: - Menu-tracking guard

    /// Menus the guard must dismiss besides the main menu bar — the status
    /// item's menu registers itself (its tracking session wedges the same way).
    var trackedMenus: [() -> NSMenu?] = []

    /// Hotkeys fire INSIDE an open menu's tracking runloop (Carbon handlers
    /// and the main queue both run in the tracking mode). Starting a capture
    /// there wedges AppKit's NSMenuTrackingSession — the menu title stays
    /// stuck highlighted, the overlay panels never present, and the live
    /// session then holds the busy gate so every later trigger is eaten
    /// (verified by backtrace: startRunningMenuEventLoop parked forever).
    /// Returns true when the trigger was deferred: the caller bails, and
    /// `retry` re-enters after the menus are cancelled and their tracking
    /// loop unwinds (the mode is re-checked — another menu may still be up).
    private func deferIfMenuTracking(retry: @escaping () -> Void) -> Bool {
        guard RunLoop.current.currentMode == .eventTracking else { return false }
        os_log("capture trigger during menu tracking — cancelling menus, deferring",
               log: log, type: .info)
        NSApp.mainMenu?.cancelTrackingWithoutAnimation()
        for provider in trackedMenus { provider()?.cancelTrackingWithoutAnimation() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { retry() }
        return true
    }

    func triggerRegionCapture() {
        if deferIfMenuTracking(retry: { [weak self] in self?.triggerRegionCapture() }) { return }
        let hotkeyToken = SignpostMetrics.begin("hotkey-to-overlay")
        gatePermission(
            hotkeyToken: hotkeyToken,
            granted: { [weak self] in
                self?.editor.dismissWithAutoSave()
                self?.runCaptureSession(hotkeyToken: hotkeyToken)
            },
            retry: { [weak self] in self?.triggerRegionCapture() },
            label: "region"
        )
    }

    /// Capture the last area again, with no overlay and no selection.
    ///
    /// The point of the feature is the absence of ceremony: for step-by-step
    /// documentation, before/after shots, or watching one corner of a
    /// dashboard, reselecting the same box every time is the whole friction.
    ///
    /// When the remembered area can't be honoured EXACTLY — its display was
    /// unplugged, or the screen's resolution changed under it — this falls
    /// back to ordinary selection rather than capturing approximately the
    /// right pixels. The overlay says why it appeared, and whatever the user
    /// drags becomes the new repeat area, so one gesture puts the feature back
    /// in service. See `LastCaptureRegionStore` for why nothing is clamped.
    func triggerRepeatCapture() {
        if deferIfMenuTracking(retry: { [weak self] in self?.triggerRepeatCapture() }) { return }
        let hotkeyToken = SignpostMetrics.begin("hotkey-to-overlay")
        gatePermission(
            hotkeyToken: hotkeyToken,
            granted: { [weak self] in
                guard let self else { return }
                guard let region = self.resolvedRepeatRegion() else {
                    // Never captured yet, or captured somewhere that no longer
                    // exists — the same fallback, but not the same sentence.
                    let neverCaptured = self.lastRegion.stored == nil
                    os_log("repeat capture: no usable area (%{public}@) — falling back to selection",
                           log: log, type: .info,
                           neverCaptured ? "nothing stored" : "stored area unusable")
                    SignpostMetrics.end(hotkeyToken)
                    self.triggerUnifiedCapture(hints: neverCaptured
                        ? CrosshairRender.Hints.repeatNothingYet
                        : CrosshairRender.Hints.repeatUnavailable)
                    return
                }
                self.editor.dismissWithAutoSave()
                self.runRepeatCapture(region: region, hotkeyToken: hotkeyToken)
            },
            retry: { [weak self] in self?.triggerRepeatCapture() },
            label: "repeat"
        )
    }

    /// The remembered area as something capturable right now, or nil.
    func resolvedRepeatRegion() -> SelectedRegion? {
        LastCaptureRegionStore.resolve(lastRegion.stored, screens: NSScreen.screens,
                                       displayID: DisplayIdentity.id(for:))
    }

    private func runRepeatCapture(region: SelectedRegion,
                                  hotkeyToken: SignpostMetrics.Token) {
        Task { @MainActor in
            defer { self.endFloatingWindowCapture() }
            SignpostMetrics.end(hotkeyToken)
            do {
                let captured = try await self.capturer.capture(region)
                // Show WHERE it fired. Without an overlay there is otherwise no
                // evidence a capture happened at all, let alone of what.
                RepeatCaptureFlash.show(region)
                self.presentCaptured(captured)
            } catch {
                os_log("repeat capture failed: %{public}@", log: log, type: .error,
                       String(describing: error))
                self.cancelledCaptureSession()
            }
        }
    }

    /// Best-effort frozen grab feeding the live region overlay's crosshair
    /// loupe. Runs concurrently with overlay presentation and never blocks or
    /// delays the session — the loupe appears once frames arrive (and stays
    /// hidden if the grab fails). Clears first so a previous trigger's frames
    /// can't show stale pixels while the new grab is in flight.
    private func refreshLiveLoupeSource() {
        overlay.updateLoupeSource(nil)
        Task { @MainActor in
            if let frames = try? await FrozenFrameGrabber.captureAll() {
                self.overlay.updateLoupeSource(frames)
            }
        }
    }

    private func runCaptureSession(hotkeyToken: SignpostMetrics.Token) {
        refreshLiveLoupeSource()
        Task { @MainActor in
            // Every exit — captured, cancelled, or thrown — restores the panel
            // and the editor. Idempotent with `presentCaptured`.
            defer { self.endFloatingWindowCapture() }
            guard let result = await self.runSelectionLoop(startMode: .region, hotkeyToken: hotkeyToken) else {
                os_log("region/window selection cancelled", log: log, type: .info)
                self.cancelledCaptureSession()
                return
            }
            do {
                switch result {
                case .region(let region):
                    let captured = try await self.capturer.capture(region)
                    self.presentCaptured(captured)
                case .window(let win, let screen, let captureSpan):
                    let captured = try await self.windowCapturer.capture(window: win, on: screen)
                    SignpostMetrics.end(captureSpan)
                    self.presentCaptured(captured)
                }
            } catch {
                os_log("capture failed: %{public}@", log: log, type: .error, String(describing: error))
            }
        }
    }

    /// Whether a finished still capture opens the editor. Clipboard-only
    /// destination means the capture is deliberately ephemeral — it went to
    /// the pasteboard and nothing else should happen; New-from-Clipboard
    /// (⇧⌘N) covers "actually, I want to edit it". A capture that DID save a
    /// file always opens (including `.both` degrading to clipboard-only on a
    /// file-write failure — the editor is then the only place the capture
    /// remains recoverable beyond one paste).
    ///
    /// The second suppression is the floating capture window, and it applies
    /// whether or not the editor happened to be open. Keying it on editor
    /// visibility (the first attempt) made the panel useless in its most common
    /// state: the panel is opened FROM the editor's toolbar, so the editor is
    /// usually still there, and every capture re-summoned it — which is the one
    /// behaviour the panel exists to prevent. Clicking the panel is the user
    /// saying "not the big window"; ⤢ is how they ask for it back.
    /// The third suppression is the user having CLOSED the editor window. A
    /// window someone closed on purpose should not be reopened by a background
    /// action; captures keep landing in the Library either way, and any
    /// deliberate way in (⌘⇧E, the Library shortcut, the Dock, the menu bar)
    /// clears it. Distinct from merely hidden: `dismissWithAutoSave` hides the
    /// window for the duration of a capture and expects it back.
    nonisolated static func shouldOpenEditor(output: CaptureOutput, savedFileURL: URL?,
                                             startedFromFloatingWindow: Bool,
                                             userClosedEditor: Bool = false) -> Bool {
        if output == .clipboard && savedFileURL == nil { return false }
        if userClosedEditor { return false }
        return !startedFromFloatingWindow
    }

    /// Route a finished still capture to the editor per `shouldOpenEditor`;
    /// after a clipboard-only capture the editor window simply STAYS HIDDEN
    /// (it was hidden for the capture anyway) — reopen it via ⌘⇧E, the menu
    /// bar, or the Dock as usual.
    private func presentCaptured(_ result: CaptureResult) {
        let fromFloatingWindow = captureOriginIsFloatingWindow
        // Whatever happens below, this capture is finished: the next one is
        // whatever surface starts it. A stuck flag would silence the editor for
        // menu-bar and shortcut captures too.
        defer { endFloatingWindowCapture() }

        // Fresh captures are ⌘Z-undoable (undo → trash, redo → restore),
        // whether or not the editor opens for them. Scratch captures are NOT
        // announced: the notification is what feeds the index, the strips and
        // capture-undo, and "not in the Library" means none of those. The
        // keep gesture (Add to Library) posts it when the file moves in.
        if let saved = result.savedFileURL, !ScratchCapture.isScratch(saved) {
            NotificationCenter.default.post(name: .captureFilesImported, object: [saved],
                                            userInfo: ["kind": "capture"])
        }
        if fromFloatingWindow {
            floatingWindowCaptureLanded(result.savedFileURL)
        }
        // Sealshot is free and funded by the people who buy it. Count the work
        // that just landed, and let the policy decide whether this is one of the
        // rare moments to ask — after the capture, never in front of it.
        SupportNudge.recordCreationAndAskIfDue(isBusy: { [weak self] in
            guard let self else { return false }
            return self.isCaptureSessionActive || self.isRecordingActive()
        })
        guard Self.shouldOpenEditor(output: config.defaultOutput,
                                    savedFileURL: result.savedFileURL,
                                    startedFromFloatingWindow: fromFloatingWindow,
                                    userClosedEditor: editor.userClosedWindow) else {
            os_log("capture kept quiet — editor stays hidden", log: log, type: .info)
            return
        }
        editor.present(result)
        onEditorOpened()
    }

    /// Start a capture owned by the floating panel. Sets the origin flag AND
    /// tells the editor to stay down: the panel deliberately hid the big window
    /// and is now the user's surface, so neither a landed capture nor a cancel
    /// should drag it back.
    func beginFloatingWindowCapture() {
        captureOriginIsFloatingWindow = true
        editor.keepHiddenAfterCapture = true
    }

    /// True while a recording started from the floating panel is in flight.
    ///
    /// Separate from `captureOriginIsFloatingWindow` because a recording never
    /// reaches `presentCaptured`: it ends on the `.recordingDidFinish`
    /// notification, long after a still capture would have cleared its flag.
    private var recordingOriginIsFloatingWindow = false

    /// A recording the floating panel started. Like a still capture, it must
    /// not summon the editor when it lands — but recordings arrive by a
    /// different route, so they need their own suppression.
    func beginFloatingWindowRecording() {
        recordingOriginIsFloatingWindow = true
        editor.keepHiddenAfterCapture = true
        editor.suppressNextRecordingPresentation = true
        editor.onSuppressedRecordingFinished = { [weak self] url in
            self?.endFloatingWindowRecording(savedURL: url)
        }
    }

    /// The recording finished or was abandoned: count it, show it in the strip,
    /// and put the editor back exactly as a still capture does.
    func endFloatingWindowRecording(savedURL: URL?) {
        guard recordingOriginIsFloatingWindow else { return }
        recordingOriginIsFloatingWindow = false
        editor.suppressNextRecordingPresentation = false
        if let savedURL {
            floatingWindowCaptureLanded(savedURL)
        }
        editor.restoreAfterFloatingCapture()
        floatingWindowCaptureEnded()
    }

    /// Clear both, and put the panel back. Called on EVERY exit path — landed,
    /// cancelled, or failed — because a panel that vanishes when you press Esc
    /// is worse than one that never hid.
    func endFloatingWindowCapture() {
        guard captureOriginIsFloatingWindow else { return }
        captureOriginIsFloatingWindow = false
        // Put the editor back where it was — same frame, same ordering, same
        // content. We hid it for the capture, so undoing that is ours to do;
        // leaving it hidden made a capture look like it had closed the window.
        editor.restoreAfterFloatingCapture()
        floatingWindowCaptureEnded()
    }

    /// Restore the floating panel after its capture ends, however it ended.
    var floatingWindowCaptureEnded: () -> Void = {}

    /// The single exit for a cancelled or abandoned capture session. Every
    /// cancel path funnels here so the floating panel is restored exactly once,
    /// no matter which of the many overlays did the cancelling — the panel
    /// vanishing on Esc was the symptom of restoring it in only one of them.
    func cancelledCaptureSession() {
        editor.reshowAfterCancel()
        endFloatingWindowCapture()
        // An abandoned recording (cancelled selection, cancelled countdown)
        // leaves no file — but the panel and editor still have to come back.
        endFloatingWindowRecording(savedURL: nil)
    }

    // MARK: - Window (direct ⌘⇧W)

    func triggerWindowCapture() {
        let hotkeyToken = SignpostMetrics.begin("hotkey-to-picker")
        gatePermission(
            hotkeyToken: hotkeyToken,
            granted: { [weak self] in
                self?.editor.dismissWithAutoSave()
                self?.runWindowCaptureSession(hotkeyToken: hotkeyToken)
            },
            retry: { [weak self] in self?.triggerWindowCapture() },
            label: "window"
        )
    }

    private func runWindowCaptureSession(hotkeyToken: SignpostMetrics.Token) {
        Task { @MainActor in
            // Every exit — captured, cancelled, or thrown — restores the panel
            // and the editor. Idempotent with `presentCaptured`.
            defer { self.endFloatingWindowCapture() }
            guard let result = await self.runSelectionLoop(startMode: .window, hotkeyToken: hotkeyToken) else {
                os_log("window picker cancelled", log: log, type: .info)
                self.cancelledCaptureSession()
                return
            }
            do {
                switch result {
                case .region(let region):
                    let captured = try await self.capturer.capture(region)
                    self.presentCaptured(captured)
                case .window(let win, let screen, let captureSpan):
                    let captured = try await self.windowCapturer.capture(window: win, on: screen)
                    SignpostMetrics.end(captureSpan)
                    self.presentCaptured(captured)
                }
            } catch {
                os_log("capture failed: %{public}@", log: log, type: .error, String(describing: error))
            }
        }
    }

    // MARK: - Unified (⌘⇧C)

    // MARK: - Live capture

    /// Live Capture: capture every eligible window + wallpapers, compose a
    /// layered scene, write it, and open it. Additive — reuses only read-only
    /// building blocks; no existing capture path changes.
    /// Live Capture. With multiple monitors and no explicit `choice`, show the
    /// click-a-monitor overlay (⌘-click = all monitors), exactly like Full
    /// Screen capture; a single monitor or an explicit `.display(i)`/
    /// `.allDisplays` skips the overlay.
    func triggerLiveCapture(choice: DisplayChoice? = nil) {
        // Live capture bypasses gatePermission (own session flow below), so it
        // needs the busy gate explicitly — same as scroll.
        guard !blockedByActiveSession("live") else { return }
        if choice == nil, NSScreen.screens.count > 1 {
            let picker = DisplayPickerController()
            self.displayPicker = picker
            Task { @MainActor in
                let pick = await picker.pick(allowAllDisplays: true, freeze: false)
                self.displayPicker = nil
                guard let pick else { return }   // Esc/right-click cancel — no-op
                self.runLiveCaptureSession(choice: pick.choice)
            }
        } else {
            runLiveCaptureSession(choice: choice)
        }
    }

    private func runLiveCaptureSession(choice: DisplayChoice?) {
        let saveFolder = self.saveFolder
        let displayID = liveCaptureDisplayID(for: choice)
        Task { @MainActor in
            do {
                let result = try await SceneCapturer.capture(displayID: displayID)
                guard !result.windows.isEmpty else {
                    os_log("live capture: no eligible windows", log: log, type: .info)
                    NSSound.beep()
                    return
                }
                let scene = try SceneComposer.compose(result)
                let url = LiveCaptureWriter.destination(in: saveFolder)
                try LiveCaptureWriter.write(scene, to: url,
                                            crypto: SealPackageCryptoContext.current())
                // Live Capture was the only capture path that never started the
                // metadata pipeline, so scenes got no title, keywords, or
                // summary. No `source:` is passed — the scene path reads the
                // window assets from the package, not the wallpaper.
                MetadataCoordinator.shared.start(for: url, sourceApp: nil,
                                                 windowTitle: nil,
                                                 captureKind: .liveCapture)
                // Live Capture writes straight to the library and presents the
                // scene itself, so it never passes through `presentCaptured` —
                // it needs its own copy of the quiet rule, or a scene started
                // from the floating panel would take over the editor.
                if captureOriginIsFloatingWindow {
                    floatingWindowCaptureLanded(url)
                } else {
                    let state = LiveCaptureWriter.makeState(scene, url: url)
                    editor.presentScene(state, title: url.lastPathComponent)
                }
            } catch {
                os_log("live capture failed: %{public}@", log: log, type: .error, "\(error)")
                NSSound.beep()
            }
            // Success, failure, or a cancelled compose — the panel comes back
            // and the editor returns to where it was.
            endFloatingWindowCapture()
        }
    }

    /// `.allDisplays`/`nil` → nil (every monitor). `.display(i)` → that screen's
    /// `CGDirectDisplayID` (falling back to the cursor's screen if the index is
    /// stale), which `SceneCapturer` uses to scope the scene to one monitor.
    private func liveCaptureDisplayID(for choice: DisplayChoice?) -> CGDirectDisplayID? {
        switch choice {
        case .allDisplays, nil:
            return nil
        case .display(let index):
            let screens = NSScreen.screens
            let screen = (screens.indices.contains(index) ? screens[index] : nil)
                ?? cursorScreen() ?? NSScreen.main
            return screen.flatMap { DisplayResolver.displayID(for: $0) }
        }
    }

    // MARK: - Scrolling capture (⌘⇧L)

    /// Scrolling capture: pick a viewport with the live region overlay, then
    /// the user scrolls the content while a sampler feeds the stitcher; Return
    /// finishes into the normal region output path.
    func triggerScrollCapture() {
        if deferIfMenuTracking(retry: { [weak self] in self?.triggerScrollCapture() }) { return }
        // Scroll capture has its own permission preflight (below) instead of
        // gatePermission, so it needs the busy gate explicitly.
        guard !blockedByActiveSession("scroll") else { return }
        // Check EVERYTHING this capture needs up front, so the user sees
        // one checklist instead of discovering permissions one trigger at a
        // time. Synchronous preflights only — no system dialog (those come
        // exclusively from the checklist's Enable buttons) and no SCK
        // round-trip latency before the session. The checklist always lists
        // every permission with its live status; only required ones block.
        let recordingOK = CGPreflightScreenCaptureAccess()
        let accessibilityRequired = AutoScrollPreference.isEnabled()
            && !AccessibilityPermission.isSandboxed
        let accessibilityOK = !accessibilityRequired || AccessibilityPermission.canAutoScroll
        if !recordingOK || !accessibilityOK {
            // Show the full permission set (same as plain capture, the welcome
            // tour, and Settings) so it never looks like fewer permissions
            // exist. Screen Recording always gates; Accessibility gates only
            // when auto-scroll is on; Automation + Microphone are informational.
            showPermissionChecklist(
                PermissionRequirement.captureRequirements(
                    accessibilityRequired: AutoScrollPreference.isEnabled()),
                titleNoun: "Scrolling capture",
                actionLabel: "Done",
                onReady: { })
            endFloatingWindowCapture()
            return
        }
        // One-time coach card; Start Capture re-enters this trigger.
        if !ScrollCaptureCoachPreference.hasShown() {
            endFloatingWindowCapture()
            showScrollCoachCard()
            return
        }
        let hotkeyToken = SignpostMetrics.begin("hotkey-to-overlay")
        gatePermission(
            hotkeyToken: hotkeyToken,
            granted: { [weak self] in
                guard let self else { return }
                self.editor.dismissWithAutoSave()
                self.runScrollSession(hotkeyToken: hotkeyToken)
            },
            retry: { [weak self] in self?.triggerScrollCapture() },
            label: "scroll"
        )
    }

    /// One window for every permission an action needs; the action button
    /// arms when the live checklist is all green and fires `onReady`
    /// (typically re-entering the original trigger).
    private func showPermissionChecklist(
        _ requirements: [PermissionRequirement],
        titleNoun: String,
        actionLabel: String,
        showsOptionalBadge: Bool = true,
        onReady: @escaping () -> Void,
        onCancel: (() -> Void)? = nil
    ) {
        if permissionWindow != nil { return }
        let view = PermissionChecklistView(
            title: requirements.count == 1
                ? "\(titleNoun) needs a permission"
                : "\(titleNoun) needs permissions",
            requirements: requirements,
            actionLabel: actionLabel,
            showsOptionalBadge: showsOptionalBadge,
            onReady: { [weak self] in
                self?.dismissPreflight()
                onReady()
            },
            onCancel: { [weak self] in
                self?.dismissPreflight()
                onCancel?()
            }
        )
        let window = presentCenteredPanel(title: "Sealshot — Permissions", view: view)
        WindowCloseCleanup.onClose(of: window) { [weak self] in
            if self?.permissionWindow === window { self?.permissionWindow = nil }
        }
        permissionWindow = window
    }

    private func runScrollSession(hotkeyToken: SignpostMetrics.Token) {
        Task { @MainActor in
            // Reuse the regular capture's frozen overlay so the scroll-area pick
            // gets the same ⌘-drag adjust as a normal capture — but DRAG-ONLY:
            // no window/boundary click candidates. Making the user draw the
            // area themselves keeps fixed chrome (toolbars, sidebars, sticky
            // headers) out of the stitch region, which whole-window picks
            // dragged in. The freeze is ONLY for picking the region — once it's
            // confirmed the overlay dismisses and ScrollCaptureController records
            // the live, scrolling content in that region.
            let frames: FrozenFrameSet
            do {
                frames = try await FrozenFrameGrabber.captureAll()
            } catch {
                os_log("scroll capture freeze failed: %{public}@", log: log, type: .error,
                       String(describing: error))
                return
            }
            let result = await self.unifiedOverlay.select(
                frames: frames, hints: CrosshairRender.Hints.scroll, dragOnly: true,
                hotkeyToken: hotkeyToken)

            let region: SelectedRegion
            switch result {
            case .region(let r):
                region = r
            case .window(_, _, let span):
                // Unreachable in a drag-only session (no window candidates);
                // treat like a cancel if it ever fires.
                SignpostMetrics.end(span)
                os_log("scroll capture: unexpected window result in drag-only pick",
                       log: log, type: .error)
                self.cancelledCaptureSession()
                return
            case .cancelled:
                os_log("scroll capture cancelled at selection", log: log, type: .info)
                self.cancelledCaptureSession()
                return
            }

            guard let scrollCapture = self.scrollCapture else { return }
            switch await scrollCapture.run(region: region) {
            case .finished(let stitched):
                do {
                    let captured = try await self.capturer.finishCapture(image: stitched, region: region, mode: .scrolling)
                    self.presentCaptured(captured)
                } catch {
                    os_log("scroll capture output failed: %{public}@", log: log, type: .error,
                           String(describing: error))
                }
            case .cancelled:
                os_log("scroll capture cancelled", log: log, type: .info)
                self.cancelledCaptureSession()
            case .accessibilityRevoked:
                // Auto-scroll proved the Accessibility grant is gone (the
                // trigger-time preflight was fooled by the cached trust query).
                // The scroll session is already fully torn down (run() returned
                // via complete → tearDown), so the capture is cancelled here.
                // Do NOT raise the editor now — reshowAfterCancel floats it above
                // and re-fronts on a delay, burying the prompt. Show the SAME
                // full permission checklist as a normal trigger (so the user can
                // also fix anything else missing) as the frontmost window; Start
                // Capture re-runs the flow. Bring the editor back only if the
                // user dismisses the prompt. The Accessibility row reads the
                // revoked latch, so it shows missing despite the stale query.
                os_log("scroll capture: accessibility revoked mid-session — cancelled, re-prompting",
                       log: log, type: .info)
                self.showPermissionChecklist(
                    PermissionRequirement.captureRequirements(accessibilityRequired: true),
                    titleNoun: "Scrolling capture",
                    actionLabel: "Done",
                    // The interrupted scroll is abandoned; "Done" closes the
                    // prompt and restores the editor (which was dismissed when
                    // the session started), mirroring Cancel.
                    onReady: { [weak self] in self?.cancelledCaptureSession() },
                    onCancel: { [weak self] in self?.cancelledCaptureSession() })
            }
        }
    }

    /// Delayed capture: show the on-screen countdown (Esc cancels), then run the
    /// normal unified capture. Duration is the persisted `CaptureDelayPreference`.
    /// Permission is gated HERE, at the click, so the preflight/recovery UI
    /// appears immediately — not as a surprise after the countdown runs out.
    func triggerDelayedCapture() {
        if deferIfMenuTracking(retry: { [weak self] in self?.triggerDelayedCapture() }) { return }
        guard !countdown.isRunning else { return }
        let hotkeyToken = SignpostMetrics.begin("hotkey-to-overlay")
        gatePermission(
            hotkeyToken: hotkeyToken,
            granted: { [weak self] in
                guard let self else { return }
                // The countdown isn't overlay latency — close the span now;
                // the post-countdown unified trigger opens its own.
                SignpostMetrics.end(hotkeyToken)
                // Get the editor out of the way immediately so the countdown is
                // spent arranging the screen to capture, not Sealshot's own window.
                self.editor.dismissWithAutoSave()
                self.countdown.start(
                    seconds: CaptureDelayPreference.current(),
                    onComplete: { [weak self] in
                        // The frozen-hint variant tells the user their staged
                        // menus/tooltips survived the countdown.
                        self?.triggerUnifiedCapture(hints: CrosshairRender.Hints.unifiedFrozen)
                    },
                    onCancel: { [weak self] in
                        os_log("delayed capture cancelled", log: log, type: .info)
                        self?.cancelledCaptureSession()
                    }
                )
            },
            retry: { [weak self] in self?.triggerDelayedCapture() },
            label: "delayed"
        )
    }

    func triggerUnifiedCapture(hints: [String] = CrosshairRender.Hints.unified) {
        if deferIfMenuTracking(retry: { [weak self] in self?.triggerUnifiedCapture(hints: hints) }) { return }
        let hotkeyToken = SignpostMetrics.begin("hotkey-to-overlay")
        gatePermission(
            hotkeyToken: hotkeyToken,
            granted: { [weak self] in
                self?.editor.dismissWithAutoSave()
                self?.runUnifiedSession(hints: hints, hotkeyToken: hotkeyToken)
            },
            retry: { [weak self] in self?.triggerUnifiedCapture(hints: hints) },
            label: "unified"
        )
    }

    private enum FreezeError: Error {
        case noFrozenFrame
        case emptyCrop
    }

    /// Freeze-frame capture: grab every display the moment the session starts,
    /// let the user select on the frozen image, then crop the selection from
    /// those pixels. Moving content is already saved at trigger time, and
    /// anything staged during a delayed-capture countdown (menus, tooltips)
    /// survives into the capture.
    /// Where a unified selection's pixels go: the normal capture pipeline
    /// (library + editor + clipboard, per settings), or straight to a save
    /// panel (⌘⇧S save-as — never joins the library).
    private enum UnifiedDestination { case library, savePanel }

    private func runUnifiedSession(hints: [String], hotkeyToken: SignpostMetrics.Token,
                                   destination: UnifiedDestination = .library) {
        Task { @MainActor in
            // However this session ends — saved, cancelled, or thrown — the
            // floating panel comes back and the editor returns to where it was.
            // `presentCaptured` normally does that, but the save-panel branches
            // return before reaching it, which left the panel hidden for good.
            // Idempotent, so the paths that DO reach it are unaffected.
            defer { self.endFloatingWindowCapture() }
            do {
                let freezeSpan = SignpostMetrics.begin("trigger-to-freeze")
                let frames = try await FrozenFrameGrabber.captureAll()
                SignpostMetrics.end(freezeSpan)

                let result = await self.unifiedOverlay.select(
                    frames: frames, hints: hints, hotkeyToken: hotkeyToken)
                switch result {
                case .region(let region):
                    // The region is global AppKit points; the panel covers the
                    // screen, so screen-relative == view-local.
                    let local = region.globalRect.offsetBy(
                        dx: -region.screen.frame.minX, dy: -region.screen.frame.minY)
                    let image = try self.crop(local, on: region.screen, from: frames)
                    if case .savePanel = destination {
                        self.runSavePanel(for: image)
                        return
                    }
                    let captured = try await self.capturer.finishCapture(
                        image: image, region: region)
                    self.presentCaptured(captured)
                case .window(let win, let screen, let captureSpan):
                    // WYSIWYG: the window's rect cut from the frozen frame —
                    // exactly what was on screen at freeze time.
                    let local = FrozenFrameCrop.windowViewLocalRect(
                        windowFrame: win.frame, screenFrame: screen.frame,
                        primaryMaxY: NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY)
                    let image = try self.crop(local, on: screen, from: frames)
                    SignpostMetrics.end(captureSpan)
                    if case .savePanel = destination {
                        self.runSavePanel(for: image)
                        return
                    }
                    let captured = try self.windowCapturer.finishCapture(
                        image: image, window: win, on: screen)
                    self.presentCaptured(captured)
                case .cancelled:
                    os_log("unified capture cancelled", log: log, type: .info)
                    // Bring the hidden editor back on Esc/cancel — consistent
                    // with every other capture, save-as included.
                    self.cancelledCaptureSession()
                }
            } catch {
                os_log("unified capture failed: %{public}@", log: log, type: .error, String(describing: error))
            }
        }
    }

    /// Save-as output: encode the frozen-frame crop and hand it to the panel.
    private func runSavePanel(for image: CGImage) {
        do {
            _ = try saveAs.runSavePanel(pngData: CaptureOutputWriter.encodePNG(image))
        } catch {
            os_log("save-as panel/write failed: %{public}@",
                   log: log, type: .error, String(describing: error))
        }
    }

    private func crop(_ viewLocal: CGRect, on screen: NSScreen, from frames: FrozenFrameSet) throws -> CGImage {
        guard let frame = frames.frame(for: screen) else { throw FreezeError.noFrozenFrame }
        guard let cropped = FrozenFrameCrop.crop(
            frame.image, viewLocal: viewLocal, viewSize: screen.frame.size) else {
            throw FreezeError.emptyCrop
        }
        return cropped
    }

    // MARK: - New file (File menu, empty-canvas buttons, Library import)

    /// ⌘N — a blank white canvas joins the Library immediately, like a capture
    /// landing: the `.seal` is written now ("New Image <timestamp>"), the
    /// metadata pipeline runs, and the editor presents it through the same path
    /// captures use (which also refreshes the recent strip).
    func openNewCanvas() {
        guard let image = NewCanvasFactory.blank() else { return }
        presentSavedNewImage(image, subject: "New Image", kind: .newCanvas)
    }

    /// ⇧⌘N — a pasted image joins the Library immediately ("Clipboard
    /// <timestamp>"). The menu item is disabled without a clipboard image, but
    /// stale menu validation can still let this fire — fall back to a blank
    /// new canvas.
    func openCanvasFromClipboard() {
        guard let image = NewCanvasFactory.fromClipboard() else {
            openNewCanvas()
            return
        }
        presentSavedNewImage(image, subject: "Clipboard", kind: .clipboard)
    }

    /// Write `image` into the Library now as "<subject> <timestamp>.seal", run
    /// the metadata pipeline, and present it through the capture path. A write
    /// failure degrades to an unsaved scratch session so the image is never
    /// lost.
    private func presentSavedNewImage(_ image: CGImage, subject: String, kind: CaptureKind) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            editor.presentScratchCanvas(image)
            return
        }
        do {
            let saved = try ImageImporter.importImage(
                image, subject: subject,
                saveFolder: config.saveFolder, filenameFormat: config.filenameFormat,
                includeTitle: FilenameIncludesTitlePreference().enabled)
            MetadataCoordinator.shared.start(
                for: saved, sourceApp: nil, windowTitle: subject, captureKind: kind)
            let png = (try? CaptureOutputWriter.encodePNG(image)) ?? Data()
            editor.present(CaptureResult(
                image: image, pngData: png,
                pixelSize: CGSize(width: image.width, height: image.height),
                screen: screen, clipboardWritten: false, savedFileURL: saved))
        } catch {
            os_log("%{public}@ save failed, opening scratch: %{public}@",
                   log: log, type: .error, subject, String(describing: error))
            editor.presentScratchCanvas(image)
        }
    }

    /// File ▸ Insert Image on Canvas… — place an image overlay onto the
    /// currently-open canvas (same action as the editor toolbar `+` menu).
    func insertImageOnCanvas() {
        editor.insertImageOnCanvas()
    }

    /// ⌘O — pick image files and copy them into the Library as .seal
    /// packages. One success opens in the editor; several reveal in the
    /// Library; failures collect into a single summary alert.
    func presentImportPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        // Enable selectable files via the delegate rather than
        // `allowedContentTypes`: under the app sandbox the panel silently greys
        // out some newer image UTIs (WebP, AVIF) even when they're listed and
        // conform. The delegate enables by extension, which is reliable.
        let gate = ImportPanelGate()
        panel.delegate = gate   // strong local ref keeps it alive across runModal (synchronous)
        panel.message = "Choose images, videos, or a Sealshot package (.sealshare) to import"
        panel.prompt = "Import"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        importFiles(panel.urls)
    }

    /// Plan on the main actor (large-PDF prompts), then execute on a
    /// background task under a progress panel with cooperative Cancel.
    /// Already-imported files survive a cancel.
    /// `revealInLibrary`: the import came from a Library drop — surface the
    /// result there (batch-selected + highlighted) instead of the editor.
    func importFiles(_ urls: [URL], revealInLibrary: Bool = false) {
        let packages = urls.filter { $0.pathExtension.lowercased() == "sealshare" }
        for pkg in packages { ImportPackageCoordinator.open(url: pkg, host: NSApp.keyWindow) }
        // A `.seal` IS a capture — it doesn't need converting, it needs
        // adopting. Sending one through the image importer only ever produced
        // "couldn't be imported", because the importer decodes images and a
        // capture package is not one.
        let seals = urls.filter { $0.pathExtension.lowercased() == "seal" }
        for seal in seals { adoptCapture(seal) }
        let rest = urls.filter {
            let ext = $0.pathExtension.lowercased()
            return ext != "sealshare" && ext != "seal"
        }
        guard !rest.isEmpty else { return }
        let plan = ImageImporter.makePlan(rest, confirmLargeImport: { name, pages in
            let alert = NSAlert()
            alert.messageText = "Import large PDF?"
            alert.informativeText =
                "\(name) has \(pages) pages. Each page becomes its own capture in your library."
            alert.addButton(withTitle: "Import \(pages) Pages")
            alert.addButton(withTitle: "Skip")
            return alert.runModal() == .alertFirstButtonReturn
        })
        guard !plan.items.isEmpty || !plan.failures.isEmpty else { return }

        let panel = ImportProgressPanel(totalUnits: plan.totalUnits)
        let cancelFlag = ImportCancelFlag()
        panel.onCancel = { cancelFlag.cancel() }
        panel.show()

        let saveFolder = config.saveFolder
        let filenameFormat = config.filenameFormat
        Task(priority: .userInitiated) { @MainActor [weak self] in
            let outcome = await ImageImporter.execute(
                plan, saveFolder: saveFolder, filenameFormat: filenameFormat,
                includeTitle: FilenameIncludesTitlePreference().enabled,
                isCancelled: { cancelFlag.isCancelled },
                onUnitDone: { done, total, filename in
                    panel.update(done: done, total: total, filename: filename)
                },
                startMetadata: { seal, basename in
                    MetadataCoordinator.shared.start(
                        for: seal, sourceApp: nil, windowTitle: basename,
                        captureKind: .importedImage)
                })
            self?.finishImport(outcome, panel: panel, revealInLibrary: revealInLibrary)
        }
    }

    /// Open a `.seal` that came from outside — Finder's "Open With", a
    /// double-click, a drop.
    ///
    /// One already inside the library (or the Scratch waiting room) is simply
    /// opened: copying it would leave the user with two of the same capture.
    /// One from elsewhere is copied in first, honouring the scratch toggle, so
    /// opening a capture off a USB stick doesn't leave the editor pointed at a
    /// file that may vanish.
    func adoptCapture(_ url: URL) {
        if isInsideLibrary(url) {
            editor.presentFile(url)
            return
        }
        let destinationFolder = ScratchCapture.destination(
            saveFolder: config.saveFolder,
            addToLibrary: ScratchCapturePreference().addsToLibrary)
        do {
            try FileManager.default.createDirectory(
                at: destinationFolder, withIntermediateDirectories: true)
            let base = url.deletingPathExtension().lastPathComponent
            let name = CaptureConfig.uniqueName(base: base, ext: "seal") { candidate in
                FileManager.default.fileExists(
                    atPath: destinationFolder.appendingPathComponent(candidate).path)
            }
            let dest = destinationFolder.appendingPathComponent(name, isDirectory: false)
            try FileManager.default.copyItem(at: url, to: dest)
            Self.stampAsImported(dest)
            // Scratch captures are deliberately unannounced — that notification
            // IS library membership (index, strips, ⌘Z).
            if !ScratchCapture.isScratch(dest) {
                NotificationCenter.default.post(name: .captureFilesImported, object: [dest],
                                                userInfo: ["kind": "capture"])
            }
            editor.presentFile(dest)
            os_log("adopted capture %{public}@ -> %{public}@", log: log, type: .info,
                   url.lastPathComponent, dest.lastPathComponent)
        } catch {
            os_log("adopt capture failed %{public}@: %{public}@", log: log, type: .error,
                   url.lastPathComponent, String(describing: error))
            // Opening it in place still shows the user their capture; it just
            // isn't theirs to keep.
            editor.presentFile(url)
        }
    }

    /// Date an adopted capture as of NOW, and label how it arrived — see
    /// `SealMetadataStore.stampAsAdopted` for why. Best-effort: a capture that
    /// cannot be re-stamped is still adopted, just filed by its old date.
    private static func stampAsImported(_ url: URL) {
        do {
            try SealMetadataStore.stampAsAdopted(at: url, kind: .importedImage)
        } catch {
            os_log("adopt: could not re-stamp %{public}@: %{public}@", log: log, type: .error,
                   url.lastPathComponent, String(describing: error))
        }
    }

    /// Whether `url` already lives in this library — its root, the Scratch
    /// waiting room, the trash, or the recordings folder.
    private func isInsideLibrary(_ url: URL) -> Bool {
        let parent = url.deletingLastPathComponent().standardizedFileURL.path
        let save = config.saveFolder.standardizedFileURL.path
        let known = [
            save,
            ScratchCapture.folder(under: config.saveFolder).standardizedFileURL.path,
            config.saveFolder.appendingPathComponent(SealDeleter.deletedSubfolderName)
                .standardizedFileURL.path,
            RecordingsLibrary.folder(forSaveFolder: config.saveFolder).standardizedFileURL.path,
        ]
        return known.contains(parent)
    }

    private func finishImport(_ outcome: ImageImporter.Outcome,
                              panel: ImportProgressPanel,
                              revealInLibrary: Bool = false) {
        panel.close()
        if !outcome.failures.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Some files couldn't be imported"
            alert.informativeText = outcome.failures
                .map { $0.url.lastPathComponent }.joined(separator: "\n")
            alert.runModal()
        }
        if !outcome.imported.isEmpty {
            NotificationCenter.default.post(name: .captureFilesImported,
                                            object: outcome.imported)
        }
        // Cancelled or not: surface whatever landed. A Library-originated
        // drop stays in the Library (whole batch selected + highlighted);
        // everything else keeps the open-editor / reveal-first behavior.
        if revealInLibrary {
            editor.revealImportedInLibrary(outcome.imported)
        } else if outcome.imported.count == 1, !outcome.cancelled {
            editor.presentFile(outcome.imported[0])
        } else if let first = outcome.imported.first {
            editor.revealInLibrary(first)
        }
    }

    // MARK: - Open editor (⌘⇧E)

    func triggerOpenEditor() {
        // No permission gate: opening the editor reads previously-saved
        // files from `config.saveFolder`. Doesn't touch SCK.
        editor.presentMostRecent()
        onEditorOpened()
    }

    /// The Dock icon was clicked while Sealshot is already running. Differs
    /// from `triggerOpenEditor` in that it does not force the Editor tab — a
    /// Dock click shows the app, it does not pick a tab for the user. It is
    /// still an "opened the editor" event, so the panel's count resets the same
    /// way it does for every other route.
    func triggerReopenFromDock() {
        editor.reopenFromDock()
        onEditorOpened()
    }

    /// The editor became visible. Every route that opens it — ⌘⇧E, the menu
    /// bar, the Dock, the floating window's ⤢ — funnels through
    /// `triggerOpenEditor` or `triggerReopenFromDock`, so hooking here is what
    /// makes the floating panel's count mean "since you last opened the editor"
    /// whichever way you opened it.
    var onEditorOpened: () -> Void = {}

    /// Open the editor and switch to its Settings tab (the menu-bar item's
    /// Settings… row — Sealshot has no standalone preferences window).
    func triggerOpenSettings() {
        // Settings is a locked-out surface (the menu-bar row disables while
        // locked, and every File-menu route guards on it). Defence in depth —
        // the license gate routes through `presentCreationBlocked()` instead.
        guard !Self.isLocked else { return }
        editor.presentSettings()
    }

    /// Nothing refuses a capture any more — Sealshot is free to use. Kept only
    /// as the place the LOCK still speaks from: a locked library pauses capture
    /// for a reason that has nothing to do with licensing.
    func presentCreationBlocked() {
        endFloatingWindowCapture()
        guard Self.isLocked else { return }
        editor.presentLockedNotice(
            "Sealshot is locked, so new captures and recordings are paused. "
            + "Unlock to carry on — your existing captures are untouched.")
    }

    /// Wire the editor toolbar's record buttons to the recording coordinator
    /// (owned by AppDelegate, separate from capture), so the toolbar can start
    /// a full-screen or selected-area recording.
    func setRecordingActions(onRecordScreen: @escaping (DisplayChoice?) -> Void,
                             onRecordSelection: @escaping () -> Void) {
        editor.setOnRecordScreenRequested(onRecordScreen)
        editor.setOnRecordSelectionRequested(onRecordSelection)
    }

    /// Hide the editor when a recording begins (any entry point: toolbar button,
    /// ⇧⌘V, or the selection-recording shortcut) so it isn't recorded or under
    /// the selection picker.
    func hideEditorForRecording() { editor.dismissWithAutoSave() }

    /// Re-show the editor after a cancelled recording (selection or countdown).
    func reshowEditorAfterCancel() { cancelledCaptureSession() }

    /// Recording's permission checklist — the same shared full list as still
    /// capture (Screen Recording gates; Accessibility/Automation/Microphone are
    /// informational), shown before the recording-setup prompt instead of a raw
    /// ScreenCaptureKit error. `retry` re-enters the recording once granted.
    func showRecordingChecklist(retry: @escaping () -> Void) {
        showPermissionChecklist(PermissionRequirement.captureRequirements(),
                                titleNoun: "Recording", actionLabel: "Start Recording",
                                showsOptionalBadge: false, onReady: retry)
    }

    // MARK: - Fullscreen (⌘⇧F)

    private var displayPicker: DisplayPickerController?

    /// `choice` nil + a single display = capture it directly. `choice` nil + MULTIPLE
    /// displays = show the click-a-monitor overlay (⌘-click = All Displays). An
    /// explicit `.display(i)`/`.allDisplays` bypasses the overlay.
    func triggerFullscreenCapture(choice: DisplayChoice? = nil) {
        if deferIfMenuTracking(retry: { [weak self] in self?.triggerFullscreenCapture(choice: choice) }) { return }
        let outputToken = SignpostMetrics.begin("hotkey-to-fullscreen-output")
        gatePermission(
            hotkeyToken: outputToken,
            granted: { [weak self] in
                guard let self else { return }
                self.editor.dismissWithAutoSave()
                if choice == nil, NSScreen.screens.count > 1 {
                    let picker = DisplayPickerController()
                    self.displayPicker = picker
                    Task { @MainActor in
                        let pick = await picker.pick(allowAllDisplays: true, freeze: true)
                        self.displayPicker = nil
                        guard let pick, let frozen = pick.frozenImage else {
                            // Esc/cancel: bring the hidden editor back, like the
                            // other capture cancels.
                            SignpostMetrics.end(outputToken)
                            self.cancelledCaptureSession()
                            return
                        }
                        do {
                            // Capture from the frozen snapshot the user picked.
                            let result = try await self.fullscreenCapturer.capture(
                                frozenImage: frozen, reference: pick.reference, screen: pick.screen)
                            SignpostMetrics.end(outputToken)
                            self.presentCaptured(result)
                        } catch {
                            SignpostMetrics.end(outputToken)
                            os_log("fullscreen capture (frozen) failed: %{public}@",
                                   log: log, type: .error, String(describing: error))
                        }
                    }
                } else {
                    self.runFullscreenCaptureSession(choice: choice, outputToken: outputToken)
                }
            },
            retry: { [weak self] in self?.triggerFullscreenCapture(choice: choice) },
            label: "fullscreen"
        )
    }

    private func runFullscreenCaptureSession(choice: DisplayChoice?, outputToken: SignpostMetrics.Token) {
        Task { @MainActor in
            do {
                let result: CaptureResult
                switch choice {
                case .allDisplays:
                    result = try await self.fullscreenCapturer.captureAllDisplays()
                case .display(let index):
                    let screens = NSScreen.screens
                    let screen = (screens.indices.contains(index) ? screens[index] : nil)
                        ?? self.cursorScreen() ?? NSScreen.main
                    guard let screen else { throw CaptureFailure.noScreen }
                    result = try await self.fullscreenCapturer.capture(on: screen)
                case nil:
                    guard let screen = self.cursorScreen() ?? NSScreen.main else { throw CaptureFailure.noScreen }
                    result = try await self.fullscreenCapturer.capture(on: screen)
                }
                SignpostMetrics.end(outputToken)
                self.presentCaptured(result)
            } catch {
                SignpostMetrics.end(outputToken)
                os_log("fullscreen capture failed: %{public}@",
                       log: log, type: .error, String(describing: error))
            }
        }
    }

    private enum CaptureFailure: Error { case noScreen }

    private func cursorScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        let screens = NSScreen.screens
        let bounds = screens.enumerated().map { idx, screen in
            DisplayBounds(id: idx, frame: screen.frame)
        }
        guard let hit = displayContainingPoint(mouse, in: bounds) else {
            os_log("fullscreen: cursor outside all displays; falling back to NSScreen.main",
                   log: log, type: .info)
            return nil
        }
        return screens[hit.id]
    }

    // MARK: - Save-as (⌘⇧S)

    func triggerSaveAsCapture() {
        if deferIfMenuTracking(retry: { [weak self] in self?.triggerSaveAsCapture() }) { return }
        // Same unified freeze-frame overlay as ⌘⇧C (hover window/page-body
        // boundary detection, click-or-drag) — only the destination differs:
        // the crop goes to a save panel and never joins the library.
        let hotkeyToken = SignpostMetrics.begin("hotkey-to-overlay")
        gatePermission(
            hotkeyToken: hotkeyToken,
            granted: { [weak self] in
                self?.editor.dismissWithAutoSave()
                // save-as has no editor re-show; the hidden window reappears on next capture / Dock reopen
                self?.runUnifiedSession(hints: CrosshairRender.Hints.unified,
                                        hotkeyToken: hotkeyToken,
                                        destination: .savePanel)
            },
            retry: { [weak self] in self?.triggerSaveAsCapture() },
            label: "save-as"
        )
    }

    // MARK: - Permission gate (shared)

    /// Gates on the instant preflight so the overlay appears with zero
    /// added latency — a synchronous ScreenCaptureKit verification here
    /// cost a visible pause before the overlay (worst on the first capture
    /// after launch), long enough that the user's first drag landed before
    /// the overlay existed. The honest SCK check runs in the BACKGROUND:
    /// if it disagrees (mid-run revocation / grant not applied yet), the
    /// just-started session fails anyway, and the checklist surfaces right
    /// behind it instead of silence.
    private func gatePermission(
        hotkeyToken: SignpostMetrics.Token,
        granted: @escaping () -> Void,
        retry: @escaping () -> Void,
        label: String
    ) {
        // One session at a time: while a capture session or a recording is in
        // progress, new triggers are eaten before touching any permission UI.
        if blockedByActiveSession(label) {
            SignpostMetrics.end(hotkeyToken)
            return
        }
        permission.refresh()   // keep the Settings permissions row honest
        if CGPreflightScreenCaptureAccess() {
            os_log("capture %{public}@ triggered (granted)", log: log, type: .info, label)
            granted()
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard await !ScreenRecordingPermission.liveGranted() else { return }
                os_log("capture %{public}@: SCK disagrees with preflight — surfacing checklist",
                       log: log, type: .error, label)
                self.showCaptureChecklist(retry: retry)
            }
            return
        }
        os_log("capture %{public}@ blocked on Screen Recording", log: log, type: .info, label)
        SignpostMetrics.end(hotkeyToken)
        showCaptureChecklist(retry: retry)
    }

    /// Checklist for the plain captures: Screen Recording gates; the
    /// Accessibility row is informational (status only — nothing here
    /// auto-scrolls).
    private func showCaptureChecklist(retry: @escaping () -> Void) {
        // Show the full permission set (matching the welcome tour and Settings)
        // so it never looks like fewer permissions exist; only Screen Recording
        // gates the Capture action. No optional/required badges here — each row
        // just shows its explanation.
        showPermissionChecklist(PermissionRequirement.captureRequirements(),
                                titleNoun: "Capturing", actionLabel: "Capture",
                                showsOptionalBadge: false, onReady: retry)
    }

    // MARK: - Permission panels

    /// Shared chrome for the permission/coach panels. The content size must
    /// be fixed BEFORE positioning: the hosting view only sizes the window
    /// when shown, and a post-show resize is top-left anchored, which drags
    /// the window toward the upper right (and squeezes the text). Mirrors
    /// the welcome window. Placed at the true screen center — NSWindow's
    /// `center()` sits noticeably above it.
    private func presentCenteredPanel<V: View>(title: String, view: V) -> NSWindow {
        let hosting = NSHostingController(rootView: view)
        // The window size is fixed explicitly below (setContentSize). Disable
        // the hosting controller's automatic window-size tracking: the
        // permission checklist live-polls and re-renders when a permission is
        // granted, and letting that drive updateWindowContentSizeExtrema during
        // the display cycle re-enters constraint updating and crashes on
        // macOS 26. Mirrors the editor's NSHostingView usage.
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable]
        window.title = title
        window.isReleasedWhenClosed = false
        // sizingOptions = [] (crash guard) also zeroes the live hosting view's
        // fittingSize, so measure the natural content size with a throwaway
        // hosting view that still reports it — otherwise the window centers off
        // a zero width and lands with its left edge at screen center.
        window.setContentSize(NSHostingView(rootView: view).fittingSize)
        if let screen = NSScreen.main {
            let v = screen.visibleFrame
            let size = window.frame.size
            window.setFrameOrigin(NSPoint(
                x: v.midX - size.width / 2, y: v.midY - size.height / 2))
        }
        // These panels open while another app is active (global hotkey), and
        // cooperative activation can be denied — which would leave the panel
        // buried under the active app. Float it to the very front regardless
        // of activation, then settle back to the normal level (same raise
        // trick as the editor windows).
        window.level = .floating
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { window.level = .normal }
        return window
    }

    private func dismissPreflight() {
        permissionWindow?.close()
        permissionWindow = nil
    }

    // MARK: - First-launch welcome

    /// Shows the one-time welcome window (privacy tour, shortcuts, Screen
    /// Recording walkthrough). Called by the app delegate after launch UI.
    ///
    /// The window itself is owned by `WelcomeTourPresenter`, which Settings ▸
    /// Startup ▸ "Show Now" also drives; this method only applies the
    /// first-launch gate.
    func showWelcomeIfNeeded() {
        guard !WelcomePreference.hasShown() else { return }
        WelcomeTourPresenter.present(above: editor.hostWindow)
    }

    // MARK: - Scroll-capture coach card (first use only)

    private func showScrollCoachCard() {
        if permissionWindow != nil { return }
        let view = ScrollCaptureCoachView(
            autoScrollAvailable: AutoScrollPreference.isEnabled()
                && AccessibilityPermission.canAutoScroll,
            onStart: { [weak self] in
                ScrollCaptureCoachPreference.markShown()
                self?.dismissPreflight()
                self?.triggerScrollCapture()
            },
            onCancel: { [weak self] in
                ScrollCaptureCoachPreference.markShown()
                self?.dismissPreflight()
            }
        )
        let window = presentCenteredPanel(title: "Sealshot — Scrolling Capture", view: view)
        WindowCloseCleanup.onClose(of: window) { [weak self] in
            if self?.permissionWindow === window { self?.permissionWindow = nil }
        }
        permissionWindow = window
    }
}

/// Open-panel delegate that enables importable image files by extension, plus
/// folders (for navigation) and `.sealshare` packages. Used instead of
/// `allowedContentTypes`, which the sandbox panel greys out for some newer
/// image UTIs (WebP, AVIF) even when listed.
private final class ImportPanelGate: NSObject, NSOpenSavePanelDelegate {
    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return false }
        if isDir.boolValue { return true }   // allow entering folders
        return ImageImporter.isImportable(url) || url.pathExtension.lowercased() == "sealshare"
    }
}
