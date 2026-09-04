import AppKit
import os.log
import RedactionEngineInterface

private let log = OSLog(subsystem: "com.seal-shot.sealshot", category: "editor")

@MainActor
final class EditorController {

    private let config: CaptureConfig
    private let saver: EditorSaveCoordinator
    private let enhancer = ImageEnhancer()
    private var windowController: EditorWindowController?
    private var windowCloseObserver: NSObjectProtocol?

    /// The tab the window was showing when it last went away, so a Dock-click
    /// reopen comes back to it. In memory on purpose — it is NOT persisted, so
    /// a relaunch starts on `ShellTab.launchTab` (the Editor).
    private var lastSelectedTab: ShellTab = ShellTab.launchTab
    /// Observers that persist the editor window's frame as the user moves/resizes
    /// it, so it reopens where it was left. Removed when the window closes.
    private var frameSaveObservers: [NSObjectProtocol] = []
    private var unlockObserver: NSObjectProtocol?
    private var recordingFinishObserver: NSObjectProtocol?
    private var saveFolderObserver: NSObjectProtocol?
    /// Set when an open was deferred because the session was locked; on the
    /// next unlock we load the most recent capture into the waiting window.
    private var deferredRecentDueToLock = false
    private var onCaptureRequested: () -> Void
    private var onWindowCaptureRequested: () -> Void = {}
    private var onUnifiedCaptureRequested: () -> Void = {}
    private var onDelayedCaptureRequested: () -> Void = {}
    private var onScrollCaptureRequested: () -> Void = {}
    private var onLiveCaptureRequested: () -> Void = {}
    private var onFullscreenCaptureRequested: (DisplayChoice?) -> Void = { _ in }
    private var onRecordScreenRequested: (DisplayChoice?) -> Void = { _ in }
    private var onRecordSelectionRequested: () -> Void = {}
    private var onNewCanvasRequested: () -> Void = {}
    private var onNewFromClipboardRequested: () -> Void = {}
    private var onImportRequested: () -> Void = {}
    private var onImportFilesRequested: ([URL], Bool) -> Void = { _, _ in }
    private var isEnhancing = false
    /// The in-flight enhance, retained so the overlay's Cancel button can stop it.
    private var enhanceTask: Task<Void, Never>?
    /// The in-flight smart-redaction scan; re-tapping the pill cancels it.
    private var redactionScanTask: Task<Void, Never>?
    /// Loads + caches the arm64-only GLiNER2 plugin engine (nil → rule fallback).
    private let redactionEngineLoader = RedactionEngineLoader()
    /// Manages background download of the optional enhanced redaction model.
    private var redactionModelManager: RedactionModelManager { .shared }

    init(config: CaptureConfig, onCaptureRequested: @escaping () -> Void = {}) {
        self.config = config
        self.saver = EditorSaveCoordinator(config: config)
        self.onCaptureRequested = onCaptureRequested
        // When the session unlocks, load the capture we deferred while locked
        // so the empty placeholder window becomes the most-recent capture.
        unlockObserver = NotificationCenter.default.addObserver(
            forName: .encryptionLockStateDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.loadDeferredRecentIfUnlocked() }
        }
        // When a recording finishes, bring up the editor and play the just-
        // captured video in the canvas (the coordinator posts the file URL).
        recordingFinishObserver = NotificationCenter.default.addObserver(
            forName: .recordingDidFinish, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let url = note.object as? URL else { return }
                // A recording the floating panel started is handed back instead
                // of played here: taking over the editor is exactly what that
                // panel exists to avoid, and it is the same promise a still
                // capture from the panel already keeps.
                if self.suppressNextRecordingPresentation {
                    self.suppressNextRecordingPresentation = false
                    self.onSuppressedRecordingFinished?(url)
                    return
                }
                self.presentRecording(url: url)
            }
        }
        // The save folder moved: whatever is on the canvas belongs to the OLD
        // library, so keeping it open leaves the editor showing a file the app
        // no longer lists. Swap to the empty editor.
        saveFolderObserver = NotificationCenter.default.addObserver(
            forName: .saveFolderDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleSaveFolderChange() }
        }
    }

    deinit {
        if let unlockObserver { NotificationCenter.default.removeObserver(unlockObserver) }
        if let recordingFinishObserver { NotificationCenter.default.removeObserver(recordingFinishObserver) }
        if let saveFolderObserver { NotificationCenter.default.removeObserver(saveFolderObserver) }
    }

    /// Close the open capture when the library moves. Pending edits are flushed
    /// to the OLD folder first — they were made against a file that lives
    /// there, and dropping them silently would lose work. The remembered
    /// selection is cleared too: the old file still exists on disk, so
    /// `LastSelectedCapturePreference`'s existence check would happily reopen
    /// it from the previous library on the next launch.
    private func handleSaveFolderChange() {
        autoSaveIfDirty()
        LastSelectedCapturePreference.store(nil)
        guard windowController != nil else { return }
        replaceWithEmptyWindow()
    }

    /// The on-screen editor window, or nil when none is open. Read-only: it
    /// lets the first-launch welcome tour attach itself above the editor
    /// without handing out the window controller.
    var hostWindow: NSWindow? { windowController?.window }

    /// What the editor's `pip` toolbar button does. Held here (not on the
    /// window controller) because the window is torn down and rebuilt, and the
    /// wiring has to survive that.
    var onToggleFloatingWindow: (() -> Void)? {
        didSet { windowController?.onToggleFloatingWindow = onToggleFloatingWindow }
    }

    /// Keep the `pip` button's state readout honest whichever route toggled the
    /// panel — the toolbar button or the View menu.
    private(set) var floatingWindowIsOpen = false

    func setFloatingWindowOpen(_ open: Bool) {
        floatingWindowIsOpen = open
        windowController?.setFloatingWindowOpen(open)
    }

    private func loadDeferredRecentIfUnlocked() {
        guard deferredRecentDueToLock, EncryptionSession.shared.isUnlocked else { return }
        deferredRecentDueToLock = false
        Task { @MainActor in
            // Open the newest capture from the INDEX (authoritative, and the same
            // ordering the strip shows). `findRecentCaptures` reads the plaintext
            // manifest.json, which is ENCRYPTED here, so it falls back to the
            // filesystem date and would open the most-recently-EDITED file rather
            // than the newest capture — leaving the canvas out of sync with the
            // highlighted strip tile.
            let recordingsFolder = RecordingsLibrary.folder(forSaveFolder: config.saveFolder)
            let items = await LibraryIndexStore.shared.stripItems(
                folder: config.saveFolder, recordingsFolder: recordingsFolder,
                coveringDays: 7, now: Date())
            let indexNewest = items?.first(where: { !$0.isVideo })?.url
            let finderNewest = findRecentCaptures(in: config.saveFolder, coveringDays: 7).first
            openOnLaunch(newest: indexNewest ?? finderNewest)
        }
    }

    /// Open the capture to show on launch: the one remembered from last session
    /// (when it still exists and isn't trashed), else `newest`.
    ///
    /// A remembered VIDEO: build a full editor with an image first (`presentFile`
    /// creates the state, sidebar, and enabled Info/Share), THEN play the video
    /// over it (paused, no autoplay). The video's sidebar/Info/Share attach to a
    /// live editor state — exactly what clicking a video in a running session
    /// relies on — so opening a video straight into a fresh EMPTY editor leaves it
    /// with no sidebar and disabled controls. A remembered image opens directly.
    private func openOnLaunch(newest: URL?) {
        let remembered = LastSelectedCapturePreference.load(
            deletedFolderName: SealDeleter.deletedSubfolderName)
        WindowDiag.note("openOnLaunch: remembered=\(remembered?.lastPathComponent ?? "none") "
                        + "newest=\(newest?.lastPathComponent ?? "none")")
        guard let remembered else {
            if let newest { presentFile(newest) } else { presentEmpty() }
            return
        }
        // A recording is a `.seal` PACKAGE (extension "seal"), not a bare
        // mov/mp4 — so the video-ness lives in the manifest's captureKind, the
        // same check presentFile uses to route to presentRecording. The old
        // extension-only test missed video .seals entirely.
        let ext = remembered.pathExtension.lowercased()
        let isVideo = RecordingsLibrary.videoExtensions.contains(ext)
            || (ext == "seal" && {
                guard let m = try? SealMetadataStore.readManifest(at: remembered) else { return false }
                return m.captureKind == .screenRecording || m.captureKind == .importedVideo
            }())
        if isVideo {
            if let newest { presentFile(newest) } else { presentEmpty() }
            windowController?.playVideoInCanvas(url: remembered)
        } else {
            presentFile(remembered)   // .seal or image
        }
    }

    func setOnCaptureRequested(_ closure: @escaping () -> Void) {
        self.onCaptureRequested = closure
    }

    func setOnWindowCaptureRequested(_ closure: @escaping () -> Void) {
        self.onWindowCaptureRequested = closure
    }

    func setOnUnifiedCaptureRequested(_ closure: @escaping () -> Void) {
        self.onUnifiedCaptureRequested = closure
    }

    func setOnDelayedCaptureRequested(_ closure: @escaping () -> Void) {
        self.onDelayedCaptureRequested = closure
    }

    func setOnScrollCaptureRequested(_ closure: @escaping () -> Void) {
        self.onScrollCaptureRequested = closure
    }

    func setOnLiveCaptureRequested(_ closure: @escaping () -> Void) {
        self.onLiveCaptureRequested = closure
    }

    func setOnFullscreenCaptureRequested(_ closure: @escaping (DisplayChoice?) -> Void) {
        self.onFullscreenCaptureRequested = closure
    }

    func setOnRecordScreenRequested(_ closure: @escaping (DisplayChoice?) -> Void) {
        self.onRecordScreenRequested = closure
    }

    func setOnRecordSelectionRequested(_ closure: @escaping () -> Void) {
        self.onRecordSelectionRequested = closure
    }

    func setOnNewCanvasRequested(_ closure: @escaping () -> Void) {
        self.onNewCanvasRequested = closure
    }

    func setOnNewFromClipboardRequested(_ closure: @escaping () -> Void) {
        self.onNewFromClipboardRequested = closure
    }

    func setOnImportRequested(_ closure: @escaping () -> Void) {
        self.onImportRequested = closure
    }

    func setOnImportFilesRequested(_ closure: @escaping ([URL], Bool) -> Void) {
        self.onImportFilesRequested = closure
    }

    /// Reveal a freshly imported batch in the Library tab (drop-to-import
    /// from the Library stays in the Library).
    func revealImportedInLibrary(_ urls: [URL]) {
        if windowController == nil { presentEmpty() }
        windowController?.revealImportedInLibrary(urls)
        windowController?.window?.makeKeyAndOrderFront(nil)
    }

    /// Forward the File-menu Insert Image command to the active editor window.
    func insertImageOnCanvas() {
        windowController?.insertImageOnCanvas()
    }

    // Menu (View) actions — forwarded to the active editor window; no-op when
    // no window is open.
    func zoomIn() { windowController?.zoomIn() }
    func zoomOut() { windowController?.zoomOut() }
    /// Menu-bar Edit▸Duplicate; the actual work (with the canvas-focus guard)
    /// happens in `EditorWindowController.duplicateSelection()`.
    func duplicateSelection() { windowController?.duplicateSelection() }
    /// Menu-bar Edit▸Arrange; the canvas-focus guard lives in
    /// `EditorWindowController.reorderSelection(_:)`.
    func reorderSelection(_ op: ZOrderOperation) { windowController?.reorderSelection(op) }
    /// Menu-bar Edit▸Flip; the canvas-focus guard lives in
    /// `EditorWindowController.flipSelection(horizontal:)`.
    func flipSelection(horizontal: Bool) { windowController?.flipSelection(horizontal: horizontal) }
    func zoomActualSize() { windowController?.zoomActualSize() }
    func fitWindow() { windowController?.fitWindow() }
    func fitWidth() { windowController?.fitWidth() }
    func fitHeight() { windowController?.fitHeight() }
    func toggleInfoPanel() { windowController?.toggleInfoPanel() }
    func toggleRecentStrip() { windowController?.toggleRecentStrip() }
    func exportCurrent() { windowController?.exportCurrent() }
    func exportAsPackage() { windowController?.exportAsPackage() }

    func present(_ result: CaptureResult) {
        let state = EditorState(
            sourceImage: result.image,
            sourceURL: result.savedFileURL
        )
        // Tool defaults to neutral .select; swap() carries the prior tool across
        // when an editor window is already open.
        let title = result.savedFileURL?.lastPathComponent ?? "Sealshot Capture"

        if let controller = windowController {
            // A freshly captured image always fits to the viewport, ignoring the
            // remembered zoom used for image switches.
            controller.swap(toState: state, title: title, fitFresh: true)
            controller.selectTab(.editor)
            // New capture: rebuild the strip so it shows up immediately.
            controller.refreshRecentStrip()
            if let window = controller.window { raiseAboveOtherApps(window) }
            wireEnhance(on: controller, title: title)
            autoScanIfEnabled(on: controller)
            return
        }

        let screenFrame = result.screen.visibleFrame
        presentState(state, on: screenFrame, title: title, fitFresh: true)
        if let controller = windowController {
            wireEnhance(on: controller, title: title)
            autoScanIfEnabled(on: controller)
        }
    }

    /// Wire the Enhance panel's Apply button (run the model with the current
    /// draft params, keeping the canonical source + annotations) and the
    /// Original/Enhanced flip control.
    private func wireEnhance(on controller: EditorWindowController, title: String) {
        // Keep gesture for a scratch capture: move it into the Library. Wired
        // here because every controller-construction path already runs through
        // wireEnhance, so no present() route can forget it.
        controller.onAddToLibraryRequested = { [weak self] url in
            self?.addScratchCaptureToLibrary(url)
        }
        // Enhance panel Apply: runs the enhancer with the current `enhanceDraft`
        // params (not .default). Wired to sidebar.onEnhanceApply via
        // controller.onEnhanceApply, which fires from both the Apply button and
        // the auto-run triggered when the Enabled switch is turned on with no
        // existing enhanced image.
        controller.onEnhanceApply = { [weak self, weak controller] in
            guard let self, let controller, let state = controller.state else { return }
            self.runEnhanceApply(controller: controller, state: state)
        }
        // Cancel any in-flight enhance run (e.g. user turns the switch OFF mid-run).
        controller.onEnhanceCancel = { [weak self] in
            self?.enhanceTask?.cancel()
        }
        // Swapping captures makes an in-flight redaction scan stale — its result
        // belongs to the capture the user just left.
        controller.onRedactionScanCancel = { [weak self] in
            self?.redactionScanTask?.cancel()
        }
    }

    /// Run the image enhancer with `state.enhanceDraft` params, reusing the
    /// existing overlay/task plumbing. On success updates `state.enhancedImage`,
    /// `state.enhanceParams`, and marks the document dirty.
    private func runEnhanceApply(controller: EditorWindowController, state: EditorState) {
        guard !isEnhancing else { return }
        isEnhancing = true
        state.enhanceRunning = true
        let progress = EnhanceProgress()
        controller.showEnhancingOverlay(progress: progress, onCancel: { [weak self] in
            self?.enhanceTask?.cancel()
        })
        let params = state.enhanceDraft   // snapshot before the async hop
        enhanceTask = Task { @MainActor [weak self, weak controller, weak state] in
            // The overlay is this task's to clean up, on EVERY exit — declared
            // above the weak-capture guard below, which returns without running
            // any `defer` placed after it. A state deallocated before the task
            // ran used to leave "Enhancing…" on the canvas with the toolbar and
            // tabs frozen behind it, unrecoverable short of relaunching.
            defer { controller?.hideEnhancingOverlay() }
            guard let self, let controller, let state else { return }
            defer {
                self.isEnhancing = false
                self.enhanceTask = nil
                state.enhanceRunning = false
            }
            do {
                let enhanced = try await self.enhancer.enhance(
                    state.sourceImage, params: params,
                    onProgress: { f in Task { @MainActor in progress.fraction = f } })
                // A cancel can race the final await and still deliver a
                // result — honor the user's cancel: don't install, revert the
                // switch, drop the gesture's ⌘Z step.
                guard !Task.isCancelled else {
                    if state.enhancedImage == nil { state.showingEnhanced = false }
                    state.discardLastUndoCheckpoint(ifAction: "Enhance")
                    return
                }
                guard self.windowController === controller, controller.state === state else { return }
                // The ⌘Z step was recorded at the GESTURE (toggle/Apply
                // click) — checkpointing here would capture the already-
                // flipped flag and make undo a no-op.
                state.enhancedImage = enhanced
                state.showingEnhanced = true
                state.showingCutout = false   // alternate bases are exclusive
                state.enhanceParams = params   // commit the draft → applied
                state.markDirty()
            } catch {
                // Cancelled or failed — revert switch to OFF if no enhanced
                // image exists, and drop the gesture's optimistic ⌘Z step
                // (nothing changed; a no-op step reads as broken undo).
                if state.enhancedImage == nil { state.showingEnhanced = false }
                state.discardLastUndoCheckpoint(ifAction: "Enhance")
            }
        }
    }

    /// The app that was frontmost when the editor was hidden for a capture.
    /// A cancelled session restores its activation instead of yanking the
    /// editor above it (the capture overlay activates Sealshot, so without
    /// this every cancel surfaced the editor over the app the user was in).
    private var preCaptureFrontmostApp: NSRunningApplication?

    /// Whether the editor window was on screen when the current capture began.
    ///
    /// The editor is a PERSISTENT SHELL: closing it orders the window out but
    /// keeps this controller alive. Without this flag, a cancelled capture
    /// started from the floating window would order a deliberately-closed
    /// editor straight back onto the screen — and `presentCaptured` would open
    /// it for successful ones. Read before `dismissWithAutoSave` hides it,
    /// since afterwards the window always reads as hidden.
    private(set) var wasVisibleBeforeCapture = false

    /// True from the moment the user CLOSES the editor window until they open
    /// it again on purpose.
    ///
    /// A closed window is a decision, and a capture is not a request to undo
    /// it: the shot still lands in the Library and the recent strip, it just
    /// doesn't drag the big window back over whatever the user is documenting.
    /// Only real closes count — `dismiss()` unhooks the close observer before
    /// closing, so programmatic teardown (locking, swapping sessions) is not
    /// mistaken for the user reaching for the red button.
    private(set) var userClosedWindow = false

    /// The editor is being shown deliberately — by ⌘⇧E, the Library shortcut,
    /// the Dock, the menu bar, a new canvas, or an opened file. Whatever the
    /// user closed, they have now asked for it back.
    private func noteEditorShownDeliberately() { userClosedWindow = false }

    /// Set while a capture started from the floating panel is in flight, so the
    /// ordinary cancel path stands aside for `restoreAfterFloatingCapture()`.
    /// That path either raises the editor over everything or buries it at the
    /// back depending on who was frontmost — and since the panel never
    /// activates Sealshot, a floating capture always took the burying branch.
    var keepHiddenAfterCapture = false

    /// Set while a recording started from the floating panel is in flight, so
    /// the `.recordingDidFinish` observer hands the file back rather than
    /// opening the editor and playing it.
    var suppressNextRecordingPresentation = false

    /// Where a suppressed recording goes instead — the coordinator counts it,
    /// puts it in the panel's strip, and restores the editor.
    var onSuppressedRecordingFinished: ((URL) -> Void)?

    /// Undo `dismissWithAutoSave` for a capture the floating panel started:
    /// put the editor back exactly as it was, and nothing more.
    ///
    /// `orderFront` rather than `orderBack` (which buried it under other apps)
    /// or `raiseAboveOtherApps` (which would yank it over the work the user is
    /// capturing). The frame never changed — `orderOut` preserves it — so
    /// restoring the ordering restores the window. It deliberately does NOT
    /// present the new capture: the panel's whole purpose is that captures
    /// don't take over this window.
    func restoreAfterFloatingCapture() {
        keepHiddenAfterCapture = false
        preCaptureFrontmostApp = nil
        guard wasVisibleBeforeCapture,
              let window = windowController?.window,
              !window.isMiniaturized else { return }
        window.orderFront(nil)
    }

    /// Hide the editor window before a capture so it isn't recorded in the
    /// screenshot. If the current session has unsaved annotations or a
    /// committed crop, save them first so the user doesn't lose work.
    func dismissWithAutoSave() {
        wasVisibleBeforeCapture = windowController?.window?.isVisible == true
        autoSaveIfDirty()
        preCaptureFrontmostApp = NSWorkspace.shared.frontmostApplication
        // Persistent shell: hide (don't close) the window so it isn't captured
        // in the screenshot. present()/presentMostRecent() re-show it afterward.
        // A MINIMIZED window is a Dock tile, not on-screen, so it can't appear in
        // the capture — leave it minimized. (orderOut would clear that state, and
        // a cancelled capture should keep it minimized — see reshowAfterCancel.)
        guard let window = windowController?.window else { return }
        if !window.isMiniaturized { window.orderOut(nil) }
    }

    /// Re-show the editor window after a cancelled capture/recording (it was
    /// hidden by `dismissWithAutoSave`). If the capture was triggered while
    /// ANOTHER app was frontmost (global hotkey / menu bar), the editor comes
    /// back without raising, and activation returns to that app — a cancel
    /// should leave the screen exactly as it was.
    func reshowAfterCancel() {
        let previous = preCaptureFrontmostApp
        preCaptureFrontmostApp = nil

        // Either it was closed before this capture — a cancel must not be the
        // thing that opens it — or the floating panel deliberately hid it and
        // owns the screen for now. Activation still goes back, so the overlay's
        // app activation doesn't strand focus on Sealshot.
        guard wasVisibleBeforeCapture, !keepHiddenAfterCapture else {
            let ownPid = ProcessInfo.processInfo.processIdentifier
            if let previous, !previous.isTerminated,
               previous.processIdentifier != ownPid {
                yieldActivation(to: previous)
            }
            return
        }
        let ownPid = ProcessInfo.processInfo.processIdentifier
        let foreignPrevious: NSRunningApplication? = {
            guard let previous, !previous.isTerminated,
                  previous.processIdentifier != ownPid else { return nil }
            return previous
        }()

        guard let window = windowController?.window, !window.isMiniaturized else {
            // No window (or it stays minimized) — still hand activation back
            // so the overlay's app activation doesn't strand focus on us.
            if let foreignPrevious { yieldActivation(to: foreignPrevious) }
            return
        }
        if let foreignPrevious {
            window.orderBack(nil)
            yieldActivation(to: foreignPrevious)
        } else {
            raiseAboveOtherApps(window)
        }
    }

    private func yieldActivation(to app: NSRunningApplication) {
        NSApp.yieldActivation(to: app)
        app.activate()
    }

    /// Navigating to another item makes a running Smart Redaction scan
    /// stale: its result would be discarded on arrival anyway, but without a
    /// cancel the OCR/FM work keeps burning and the progress overlay stays
    /// up over the NEW item until the scan finishes. Same path as the
    /// overlay's Cancel button.
    private func cancelStaleRedactionScan() {
        redactionScanTask?.cancel()
    }

    /// Move a scratch capture into the Library, announce it, and re-point the
    /// open session at the moved file.
    ///
    /// Auto-save FIRST: annotations made since the capture live in editor
    /// state until a save, and moving the package out from under an unsaved
    /// session would keep the edits pointed at a path that no longer exists.
    /// Announce via the same `.captureFilesImported` a fresh capture posts, so
    /// the index, both strips, and capture-undo treat the kept file exactly
    /// like a new one. Reopen at the new URL rather than mutating sourceURL in
    /// place — presentFile already knows how to swap a session safely.
    private func addScratchCaptureToLibrary(_ url: URL) {
        guard ScratchCapture.isScratch(url) else { return }
        autoSaveIfDirty()
        do {
            let dest = try ScratchCapture.keep(url, saveFolder: config.saveFolder)
            NotificationCenter.default.post(name: .captureFilesImported, object: [dest],
                                            userInfo: ["kind": "capture"])
            // Re-point the OPEN session rather than reopening the moved file:
            // a reopen is a fresh present, which re-fits the canvas — keeping
            // a capture must not move the user's zoom or scroll. Only the URL
            // changed; the pixels on screen are already right.
            windowController?.notePresentedFileMoved(to: dest)
            os_log("scratch capture kept: %{public}@ -> %{public}@", log: log,
                   type: .info, url.lastPathComponent, dest.lastPathComponent)
        } catch {
            os_log("scratch keep failed: %{public}@", log: log, type: .error,
                   String(describing: error))
        }
    }

    private func autoSaveIfDirty() {
        guard let controller = windowController else { return }
        // Fold any in-progress inline text edit into the annotation list before
        // checking dirty — otherwise uncommitted text would be lost on the
        // file-switch / dismiss that triggered this autosave.
        controller.commitPendingTextEdit()
        guard controller.hasUnsavedEdits, let state = controller.state else { return }
        do {
            // Timed because this runs BEFORE the incoming capture is loaded on a
            // switch, so it is invisible to the switch measurement — and unlike
            // reading, saving re-encodes every PNG in full.
            let saveStart = ContinuousClock.now
            _ = try saver.save(state: state)
            let d = ContinuousClock.now - saveStart
            os_log("auto-save before switch: %.0fms", log: log, type: .default,
                   Double(d.components.seconds) * 1000
                       + Double(d.components.attoseconds) / 1.0e15)
        } catch {
            os_log("auto-save before dismiss failed: %{public}@",
                   log: log, type: .error, String(describing: error))
        }
    }

    /// Open the editor with the most recent capture from `config.saveFolder`.
    /// If a window is already open, brings it to front. If no captures
    /// exist within the 7-day window, falls through to `presentEmpty`.
    /// Open the editor (most recent capture, or empty) and switch to the
    /// Settings tab. Backs the menu-bar item's Settings… row.
    func presentSettings() {
        presentMostRecent()
        windowController?.selectTab(.settings)
    }

    /// Open the editor window straight onto the Library tab — browsing/
    /// organizing without routing through the last capture. Backs the
    /// `openLibrary` global shortcut.
    func presentLibrary() {
        presentMostRecent()
        windowController?.selectTab(.library)
    }

    /// The Dock icon was clicked while Sealshot is already running.
    ///
    /// Unlike ⌘⇧E / the menu bar / the panel's ⤢ — all of which name the editor
    /// and so land on it — a Dock click means "show me the app". An open window
    /// is therefore raised exactly as it is, keeping the user's tab; a closed
    /// one comes back on the tab it was showing.
    func reopenFromDock() {
        let action = ShellTab.dockReopenAction(hasEditorWindow: windowController != nil,
                                               lastSelectedTab: lastSelectedTab)
        WindowDiag.note("reopenFromDock: hasEditorWindow=\(windowController != nil) "
                        + "lastSelectedTab=\(lastSelectedTab) → \(action)")
        switch action {
        case .raiseExisting:
            guard let window = windowController?.window else {
                // A controller with no window is why a Dock click can look dead.
                WindowDiag.note("reopenFromDock: raiseExisting but windowController.window is nil")
                return
            }
            // Minimised counts as open: bring it back rather than leaving the
            // click looking dead.
            if window.isMiniaturized { window.deminiaturize(nil) }
            raiseAboveOtherApps(window)
        case .openRestoringTab(let tab):
            presentMostRecent()
            // presentMostRecent lands on the Editor; restore what was showing.
            if tab != .editor { windowController?.selectTab(tab) }
        }
    }

    func presentMostRecent() {
        // Traced end to end: this is the one path every "show me the editor"
        // route funnels through (launch, ⌘⇧E, menu bar, Dock), so a window that
        // never appears is either not reaching here or leaving by one of the
        // early returns below.
        WindowDiag.note("presentMostRecent: hasController=\(windowController != nil) "
                        + "encryptionEnabled=\(EncryptionSession.shared.isEnabled) "
                        + "unlocked=\(EncryptionSession.shared.isUnlocked)")
        defer { WindowDiag.windows("end of presentMostRecent") }
        noteEditorShownDeliberately()
        if let controller = windowController {
            controller.selectTab(.editor)
            // Bring the existing window above other apps — a bare
            // makeKeyAndOrderFront leaves it buried when invoked from the
            // status-menu / hotkey while another app is frontmost (macOS 14+
            // suppresses plain NSApp.activate).
            if let window = controller.window { raiseAboveOtherApps(window) }
            return
        }
        // While encryption is on but locked, reading a capture would dead-end
        // on .packageLocked. Open an empty window instead — its lock-screen
        // overlay shows the Unlock button (the editor's only path to unlock).
        if EncryptionSession.shared.isEnabled && !EncryptionSession.shared.isUnlocked {
            deferredRecentDueToLock = true
            presentEmpty()
            return
        }
        WindowDiag.note("presentMostRecent: scanning \(config.saveFolder.path)")
        let recents = findRecentCaptures(in: config.saveFolder, coveringDays: 7)
        WindowDiag.note("presentMostRecent: \(recents.count) recent, newest=\(recents.first?.lastPathComponent ?? "none")")
        if recents.first == nil {
            os_log("openEditor: no recent captures in %{public}@; presenting empty",
                   log: log, type: .info, config.saveFolder.path)
        }
        openOnLaunch(newest: recents.first)
        WindowDiag.note("presentMostRecent: openOnLaunch returned, hasController=\(windowController != nil)")
    }

    /// Open a scratch session on an unsaved canvas (blank or clipboard-
    /// seeded). Nothing touches disk until ⌘S, whose nil-source path writes
    /// a timestamp-named `.seal` into the save folder — at which point the
    /// session joins the Library like any capture.
    func presentScratchCanvas(_ image: CGImage) {
        autoSaveIfDirty()
        let state = EditorState(sourceImage: image, sourceURL: nil)
        let title = "Untitled"
        if let controller = windowController {
            // A fresh scratch canvas fits like a capture (not an image switch).
            controller.swap(toState: state, title: title, fitFresh: true)
            controller.selectTab(.editor)
            if let window = controller.window { raiseAboveOtherApps(window) }
            wireEnhance(on: controller, title: title)
            return
        }
        let screenFrame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)  // launch before active: NSScreen.main can be nil
        presentState(state, on: screenFrame, title: title, fitFresh: true)
        if let controller = windowController { wireEnhance(on: controller, title: title) }
    }

    /// Open a fully-built Live Capture scene state (annotations + assets already
    /// populated) in the editor. Additive; does not touch the fresh-capture path.
    func presentScene(_ state: EditorState, title: String) {
        autoSaveIfDirty()
        if let controller = windowController {
            controller.swap(toState: state, title: title, fitFresh: true)
            controller.selectTab(.editor)
            if let window = controller.window { raiseAboveOtherApps(window) }
            wireEnhance(on: controller, title: title)
            return
        }
        let screenFrame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        presentState(state, on: screenFrame, title: title, fitFresh: true)
        if let controller = windowController { wireEnhance(on: controller, title: title) }
    }

    /// Bring up the editor and play a just-finished recording in the canvas.
    /// Reuses the existing window (it was hidden while recording) or opens one,
    /// raises it above other apps, and starts playback via `VideoSealPackageIO.read`.
    func presentRecording(url: URL) {
        cancelStaleRedactionScan()
        windowController?.cancelCanvasProgressAction()
        if windowController == nil { presentEmpty() }
        guard let controller = windowController else { return }
        controller.selectTab(.editor)
        if let window = controller.window { raiseAboveOtherApps(window) }
        // Rebuild the strip so the just-saved recording shows up as a tile — like
        // `present` does for a fresh capture — otherwise playVideoInCanvas sets the
        // strip's open-selection to a URL that has no tile yet, so nothing
        // highlights.
        controller.refreshRecentStrip()
        controller.playVideoInCanvas(url: url)
    }

    /// Switch the editor window to the Library tab with `url` selected,
    /// opening a window first when none exists. Used after multi-file import.
    func revealInLibrary(_ url: URL) {
        if windowController == nil { presentEmpty() }
        windowController?.revealInLibrary(url)
        windowController?.window?.makeKeyAndOrderFront(nil)
    }

    /// Open an empty editor window — no canvas content, only the recent
    /// strip + a Capture toolbar button + drop-target placeholder. Used
    /// when `presentMostRecent` finds no captures within the 7-day window,
    /// and as a stable surface the user can return to via the dock icon.
    /// Bring the window forward on the lock screen, carrying `text` to explain
    /// what was just refused. The hotkey that triggers this usually fires from
    /// another app, so the window is raised the same way `presentMostRecent`
    /// does — a plain makeKeyAndOrderFront leaves it buried on macOS 14+.
    func presentLockedNotice(_ text: String) {
        presentEmpty()
        windowController?.presentLockNotice(text)
        if let window = windowController?.window { raiseAboveOtherApps(window) }
    }

    func presentEmpty() {
        WindowDiag.note("presentEmpty: hasController=\(windowController != nil)")
        defer { WindowDiag.windows("end of presentEmpty") }
        noteEditorShownDeliberately()
        if let controller = windowController {
            controller.selectTab(.editor)
            controller.window?.makeKeyAndOrderFront(nil)
            return
        }
        let screenFrame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)  // launch before active: NSScreen.main can be nil
        presentEmptyState(on: screenFrame)
    }

    /// `preservingFrame` reuses an outgoing window's frame (delete-of-last-
    /// capture swap) instead of the centered default, so the window doesn't
    /// jump.
    private func presentEmptyState(on screenFrame: NSRect, preservingFrame: NSRect? = nil) {
        noteEditorShownDeliberately()
        dismiss()

        let contentRect = initialContentRect(screenFrame: screenFrame)

        let controller = EditorWindowController(
            state: nil,
            saver: saver,
            config: config,
            contentRect: contentRect,
            title: "Sealshot",
            onRecentClick: { [weak self] url in self?.presentFile(url) }
        )
        wireCallbacks(on: controller)
        windowController = controller

        if let window = controller.window {
            applyInitialFrame(window, contentRect: contentRect,
                              screenFrame: screenFrame, preservingFrame: preservingFrame)
            raiseAboveOtherApps(window)
            installFrameAutosave(for: window)

            windowCloseObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.rememberSelectedTab()
                    self?.userClosedWindow = true
                    self?.windowController = nil
                    self?.removeFrameSaveObservers()
                    // Nothing pushes `hasSelection: false` once the controller
                    // that owned the last sync is gone — reset explicitly, or
                    // Edit▸Duplicate/Arrange/Flip stay enabled with no editor
                    // open. (A published-flag design needs an explicit reset
                    // like this; an AppKit `can*` predicate evaluated at
                    // menu-open time wouldn't.)
                    ObjectMenuState.shared.update(hasSelection: false, hasFlippableSelection: false)
                    if let obs = self?.windowCloseObserver {
                        NotificationCenter.default.removeObserver(obs)
                        self?.windowCloseObserver = nil
                    }
                }
            }
        }
        os_log("editor present (empty)", log: log, type: .info)
    }

    /// Open `url` as a fresh editor session. If a prior session has unsaved
    /// edits (annotations or a committed crop), auto-save it before
    /// switching — matches the user's choice for the recent-strip click flow.
    ///
    /// When a window is already on-screen, the window's frame is preserved
    /// across the switch — only the canvas content is swapped. This avoids
    /// the layout jump that would otherwise happen on every thumbnail click.
    func presentFile(_ url: URL) {
        WindowDiag.note("presentFile: \(url.lastPathComponent)")
        defer { WindowDiag.windows("end of presentFile") }
        // Opening a scratch capture: whatever tile the strip had highlighted
        // belongs to a DIFFERENT image than the one about to fill the canvas.
        // Clear rather than mislead; the strip has no tile for scratch files.
        if ScratchCapture.isScratch(url) { windowController?.clearStripSelection() }
        // Identity of what's on screen BEFORE the switch, for the
        // `.navigation` entry recorded below (images only — the video `.seal`
        // early-return further down delegates to `presentRecording` →
        // `playVideoInCanvas`, which records its own entry; see correction 5
        // in the Task 4 report for why that's the single recording point per
        // media type, not a double-record).
        let navFrom = windowController?.currentDisplayedItemURL
        // Navigating away makes an in-flight Extract Data / summarize stale —
        // cancel it (redaction has the same treatment via its own task).
        windowController?.cancelCanvasProgressAction()
        autoSaveIfDirty()

        var canvasImage: CGImage
        let loadedAnnotations: [Annotation]
        var loadedCrop: CGRect?
        var loadedContentClip: CGRect?
        var loadedFocus: CGRect? = nil
        var loadedEnhanced: CGImage?
        var loadedShowingEnhanced: Bool
        var loadedEnhanceParams: EnhanceParams = .default
        var loadedImageAssets: [String: Data] = [:]
        // Live Capture: original per-window frames from manifest.sceneLayers.
        // Without rehydrating these on open, a reopened scene loses its scene
        // identity — scene menu items disappear and Revert to Original wipes
        // the window layers to an empty canvas instead of restoring the
        // captured layout.
        var loadedSceneFrames: [String: CGRect] = [:]
        var loadedBackgroundFill: SerializableColor? = nil
        // Document resize (v8): when set, `canvasImage` is the resampled base
        // and this holds the pristine source.png pixels for save/reset.
        var loadedPristine: CGImage? = nil
        // Background-removal alternate base (`cutout.png`) + display flag.
        var loadedCutout: CGImage? = nil
        var loadedPlaceholder: CGImage? = nil
        var loadedShowingCutout = false

        if url.pathExtension.lowercased() == "sealshare" {
            ImportPackageCoordinator.open(url: url, host: NSApp.keyWindow)
            return
        }

        // A plain .mov/.mp4 recording (package wrapper turned off in Settings ▸
        // Recording) has no manifest to consult — its video-ness is the
        // extension. Same destination as a video .seal: play it in the canvas.
        // Without this the file falls through to the image path and opening a
        // recording does nothing.
        if plainMovieExtensions.contains(url.pathExtension.lowercased()) {
            presentRecording(url: url)
            return
        }

        // Video .seal guard — MUST come before readSealPackage (which hard-faults
        // on missing source.png). Reads only manifest.json (cheap). Routes to the
        // existing playVideoInCanvas entry point via the held windowController ref.
        if url.pathExtension.lowercased() == "seal",
           let manifest = try? SealMetadataStore.readManifest(at: url),
           manifest.captureKind == .screenRecording || manifest.captureKind == .importedVideo {
            presentRecording(url: url)
            return
        }

        if url.pathExtension.lowercased() == "seal" {
            // End-to-end switch cost. `readSealPackage` reports its own stage
            // split; this brackets everything after it too (state build, window
            // swap, first draw), so a slow switch can be attributed to loading
            // versus presenting.
            let switchStart = ContinuousClock.now
            defer {
                let d = ContinuousClock.now - switchStart
                let ms = Double(d.components.seconds) * 1000
                    + Double(d.components.attoseconds) / 1.0e15
                os_log("capture switch %{public}@: %.0fms end-to-end",
                       log: log, type: .default, url.lastPathComponent, ms)
            }
            let pkg: SealPackageContents
            do {
                pkg = try readSealPackage(at: url, crypto: SealPackageCryptoContext.current())
            } catch SealPackageIOError.packageLocked {
                // Don't dead-end on a modal alert (it leaves no way to unlock
                // when no window is up yet — e.g. launch / Dock-icon open).
                // Show an empty window so its lock-screen overlay offers
                // Unlock; the capture loads after the session is unlocked.
                deferredRecentDueToLock = true
                presentEmpty()
                return
            } catch {
                os_log("failed to read .seal at %{public}@: %{public}@",
                       log: log, type: .error, url.path, String(describing: error))
                // Don't leave a silent no-op with a desynced strip highlight —
                // restore the strip to the still-open file and explain why.
                windowController?.presentOpenFailure(url: url, error: error)
                return
            }
            canvasImage = pkg.source
            loadedAnnotations = pkg.annotations
            loadedCrop = pkg.crop
            loadedContentClip = pkg.contentClip
            loadedFocus = pkg.focus
            loadedEnhanced = pkg.enhanced
            loadedShowingEnhanced = pkg.enhanced != nil ? pkg.showingEnhanced : false
            loadedEnhanceParams = pkg.manifest.enhanceParams ?? .default
            loadedImageAssets = pkg.imageAssets
            loadedSceneFrames = SceneLayer.originalFrames(from: pkg.manifest.sceneLayers)
            if pkg.manifest.captureKind == .liveCapture {
                SceneDiag.note("OPEN \(SceneDiag.name(url)): manifestSceneLayers="
                    + "\(pkg.manifest.sceneLayers?.count.description ?? "nil") "
                    + "hydratedFrames=\(loadedSceneFrames.count) "
                    + "annotations=\(pkg.annotations.count) assets=\(pkg.imageAssets.count)")
            }
            loadedCutout = pkg.cutout
            loadedPlaceholder = pkg.placeholder
            loadedShowingCutout = pkg.showingCutout
            loadedBackgroundFill = pkg.backgroundFill
            // Document resize (v8): source.png is pristine; the document works
            // on a resampled base. Annotations/focus are stored in resized
            // space (used as-is); the crop is stored in pristine space and
            // scales up. The enhanced base's 2×-of-source invariant no longer
            // holds against a resampled base — drop it (regenerated on demand).
            if let target = pkg.resizedSize {
                let pristineVisible = pkg.crop?.size
                    ?? CGSize(width: pkg.source.width, height: pkg.source.height)
                let fx = target.width / max(pristineVisible.width, 1)
                let fy = target.height / max(pristineVisible.height, 1)
                let fullTarget = CGSize(width: CGFloat(pkg.source.width) * fx,
                                        height: CGFloat(pkg.source.height) * fy)
                if fx > 0, fy > 0,
                   let resampled = DocumentResampler.resample(pkg.source, to: fullTarget) {
                    canvasImage = resampled
                    loadedPristine = pkg.source
                    loadedCrop = pkg.crop.map {
                        CGRect(x: $0.minX * fx, y: $0.minY * fy,
                               width: $0.width * fx, height: $0.height * fy)
                    }
                    loadedContentClip = pkg.contentClip.map {
                        CGRect(x: $0.minX * fx, y: $0.minY * fy,
                               width: $0.width * fx, height: $0.height * fy)
                    }
                    loadedEnhanced = nil
                    loadedShowingEnhanced = false
                }
            }
        } else {
            let pkg: AnnotatedPNG
            do {
                pkg = try readAnnotatedPNG(url: url)
            } catch {
                os_log("failed to read PNG at %{public}@: %{public}@",
                       log: log, type: .error, url.path, String(describing: error))
                // Same recovery as the .seal path — restore the strip highlight
                // and explain, instead of a silent no-op.
                windowController?.presentOpenFailure(url: url, error: error)
                return
            }
            canvasImage = pkg.source ?? pkg.composite
            loadedAnnotations = pkg.annotations
            loadedCrop = pkg.crop
            loadedFocus = pkg.focus
            loadedEnhanced = nil
            loadedShowingEnhanced = false
        }

        let isDeleted = isUnderDeletedFolder(url)
        let newState = EditorState(
            sourceImage: canvasImage,
            sourceURL: url,
            enhancedImage: loadedEnhanced,
            showingEnhanced: loadedShowingEnhanced,
            pristineSource: loadedPristine
        )
        newState.annotations = loadedAnnotations
        warnIfTextFontsMissing(in: loadedAnnotations)
        newState.croppedRect = loadedCrop
        newState.contentClip = loadedContentClip
        newState.focusRect = loadedFocus
        newState.backgroundFill = loadedBackgroundFill
        newState.enhanceParams = loadedEnhanceParams
        newState.enhanceDraft = loadedEnhanceParams
        newState.imageAssets = loadedImageAssets
        newState.placeholderImage = loadedPlaceholder
        newState.sceneOriginalFrames = loadedSceneFrames
        // The cutout must match the (possibly resampled) document exactly;
        // resize invalidates it at apply time, so a mismatch means a stale
        // entry — drop rather than show a wrong-sized base.
        if let cutout = loadedCutout,
           cutout.width == canvasImage.width, cutout.height == canvasImage.height {
            newState.cutoutImage = cutout
            newState.showingCutout = loadedShowingCutout
        }
        // Undo/redo now lives on the app-global timeline (`GlobalUndoStore`),
        // loaded once from its own backend — nothing per-capture to restore here.
        // Tool defaults to neutral .select; swap() carries the prior tool across.
        newState.selectedAnnotationID = nil
        newState.isReadOnly = isDeleted

        let title = isDeleted
            ? "(Deleted) \(url.lastPathComponent)"
            : url.lastPathComponent

        if let controller = windowController {
            controller.swap(toState: newState, title: title)
            wireEnhance(on: controller, title: title)
            controller.selectTab(.editor)
            controller.window?.makeKeyAndOrderFront(nil)
            autoScanIfEnabled(on: controller)
        } else {
            let screenFrame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)  // launch before active: NSScreen.main can be nil
            presentState(newState, on: screenFrame, title: title)
            if let controller = windowController {
                wireEnhance(on: controller, title: title)
                autoScanIfEnabled(on: controller)
            }
        }
        // The switch succeeded — record it as a navigable step. Suppressed
        // for undo/redo-driven reopens (including the async file-event tail
        // — see `EditorWindowController.navigationRecordingSuppressed`), so
        // an undo/redo-triggered view switch never mints its own entry.
        if windowController?.navigationRecordingSuppressed != true {
            windowController?.globalUndo.record(.navigation(from: navFrom, to: url))
            windowController?.updateUndoRedoButtons()
        }
    }

    /// True when `url`'s parent is `<saveFolder>/Deleted/`.
    private func isUnderDeletedFolder(_ url: URL) -> Bool {
        let deleted = config.saveFolder
            .appendingPathComponent(SealDeleter.deletedSubfolderName, isDirectory: true)
            .standardizedFileURL
        return url.deletingLastPathComponent().standardizedFileURL == deleted
    }

    /// Bring `window` to the front above other apps. macOS 14+ suppresses
    /// `NSApp.activate` when it isn't tied to a recent user gesture (after the
    /// async capture chain, ours isn't), so a temporary `.floating` level boost
    /// guarantees the window appears on top. `orderFrontRegardless` orders it up
    /// even while the app isn't yet frontmost (true on a cold launch from
    /// Spotlight). The boost is held briefly before dropping back to `.normal`:
    /// dropping on the immediate next runloop tick can land before the window
    /// server finishes the app-activation transition, leaving the window buried.
    /// Used by every capture-driven open, the empty/launch window, and the
    /// persistent-window swap.
    /// Position a freshly-created editor window: keep an outgoing frame across a
    /// delete-swap (`preservingFrame`); else restore the last saved frame when
    /// it's still reachable on a connected display; else fall back to the
    /// fitted, centered default.
    private func applyInitialFrame(_ window: NSWindow, contentRect: NSRect,
                                   screenFrame: NSRect, preservingFrame: NSRect? = nil) {
        if let preservingFrame {
            window.setFrame(preservingFrame, display: true)
            return
        }
        if let saved = WindowFramePreference.load(),
           WindowFramePreference.isReachable(saved, on: NSScreen.screens.map(\.visibleFrame)) {
            window.setFrame(saved, display: true)
            return
        }
        // Force the content size: a window born from a degenerate contentRect
        // won't grow just from contentMinSize, so set it.
        window.setContentSize(contentRect.size)
        window.setFrameOrigin(NSPoint(x: screenFrame.midX - contentRect.width / 2,
                                      y: screenFrame.midY - contentRect.height / 2))
    }

    /// Persist the window's frame whenever the user moves or resizes it, so the
    /// next launch reopens at the same spot/size (and monitor).
    private func installFrameAutosave(for window: NSWindow) {
        removeFrameSaveObservers()
        let nc = NotificationCenter.default
        let save: (Notification) -> Void = { note in
            guard let w = note.object as? NSWindow else { return }
            WindowFramePreference.store(w.frame)
        }
        frameSaveObservers = [
            nc.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main) { note in
                MainActor.assumeIsolated { save(note) }
            },
            nc.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: window, queue: .main) { note in
                MainActor.assumeIsolated { save(note) }
            },
        ]
    }

    private func removeFrameSaveObservers() {
        frameSaveObservers.forEach { NotificationCenter.default.removeObserver($0) }
        frameSaveObservers = []
    }

    /// Bring the editor to the very front, briefly outranking other apps.
    ///
    /// The `.floating` promotion is TEMPORARY, and anything that wants to sit
    /// above the editor has to wait it out: window levels are absolute, so an
    /// `order(.above:)` issued against a `.floating` window from a `.normal`
    /// one is a silent no-op, and 0.25s later the editor re-fronts at `.normal`
    /// and lands on top of it. `didBecomeKey` fires INSIDE that window, which
    /// is why it is not enough on its own — see
    /// `editorWindowLevelDidSettleNotification`.
    private func raiseAboveOtherApps(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.level = .floating
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.raiseSettleDelay) { [weak window] in
            guard let window else { return }
            window.level = .normal
            // Dropping from .floating re-slots the window into the normal
            // level; when activation hasn't settled yet (e.g. a Dock-click
            // reopen while the window was hidden), that can land it BEHIND
            // the previous app's windows — the editor flashes on-screen and
            // "vanishes" 0.25s later. Re-front it at the normal level.
            guard window.isVisible else { return }
            window.orderFrontRegardless()
            // The level has settled: whoever must ride above the editor can
            // now actually do it. Announced rather than called directly so the
            // editor keeps knowing nothing about the floating panel.
            NotificationCenter.default.post(
                name: Self.editorWindowLevelDidSettleNotification, object: window)
        }
    }

    /// How long the editor stays promoted to `.floating` when it is raised over
    /// another app. Named so the settle notification and this delay can never
    /// drift into two different numbers.
    static let raiseSettleDelay: TimeInterval = 0.25

    /// Posted with the editor window once `raiseAboveOtherApps` has put it back
    /// at `.normal` and re-fronted it. The floating panel listens for this: an
    /// unpinned panel's `order(.above:)` only takes effect once the editor is
    /// no longer outranking it, and every raise route (Dock click, ⌘⇧E, the
    /// panel's ⤢ button, a capture presenting the editor) goes through here.
    static let editorWindowLevelDidSettleNotification =
        Notification.Name("SealshotEditorWindowLevelDidSettle")

    /// Wire every controller callback. Used by BOTH the empty-window and
    /// loaded-window paths so the two never drift — the empty window is reused
    /// in place when a capture/recent is opened after launch (e.g. unlocking),
    /// so it must carry the full set of capture closures, not just the plain one.
    private func wireCallbacks(on controller: EditorWindowController) {
        // Re-applied on every window rebuild, so the pip button keeps working —
        // and keeps showing the right state — after a teardown/reshow cycle.
        controller.onToggleFloatingWindow = onToggleFloatingWindow
        controller.setFloatingWindowOpen(floatingWindowIsOpen)
        controller.onCaptureRequested = { [weak self] in self?.onCaptureRequested() }
        controller.onWindowCaptureRequested = { [weak self] in self?.onWindowCaptureRequested() }
        controller.onUnifiedCaptureRequested = { [weak self] in self?.onUnifiedCaptureRequested() }
        controller.onDelayedCaptureRequested = { [weak self] in self?.onDelayedCaptureRequested() }
        controller.onScrollCaptureRequested = { [weak self] in self?.onScrollCaptureRequested() }
        controller.onLiveCaptureRequested = { [weak self] in self?.onLiveCaptureRequested() }
        controller.onFullscreenCaptureRequested = { [weak self] choice in self?.onFullscreenCaptureRequested(choice) }
        controller.onRecordScreenRequested = { [weak self] choice in self?.onRecordScreenRequested(choice) }
        controller.onRecordSelectionRequested = { [weak self] in self?.onRecordSelectionRequested() }
        controller.onNewCanvasRequested = { [weak self] in self?.onNewCanvasRequested() }
        controller.onNewFromClipboardRequested = { [weak self] in self?.onNewFromClipboardRequested() }
        controller.onImportRequested = { [weak self] in self?.onImportRequested() }
        controller.onImportFilesRequested = { [weak self] urls, reveal in self?.onImportFilesRequested(urls, reveal) }
        controller.onFileDropped = { [weak self] url in self?.presentFile(url) }
        controller.onAllCapturesDeleted = { [weak self] in self?.replaceWithEmptyWindow() }
        controller.onSmartRedact = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.runSmartRedactionScan(on: controller)
        }
        controller.onSmartRedactCancel = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.cancelSmartRedaction(on: controller)
        }
    }

    /// Cancel any in-flight Smart Redact scan and dismiss pending proposals —
    /// invoked when the user selects a drawing tool (mutual exclusion).
    private func cancelSmartRedaction(on controller: EditorWindowController) {
        redactionScanTask?.cancel()
        redactionScanTask = nil
        controller.state?.cancelRedactionScan()
        controller.setSmartRedactScanning(false)
    }

    /// Presents the one-time sheet offering the enhanced on-device redaction model.
    /// If a loaded capture references text fonts not installed on this Mac, tell
    /// the user (once per open) which are missing and that the text falls back to
    /// the remembered/system font. The stored family is NOT changed, so the file
    /// renders correctly again on a Mac that has the font. Deferred so it lands
    /// after the window is on screen.
    private func warnIfTextFontsMissing(in annotations: [Annotation]) {
        let missing = missingTextFontFamilies(in: annotations)
        guard !missing.isEmpty else { return }
        let names = missing.joined(separator: ", ")
        let fallback = AnnotationTextFont.remembered ?? "the system font"
        let plural = missing.count == 1
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = plural ? "A font isn’t installed" : "Some fonts aren’t installed"
            alert.informativeText =
                "This capture uses \(plural ? "a font" : "fonts") that \(plural ? "isn’t" : "aren’t") installed on this Mac (\(names)). "
                + "That text is shown in \(fallback) until you edit it, and will render correctly again if opened on a Mac where the font is installed."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    /// On "Download": shows the blocking foreground-download sheet, then runs the
    /// scan after the model is ready (or falls back to basic on cancel/failure).
    /// On "Use Basic Detection": runs the scan immediately with the basic engine.
    private func presentRedactionModelConsent(on controller: EditorWindowController) {
        let alert = NSAlert()
        alert.messageText = "Download the enhanced on-device model?"
        alert.informativeText = "Download a ~400 MB on-device AI model that improves Smart Redaction and Structured Data Extraction. It runs entirely on your Mac and you can remove it any time. Until it's ready, both features use basic detection."
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Use Basic Detection")

        // Force the alert wider with a transparent spacer accessory view.
        let spacer = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 1))
        alert.accessoryView = spacer

        guard let window = controller.window else {
            if alert.runModal() == .alertFirstButtonReturn {
                redactionModelManager.start()
            }
            return
        }

        alert.beginSheetModal(for: window) { [weak self, weak controller] response in
            guard let self, let controller else { return }
            if response == .alertFirstButtonReturn {
                // Foreground blocking download sheet; scan runs after it dismisses
                // regardless of outcome (ready → enhanced scan; cancelled/failed → basic).
                RedactionModelDownloadSheet.run(on: window) { [weak self, weak controller] _ in
                    guard let self, let controller else { return }
                    self.runSmartRedactionScanCore(on: controller)
                }
            } else {
                // "Use Basic Detection" — scan immediately with the basic engine.
                self.runSmartRedactionScanCore(on: controller)
            }
        }
    }

    /// Run the smart-redaction analyzer and hand the detections to the state for
    /// review, with a cancellable progress overlay. Scans the focus area when one
    /// is set (else the crop, else the whole image); detections come back in that
    /// crop's space and are offset back into visible-image space (annotations'
    /// space) by the focus origin. Tapping while a scan is in flight cancels it.
    private func runSmartRedactionScan(on controller: EditorWindowController) {
        guard let state = controller.state, !state.isReadOnly else { return }
        if case .scanning = state.redactionScan {
            redactionScanTask?.cancel()
            redactionScanTask = nil
            state.cancelRedactionScan()
            controller.setSmartRedactScanning(false)
            controller.hideCanvasProgressOverlay()
            return
        }
        // First-use offer for the enhanced on-device model: show a blocking consent
        // sheet then run the scan after the user decides (download → wait for model
        // then scan; basic / cancel → scan immediately with the basic engine).
        if RedactionConsentPreference.shouldPrompt(
            appleSilicon: RedactionEngineLoader.isAppleSilicon,
            aiEnabled: AIFeaturePreference().enabled,
            modelReady: RedactionModelLocator.localModelPath() != nil,
            asked: RedactionConsentPreference.asked) {
            RedactionConsentPreference.asked = true
            presentRedactionModelConsent(on: controller)    // defers scan to post-consent
            return
        }
        runSmartRedactionScanCore(on: controller)
    }

    /// The inner scan body — resolves the engine, runs the analyzer, and
    /// presents detection proposals.  Called directly when no consent prompt
    /// is needed, and called by `presentRedactionModelConsent` after the user
    /// has made their choice.
    private func runSmartRedactionScanCore(on controller: EditorWindowController) {
        guard let state = controller.state, !state.isReadOnly else { return }

        let rect = EditorState.aiOCRRect(
            sourceSize: CGSize(width: state.sourceImage.width, height: state.sourceImage.height),
            croppedRect: state.croppedRect, focusRect: state.focusRect)
        guard let image = state.sourceImage.cropping(to: rect.integral) else { return }
        let offset = state.focusRect?.origin ?? .zero

        state.enhanceEditing = false
        state.redactionScan = .scanning
        controller.setSmartRedactScanning(true)
        let progress = CanvasProgress()
        progress.label = "Preparing…"
        controller.showCanvasProgressOverlay(progress: progress) { [weak self] in
            self?.redactionScanTask?.cancel()
        }
        redactionScanTask = Task { @MainActor [weak self, weak controller, weak state] in
            // Shows a "still working" note if the Thorough-scan phase runs long.
            var thoroughWatchdog: Task<Void, Never>?
            defer {
                thoroughWatchdog?.cancel()
                self?.redactionScanTask = nil
                controller?.hideCanvasProgressOverlay()
            }
            // Resolve the GLiNER2 engine when gated on (Apple silicon + AI on +
            // local model present). The loader call is blocking (~1 s, loads the
            // model), so it runs in a detached task; nil → rule/FM fallback.
            let modelPath = RedactionModelLocator.localModelPath()
            let useEngine = RedactionEngineGate.shouldUseEngine(
                appleSilicon: RedactionEngineLoader.isAppleSilicon,
                aiEnabled: AIFeaturePreference().enabled,
                modelPresent: modelPath != nil)
            let engine: RedactionEngine?
            if useEngine, let loader = self?.redactionEngineLoader {
                engine = await Task.detached { loader.engine(modelPath: modelPath) }.value
            } else {
                engine = nil
            }
            let detections: [Detection]
            let financialDocument: Bool
            do {
                let analysis = try await SmartRedactionAnalyzer().analyze(image, engine: engine) { frac, label in
                    progress.fraction = frac
                    guard progress.label != label else { return }
                    progress.label = label
                    progress.note = ""
                    thoroughWatchdog?.cancel()
                    thoroughWatchdog = nil
                    // The Thorough-scan (Foundation Model) phase is the variable, sometimes
                    // long one — only after 7s of it still running do we reassure the user.
                    if label == SmartRedactionAnalyzer.ScanPhase.thorough {
                        thoroughWatchdog = Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 7_000_000_000)
                            if !Task.isCancelled { progress.note = "This one takes a moment…" }
                        }
                    }
                }
                detections = analysis.detections
                financialDocument = analysis.financialDocument
            } catch {
                // Cancelled or OCR failed — end quietly; the user can re-scan.
                guard let state, case .scanning = state.redactionScan else {
                    controller?.setSmartRedactScanning(false); return
                }
                state.cancelRedactionScan()
                controller?.setSmartRedactScanning(false)
                return
            }
            // The window may have swapped to another image while we scanned.
            guard let controller, let state, controller.state === state,
                  case .scanning = state.redactionScan else {
                controller?.setSmartRedactScanning(false); return
            }
            // Don't drop the pill highlight here — the scan is moving into its
            // review panel (`.found`), and the pill stays lit for the whole
            // active mode. The `redactionScan` observer turns it off when the
            // review ends (→ .idle) or when no proposals are found (→ .empty).
            let placed = offset == .zero ? detections
                : detections.map { $0.offsetBy(dx: offset.x, dy: offset.y) }
            state.presentRedactionProposals(placed, financialDocument: financialDocument)
            if placed.isEmpty {
                controller.flashNoSensitiveContent()
                state.cancelRedactionScan()
            }
        }
    }

    /// Kick off a background scan right after an image opens, when the user
    /// has opted in (Settings → "Scan captures automatically").
    private func autoScanIfEnabled(on controller: EditorWindowController) {
        guard SmartRedactionPreference.autoScanEnabled() else { return }
        runSmartRedactionScan(on: controller)
    }

    /// The open file was deleted and nothing remains: swap the loaded window
    /// for the empty editor in place (same frame) so the app keeps a window
    /// instead of vanishing from the screen.
    private func replaceWithEmptyWindow() {
        let preservedFrame = windowController?.window?.frame
        let screenFrame = windowController?.window?.screen?.visibleFrame
            ?? (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        presentEmptyState(on: screenFrame, preservingFrame: preservedFrame)
    }

    private func presentState(_ state: EditorState, on screenFrame: NSRect, title: String,
                              fitFresh: Bool = false) {
        // A window is being built: whatever route asked for it, the editor is
        // on screen again from here.
        noteEditorShownDeliberately()
        // Tear down any prior session synchronously.
        dismiss()

        let contentRect = initialContentRect(screenFrame: screenFrame)

        let controller = EditorWindowController(
            state: state,
            saver: saver,
            config: config,
            contentRect: contentRect,
            title: title,
            fitFresh: fitFresh,
            onRecentClick: { [weak self] url in self?.presentFile(url) }
        )
        wireCallbacks(on: controller)
        windowController = controller

        if let window = controller.window {
            applyInitialFrame(window, contentRect: contentRect, screenFrame: screenFrame)
            raiseAboveOtherApps(window)
            installFrameAutosave(for: window)

            windowCloseObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.rememberSelectedTab()
                    self?.userClosedWindow = true
                    self?.windowController = nil
                    self?.removeFrameSaveObservers()
                    // See the empty-state close observer above: nothing else
                    // pushes `hasSelection: false` once this controller is gone.
                    ObjectMenuState.shared.update(hasSelection: false, hasFlippableSelection: false)
                    if let obs = self?.windowCloseObserver {
                        NotificationCenter.default.removeObserver(obs)
                        self?.windowCloseObserver = nil
                    }
                }
            }
        }
        os_log("editor present", log: log, type: .info)
    }

    /// Snapshot the tab before the window controller goes away — once it is nil
    /// the selection is gone with it, and a Dock-click reopen needs it.
    private func rememberSelectedTab() {
        guard let controller = windowController else { return }
        lastSelectedTab = controller.currentTabSelection
    }

    func dismiss() {
        if let obs = windowCloseObserver {
            NotificationCenter.default.removeObserver(obs)
            windowCloseObserver = nil
        }
        rememberSelectedTab()
        windowController?.close()
        windowController = nil
    }

    /// Fixed 16:9 landscape — ~70% of the screen, capped at 1600×900.
    /// Used for both empty-mode and loaded-mode opens so the editor
    /// always lands at the same shape regardless of image dimensions.
    /// scheduleFitToWindow handles the per-image scaling inside this frame.
    private func initialContentRect(screenFrame: NSRect) -> NSRect {
        // Floor the size so a degenerate screenFrame (NSScreen.main nil before
        // the app is active at launch) can never collapse the window — without
        // the floor, min(0 * 0.85, …) yields a sliver.
        let width = max(1000, min(screenFrame.width * 0.85, 2000))
        let height = max(700, min(screenFrame.height * 0.85, 1300))
        return NSRect(x: 0, y: 0, width: width, height: height)
    }
}
