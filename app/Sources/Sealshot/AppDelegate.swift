import AppKit
import SwiftUI
import os.log

private let log = OSLog(subsystem: "com.seal-shot.sealshot", category: "lifecycle")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Exposed (read-only) so SealshotApp's File-menu commands can route
    /// New Canvas / Import actions to the live coordinator.
    private(set) var captureCoordinator: CaptureCoordinator?
    /// Drives screen video recording (separate from still capture).
    private(set) var recordingCoordinator: RecordingCoordinator?
    /// Persistent menu-bar status item hosting capture + recording controls.
    /// Created at launch so it holds a stable slot — the old on-demand recording
    /// item, created at record-time, got pushed under the notch and vanished.
    private var menuBarController: MenuBarController?
    /// Floating recording HUD (draggable dot) shown while recording.
    private var recordingHUD: RecordingHUDController?
    /// Small always-on-top capture panel — the click-only route when macOS has
    /// crowded our status item off a small menu bar.
    private(set) var floatingCaptureController: FloatingCaptureController?
    /// Whether the panel was on screen at quit; drives launch restore and the
    /// Dock-icon reopen target.
    private static let floatingOpenAtQuitKey = "FloatingCaptureWindowWasOpen"
    /// Takes the panel down on lock and puts it back on unlock.
    private var floatingLockObserver: NSObjectProtocol?
    /// Pulls an unpinned panel forward with the editor window.
    private var floatingEditorOrderObserver: NSObjectProtocol?
    /// The same ride, re-asserted once the editor's temporary `.floating`
    /// promotion ends — without it every programmatic raise leaves the panel
    /// buried, because the ordering issued during the promotion is a no-op.
    private var floatingEditorSettleObserver: NSObjectProtocol?
    private let recordingSettingsPrompt = RecordingSettingsPromptController()
    private let sessionMarkerStore = SessionMarkerStore()
    private var pendingCrashReport: URL?
    /// Re-locks the session on sleep / screen-lock / fast-user-switch.
    private var relockController: RelockController?
    /// Observes unlock events to re-trigger OCR backfill for locked packages
    /// that were skipped at launch.
    private var lockObserver: NSObjectProtocol?
    /// Files handed to us via Finder's "Open With" while the session was
    /// locked. Replayed by `flushPendingOpenURLs()` once the user unlocks.
    private var pendingOpen = PendingOpenQueue()

    func applicationWillFinishLaunching(_ notification: Notification) {
        os_log("applicationWillFinishLaunching", log: log, type: .info)
        // Show tooltips immediately on hover instead of after AppKit's ~2s
        // default. `NSInitialToolTipDelay` is read (in ms) when tooltip
        // tracking is set up, so it must be registered before any window
        // appears. Applies app-wide (toolbar icons + zoom row).
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 1])
        // Auto-hiding (overlay) scrollbars app-wide — editor canvas/sidebar/strip
        // plus the SwiftUI Library and Settings surfaces — regardless of the
        // user's system "Show scroll bars" setting. `NSScroller.preferredScrollerStyle`
        // reads `AppleShowScrollBars` from CFPreferences, where this app domain
        // outranks NSGlobalDomain. "Automatic" = "based on mouse or trackpad":
        // overlay auto-hide with a trackpad, but always-visible (`.legacy`) when
        // a mouse is attached. (The always-overlay alternative is "WhenScrolling".)
        // Set (not register) so it overrides a user's system-wide "Always". Must
        // run before any scroll view is built.
        UserDefaults.standard.set("Automatic", forKey: "AppleShowScrollBars")
        // Crash visibility (privacy-honest): a marker still present from the
        // previous session means it ended uncleanly. Only the Direct build
        // looks for a corroborating macOS crash report (the MAS sandbox
        // can't read DiagnosticReports), and only a real .ips triggers the
        // prompt — a force-quit stays silent. Nothing is ever sent.
        if let stale = sessionMarkerStore.readStale(), AppInfo.edition == .direct {
            pendingCrashReport = CrashReportLocator().reportMatching(stale)
        }
        sessionMarkerStore.writeFresh(SessionMarker(
            launchDate: Date(),
            appVersion: AppInfo.versionString,
            pid: ProcessInfo.processInfo.processIdentifier))
        // BEFORE the coordinators register their hotkeys: move persisted
        // old-default keybindings to their new defaults (the library writes
        // defaults into UserDefaults, so code changes alone don't migrate).
        ShortcutDefaultsMigration.run()
        let capture = CaptureCoordinator()
        captureCoordinator = capture
        // saveFolder is a provider (not a captured URL) so recordings follow a
        // mid-session save-location change; `capture` is app-lifetime here.
        let rec = RecordingCoordinator(saveFolder: { capture.saveFolder },
                                       countdown: capture.sharedCountdown,
                                       sourcePicker: { [weak capture] in await capture?.pickRecordingSource() })
        rec.registerShortcut()
        rec.addObserver(RecordingMenuState.shared)   // drives the SwiftUI Capture menu
        recordingCoordinator = rec
        // One session at a time, in both directions: a running recording OR
        // its start pre-roll (config prompt, display pick, countdown) eats new
        // capture triggers, and a live capture session (overlay/countdown/
        // scroll) eats recording starts. Both objects are app-lifetime; weak
        // only to avoid the formal retain cycle.
        capture.isRecordingActive = { [weak rec] in rec?.isBusy ?? false }
        rec.isCaptureSessionActive = { [weak capture] in capture?.isCaptureSessionActive ?? false }
        // Editor toolbar record buttons → recording coordinator (it lives here,
        // separate from capture, so wire it through the capture coordinator).
        capture.setRecordingActions(
            onRecordScreen: { [weak rec] choice in
                var screen: NSScreen?
                if case .display(let i) = choice, NSScreen.screens.indices.contains(i) {
                    screen = NSScreen.screens[i]
                }
                rec?.toggle(display: screen)
            },
            onRecordSelection: { [weak rec] in rec?.beginSelection() })
        // Hide the editor whenever a recording begins (toolbar, ⇧⌘V, or the
        // selection-recording shortcut); a cancelled recording re-shows it.
        rec.onWillBegin = { [weak capture] in capture?.hideEditorForRecording() }
        rec.onAborted = { [weak capture] in capture?.reshowEditorAfterCancel() }
        // Carried-over fix (Task 7 review): recording's own entitlement gates
        // aborted silently without opening Settings. Route to the same call
        // CaptureCoordinator's gate sites use.
        // Pre-roll settings prompt (reminds + edits system/mic audio, cursor,
        // countdown). Honors its own "ask before each recording" toggle.
        rec.confirmSettings = { [weak self] in
            await self?.recordingSettingsPrompt.confirm() ?? true
        }
        // Screen Recording preflight: show the shared permission checklist
        // (same UI as still capture) before the setup prompt when access is
        // denied, instead of failing into a raw ScreenCaptureKit error.
        rec.showPermissionChecklist = { [weak capture] retry in
            capture?.showRecordingChecklist(retry: retry)
        }
        // Persistent menu-bar item — owns the capture/recording menu and the
        // red recording state. Created here so it claims a stable slot at launch.
        menuBarController = MenuBarController(capture: capture, recording: rec)
        // Floating recording HUD — shows the draggable dot while recording.
        recordingHUD = RecordingHUDController(recording: rec)
        wireFloatingCaptureWindow(capture: capture, recording: rec)
    }

    /// The small always-on-top capture panel. Every button routes through the
    /// SAME coordinator triggers the menu bar uses, so the panel inherits the
    /// busy gate, the lock gate and the licence gate rather than restating any
    /// of them — a second gate here would be a second place for the two to
    /// disagree.
    private func wireFloatingCaptureWindow(capture: CaptureCoordinator,
                                           recording rec: RecordingCoordinator) {
        let floating = FloatingCaptureController()
        floatingCaptureController = floating

        floating.perform = { [weak capture, weak rec, weak floating] kind in
            guard let capture else { return }
            if kind.isRecording {
                // The panel STAYS for a recording — its face button is how you
                // stop one — but the recording is still the panel's, so it
                // lands in the strip and leaves the editor where it was.
                capture.beginFloatingWindowRecording()
            } else {
                // Mark the origin so `presentCaptured` keeps the editor closed,
                // and step the panel aside while the selection overlay is up.
                capture.beginFloatingWindowCapture()
                floating?.hideForCapture()
            }
            switch kind {
            case .unified:         capture.triggerUnifiedCapture()
            case .saveAs:          capture.triggerSaveAsCapture()
            case .fullScreen:      capture.triggerFullscreenCapture()
            case .delayed:         capture.triggerDelayedCapture()
            case .scrolling:       capture.triggerScrollCapture()
            case .live:            capture.triggerLiveCapture()
            case .record:          rec?.toggle()
            case .recordSelection: rec?.beginSelection()
            }
        }
        // Same rule as the Dock icon: showing the app must not pick a tab for
        // the user. `triggerOpenEditor` forces the Editor tab, which is right
        // for ⌘⇧E and the menu bar (they name the editor) and wrong here.
        floating.openEditor = { [weak capture] in capture?.triggerReopenFromDock() }
        floating.isLocked = { CaptureCoordinator.isLocked }
        // The panel's strip is a pure projection of the SAME query the editor
        // strip renders — newest first, images and recordings alike — so the
        // two can never disagree about what exists.
        floating.recentProvider = { [weak capture] in
            guard let capture else { return [] }
            let folder = capture.saveFolder
            let recordings = RecordingsLibrary.folder(forSaveFolder: folder)
            return await LibraryIndexStore.shared.stripItems(
                folder: folder, recordingsFolder: recordings,
                coveringDays: 7, now: Date()) ?? []
        }
        floating.saveFolderProvider = { [weak capture] in capture?.saveFolder }
        floating.togglePauseRecording = { [weak rec] in rec?.togglePause() }
        floating.stopRecording = { [weak rec] in rec?.stopRecording() }
        // Held weakly by the coordinator, same as the status item — the panel's
        // face button and overflow switch to the recording controls in the same
        // beat the menu bar does.
        rec.addObserver(floating)

        // With the editor suppressed, the count and thumbnails are the user's
        // only proof a capture happened — and the count clears the moment they
        // go and look, whichever route opened the editor. The strip itself
        // needs no call here: the landed file posts `.captureFilesImported`,
        // which the panel already refetches on.
        capture.floatingWindowCaptureLanded = { [weak floating] _ in
            floating?.captureLanded()
        }
        // Fires on every exit — landed, cancelled, or failed — so pressing Esc
        // can never leave the panel gone.
        capture.floatingWindowCaptureEnded = { [weak floating] in
            floating?.restoreAfterCapture()
        }
        capture.onEditorOpened = { [weak floating] in floating?.editorWasOpened() }

        // One toggle behind both entry routes — the editor's pip button and the
        // View menu item — so they can never disagree about the panel's state.
        let toggleFloating: () -> Void = { [weak floating, weak capture] in
            guard let floating else { return }
            floating.isVisible ? floating.hide() : floating.show()
            capture?.editor.setFloatingWindowOpen(floating.isVisible)
        }
        capture.editor.onToggleFloatingWindow = toggleFloating
        capture.toggleFloatingWindowHandler = toggleFloating

        // Recovering a panel nobody can see: open it if it was closed — a
        // closed panel is the other way "I can't find it" happens — and then
        // put it somewhere unmissable. Opening goes through the same toggle so
        // the editor's button never disagrees about the panel's state.
        capture.resetFloatingWindowPositionHandler = { [weak floating] in
            guard let floating else { return }
            if !floating.isVisible { toggleFloating() }
            floating.resetPosition()
        }

        // The panel's own ✕ lands in exactly the same place as the toolbar
        // button and the View menu, so the editor's button state cannot drift.
        // `applicationWillTerminate` records `isVisible`, so a panel closed this
        // way is also not restored at the next launch.
        floating.onCloseRequested = toggleFloating

        // An unpinned panel rides the editor: whenever the editor window comes
        // forward — user, Dock, or a finished capture — the panel is ordered
        // above it. This is the only route back for a buried panel, which never
        // becomes key and so cannot raise itself. Deliberately NOT
        // `addChildWindow`: a child is not composited on a display its parent
        // does not occupy, and cannot outlive its parent.
        //
        // TWO triggers, because one is not enough. `didBecomeKey` covers a
        // plain click on the editor, but every programmatic raise (Dock click,
        // ⌘⇧E, the panel's ⤢ button, a capture presenting the editor) goes
        // through `EditorController.raiseAboveOtherApps`, which parks the
        // editor at `.floating` for a quarter second — and `didBecomeKey` fires
        // INSIDE that promotion, where ordering a `.normal` panel above a
        // `.floating` window is a silent no-op. The settle notification fires
        // once the editor is back at `.normal`, which is when the ordering can
        // actually take.
        let rideEditor: @Sendable (Notification) -> Void = { [weak floating, weak capture] note in
            MainActor.assumeIsolated {
                guard let floating, let window = note.object as? NSWindow,
                      window === capture?.editor.hostWindow else { return }
                floating.followEditorIfUnpinned(window)
            }
        }
        floatingEditorOrderObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main,
            using: rideEditor)
        floatingEditorSettleObserver = NotificationCenter.default.addObserver(
            forName: EditorController.editorWindowLevelDidSettleNotification,
            object: nil, queue: .main, using: rideEditor)
        // Unpinning from the panel's own button changes no key state, so the
        // panel has to ask for the ride itself — see the pin state's didSet.
        floating.editorWindow = { [weak capture] in capture?.editor.hostWindow }

        if FloatingCaptureLifecycle.shouldRestoreAtLaunch(
            wasOpenAtQuit: UserDefaults.standard.bool(forKey: Self.floatingOpenAtQuitKey)),
           !Self.isRunningUnitTests {
            // `show()` refuses while locked. Launching straight into a locked
            // session must not lose the panel for the rest of the session, so
            // mark it for restore and let the unlock bring it back.
            floating.show()
            if CaptureCoordinator.isLocked { floating.markPendingUnlockRestore() }
        }

        // Lock and unlock are the same notification; the panel goes down on one
        // and comes back on the other.
        floatingLockObserver = NotificationCenter.default.addObserver(
            forName: .encryptionLockStateDidChange, object: nil, queue: .main
        ) { [weak floating, weak editorController = capture.editor] _ in
            MainActor.assumeIsolated {
                guard let floating else { return }
                if CaptureCoordinator.isLocked {
                    floating.hideForLock()
                } else {
                    floating.restoreAfterUnlock()
                }
                editorController?.setFloatingWindowOpen(floating.isVisible)
            }
        }
        capture.editor.setFloatingWindowOpen(floating.isVisible)
    }

    /// True when hosted by XCTest. The unit-test host must NOT run the app's
    /// launch side-effects (background OCR sweep over the real library, opening
    /// the editor, the updater) — those processed the whole library and made the
    /// test-runner process balloon in memory.
    static var isRunningUnitTests: Bool {
        NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        os_log("applicationDidFinishLaunching", log: log, type: .info)
        WindowDiag.launch("applicationDidFinishLaunching")
        guard !Self.isRunningUnitTests else {
            os_log("applicationDidFinishLaunching: under XCTest — skipping launch side-effects",
                   log: log, type: .info)
            // This guard silently skips opening the editor. If it ever fires in
            // a real launch, that alone explains a windowless app.
            WindowDiag.note("SKIPPED all launch side-effects: isRunningUnitTests == true")
            return
        }
        // Drop the auto-inserted "Sealshot Help" item: no help book is bundled,
        // so it only dead-ends in the system "Help isn't available" alert.
        // SwiftUI's CommandGroup(replacing: .help) removes it from the menu;
        // redirecting AppKit's helpMenu to an orphan menu stops AppKit from
        // re-inserting the standard help item into the visible Help menu.
        NSApp.helpMenu = NSMenu()
        // Launch unlock — FIRST, before any window exists. The user turned off
        // "Lock when Sealshot starts", so the session must already hold the
        // identity by the time the editor window computes its lock state;
        // doing this later (or asynchronously) would flash the lock overlay
        // for a frame on every launch. The keychain read prompts nothing and
        // takes well under a millisecond.
        unlockAtLaunchIfOptedOut()
        startDeletedFolderPurge()
        // One-time migration: OCR pre-v4 packages so the whole Library is
        // text-searchable. Serial, utility priority, idempotent.
        if let saveFolder = captureCoordinator?.saveFolder {
            OCRBackfillCoordinator.shared.start(saveFolder: saveFolder)
            // Convert legacy directory packages to containers in the
            // background — see SealFormatConverter for why this is a lazy
            // sweep and not a launch-time bulk pass.
            SealFormatConverter.shared.start(saveFolder: saveFolder)
            // Summaries (image + video) backfill on open — driven by the editor's
            // syncExtractionState / view-driven video gen — so there is no
            // background sweep creating FM contexts and AVPlayers over the whole
            // library (the source of the memory runaway).
        }
        // Safety guards: pause the background backfill if memory runs away, and
        // log any main-thread stall. Containment, not a substitute for fixing a leak.
        MemoryGuard.shared.onHighMemory = {
            OCRBackfillCoordinator.shared.cancel()
        }
        MemoryGuard.shared.start()
        // Diagnostic scroll-event sniffer (flag-gated, normally off).
        ScrollDiag.installSnifferIfEnabled()
        HangMonitor.shared.start()
        // Re-lock on sleep / screen-lock / fast-user-switch.
        relockController = RelockController(
            isEnabledAndUnlocked: { EncryptionSession.shared.isEnabled && EncryptionSession.shared.isUnlocked },
            lock: { EncryptionSession.shared.lock() },
            isBusy: { [weak self] in
                (self?.captureCoordinator?.isCaptureSessionActive ?? false)
                    || (self?.recordingCoordinator?.isBusy ?? false)
            })
        relockController?.start()
        // Re-trigger OCR backfill when the user unlocks: packages skipped
        // at launch (because they were locked) now need to be processed.
        lockObserver = NotificationCenter.default.addObserver(
            forName: .encryptionLockStateDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard EncryptionSession.shared.isUnlocked else { return }
                // Replay files opened via "Open With" while the session was locked.
                self?.flushPendingOpenURLs()
                guard let folder = self?.captureCoordinator?.saveFolder else { return }
                // Self-heal a deleted keystore.json while the identity is in
                // memory (no extra auth prompt) — the escrow is the only copy
                // of the recovery path, so a fresh code must reach the user.
                if let newCode = KeystoreAutoRepair.repairIfNeeded(
                    session: EncryptionSession.shared, saveFolder: folder) {
                    self?.presentKeystoreRepaired(newCode: newCode)
                }
                OCRBackfillCoordinator.shared.restart(saveFolder: folder)
            }
        }
        // Open the editor on launch with the most recent capture (or the empty
        // canvas when there is none) — same path as ⌘⇧E / a Dock-icon click.
        WindowDiag.note("launch: calling triggerOpenEditor()")
        captureCoordinator?.triggerOpenEditor()
        WindowDiag.windows("after launch triggerOpenEditor")
        // Start the updater (Sparkle in Direct builds; inert no-op in MAS).
        UpdaterController.shared.startUpdater()
        // Licensing: evaluate entitlement (Direct only — MAS is always entitled).
        // Refresh the revocation blocklist only when "Automatically check for
        // updates" is on (the same setting the General tab binds to) — without
        // this gate it's a third, user-uncontrollable network request on every
        // launch. Skipping the fetch never clears the cache: BlocklistCache is
        // what makes a received revocation stick offline, and evaluate() reads
        // the cache, not the network.
        let entitlements = EntitlementStore.shared
        if AppInfo.edition == .direct, UpdaterController.shared.automaticallyChecksForUpdates {
            let appSupport = AppSupportDirectory.sealshot
            BlocklistFetcher.refresh(cache: BlocklistCache(directory: appSupport)) { list in
                entitlements.apply(blocklist: list)
            }
        }
        // Storage hardening: Spotlight exclusion + tight perms on data dirs.
        if let saveFolder = captureCoordinator?.saveFolder {
            StorageHardening.apply(to: saveFolder)
        }
        // "Include title & app in filename" governs all captures now (default
        // ON); encrypted libraries whose user never touched it keep their
        // historic timestamp-only privacy default. Idempotent.
        FilenameIncludesTitlePreference.applyEncryptionPrivacyDefault(
            encryptionEnabled: EncryptionSession.shared.isEnabled)
        StorageHardening.apply(to: EncryptionSession.defaultCapsuleFolder
            .deletingLastPathComponent()) // …/Application Support/Sealshot
        // First launch only: welcome window on top of the editor (privacy
        // tour, shortcuts, Screen Recording walkthrough).
        captureCoordinator?.showWelcomeIfNeeded()
        // Last on purpose: present() blocks on runModal until dismissed, so
        // everything above (editor, updater, welcome) must already be set up.
        if let report = pendingCrashReport {
            pendingCrashReport = nil
            CrashNoticePresenter.present(reportURL: report)
        }
    }

    /// Opens the encrypted session without a Touch ID prompt when the user has
    /// turned off "Lock when Sealshot starts" (Settings → Privacy & Security).
    ///
    /// Declines — leaving the app locked, exactly as every build shipped before
    /// this — unless encryption is on, the preference is off, AND the identity
    /// is actually reachable on this Mac. That last condition matters: after a
    /// keychain reset the silent read would fail anyway, and staying locked
    /// lets the lock screen offer the recovery path instead of dead-ending.
    private func unlockAtLaunchIfOptedOut() {
        let session = EncryptionSession.shared
        guard LaunchUnlockPolicy.shouldUnlockAtLaunch(
            encryptionEnabled: session.isEnabled,
            identityAvailable: session.identityAvailable,
            locksAtLaunch: LaunchLockPreference().locksAtLaunch) else { return }
        do {
            let ok = try session.unlockWithoutPresence()
            os_log("launch unlock (lock-at-startup off): %{public}@",
                   log: log, type: .info, ok ? "unlocked" : "declined")
        } catch {
            // Fail closed: the lock screen comes up and the user unlocks by hand.
            os_log("launch unlock failed: %{public}@", log: log, type: .error,
                   String(describing: error))
        }
    }

    /// Repeating timer behind the periodic Deleted-folder sweep.
    private var deletedPurgeTimer: Timer?

    /// Sweep at launch AND every few hours after: launch-only purging never
    /// fires for a user who keeps the app open for days, so a 1-day
    /// retention looked broken. Reads the retention setting fresh per sweep.
    private func startDeletedFolderPurge() {
        runDeletedFolderPurge()
        // Scratch rides the same schedule: unkept captures age out alongside
        // the trash, with no timer of their own to maintain.
        runScratchPurge()
        let timer = Timer(timeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.runDeletedFolderPurge()
                self?.runScratchPurge()
            }
        }
        timer.tolerance = 15 * 60   // battery-friendly; timing is not critical
        RunLoop.main.add(timer, forMode: .common)
        deletedPurgeTimer = timer
    }

    /// Fire-and-forget detached low-QoS task that sweeps anything trashed
    /// longer ago than the configured retention period from
    /// <saveFolder>/Deleted/. Errors are logged; the UI never waits on this.
    private func runScratchPurge() {
        guard let saveFolder = captureCoordinator?.saveFolder else { return }
        let removed = ScratchCapture.purge(in: saveFolder)
        if removed > 0 {
            os_log("scratch purge removed %{public}d", log: log, type: .info, removed)
        }
    }

    private func runDeletedFolderPurge() {
        guard let coordinator = captureCoordinator else { return }
        let saveFolder = coordinator.saveFolder
        let days = coordinator.retentionDays
        Task.detached(priority: .utility) {
            _ = SealPurger.purgeDeletedFolder(
                in: saveFolder,
                olderThan: days
            )
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Remembered so the app comes back the way it was left, and so a
        // Dock-icon click lands on the surface the user was actually using.
        UserDefaults.standard.set(floatingCaptureController?.isVisible == true,
                                  forKey: Self.floatingOpenAtQuitKey)
        deletedPurgeTimer?.invalidate()
        sessionMarkerStore.clearOnCleanQuit()
        relockController?.stop()
        if let observer = lockObserver {
            NotificationCenter.default.removeObserver(observer)
            lockObserver = nil
        }
        if let observer = floatingEditorOrderObserver {
            NotificationCenter.default.removeObserver(observer)
            floatingEditorOrderObserver = nil
        }
        if let observer = floatingEditorSettleObserver {
            NotificationCenter.default.removeObserver(observer)
            floatingEditorSettleObserver = nil
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    /// Called when the user clicks the Dock icon while Sealshot is already
    /// running: show the app's window, raising an open one as-is and bringing a
    /// closed one back on the tab it was showing.
    /// Return `false` to tell AppKit "I handled this, don't run default
    /// behavior" (which would be a no-op since we have no main window).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        WindowDiag.note("Dock reopen: hasVisibleWindows=\(flag)")
        WindowDiag.windows("before Dock reopen")
        defer { WindowDiag.windows("after Dock reopen") }
        // `flag` is deliberately ignored. It reports whether ANY window is
        // visible, and the floating capture panel is a window — so with the
        // panel on screen the old `if !flag` guard made a Dock click do nothing
        // whatsoever. The editor's own window is what matters, and
        // `reopenFromDock` keys off that instead. It also deliberately does NOT
        // route through `triggerOpenEditor`: that forces the Editor tab, which
        // threw away whatever tab the user was on.
        captureCoordinator?.triggerReopenFromDock()
        return false
    }

    /// Finder "Open With" / double-click. `importFiles` already partitions
    /// `.sealshare` packages (which handle their own unlock) from images and
    /// PDFs (which are copied into the Library as new `.seal` packages).
    /// Writing a new package needs the session key, so when encryption is on
    /// but locked we queue the URLs and surface the editor's lock overlay;
    /// `flushPendingOpenURLs()` replays them the moment the user unlocks.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard !urls.isEmpty else { return }
        let session = EncryptionSession.shared
        if session.isEnabled && !session.isUnlocked {
            pendingOpen.enqueue(urls)
            captureCoordinator?.triggerOpenEditor()   // empty editor + Unlock button
            return
        }
        captureCoordinator?.importFiles(urls)
    }

    /// Replay any "Open With" URLs that arrived while the session was locked.
    /// No-op when nothing is queued.
    private func flushPendingOpenURLs() {
        let urls = pendingOpen.drain()
        guard !urls.isEmpty else { return }
        captureCoordinator?.importFiles(urls)
    }

    /// The missing keystore.json was just recreated with a FRESH recovery code
    /// (the old one lived only sealed inside the deleted file, so it cannot
    /// come back). Reuses the standard recovery-key ceremony — copy button +
    /// "I've saved it" checkbox gating Done — in a modal window with no close
    /// button, so the code can't be dismissed unacknowledged.
    private func presentKeystoreRepaired(newCode: String) {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.title = "Recovery File Recreated"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: RecoveryKeyCeremonyView(
            code: newCode,
            message: "Your recovery file (keystore.json) was missing from the captures "
                + "folder, so Sealshot created a new one with a NEW recovery code — any "
                + "previous code no longer works. Save this code somewhere safe. It's the "
                + "only way to recover your encrypted captures if you lose access to this Mac.",
            onDone: { NSApp.stopModal() }))
        window.center()
        NSApp.runModal(for: window)
        window.orderOut(nil)
    }
}
