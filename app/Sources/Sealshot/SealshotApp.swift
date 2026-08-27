import AppKit
import SwiftUI

@main
struct SealshotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var recordingState = RecordingMenuState.shared
    @ObservedObject private var exportState = ExportMenuState.shared
    @ObservedObject private var objectMenu = ObjectMenuState.shared
    // Soft lock: while the app is locked, disable menu actions that touch
    // existing/decrypted content or the editor (New/Import/Insert/Export, View).
    // Capture & recording stay enabled (they write a write-only encrypted .seal).
    @ObservedObject private var lock = AppLockState.shared
    // Nothing is license-gated: Sealshot is free to use, and a license only
    // silences the support reminder (SupportNudgePolicy).
    @ObservedObject private var entitlements = EntitlementStore.shared

    private var capture: CaptureCoordinator? { appDelegate.captureCoordinator }
    private var recording: RecordingCoordinator? { appDelegate.recordingCoordinator }

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            // App menu: About / Check for Updates / Settings.
            CommandGroup(replacing: .appInfo) {
                Button("About Sealshot") { NSApp.orderFrontStandardAboutPanel(nil) }
                if AppInfo.edition == .direct {
                    Button("Check for Updates…") { UpdaterController.shared.checkForUpdates() }
                }
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { guard !lock.isLocked else { return }; capture?.triggerOpenSettings() }
                    .keyboardShortcut(",", modifiers: .command)
                    .disabled(lock.isLocked)
            }

            // File: new / open / insert / export.
            //
            // Every closure re-checks `lock.isLocked` at invocation: SwiftUI's
            // App-level `.disabled()` greys the visible item but does NOT
            // reliably gate the key equivalent (the App's ObservedObject may
            // not re-evaluate `.commands` before AppKit dispatches ⌘S/⌘N/etc.),
            // so the guard is what actually makes the shortcut inert while
            // locked. Capture/record actions (own menu, no key equivalents)
            // stay live — soft lock.
            CommandGroup(replacing: .newItem) {
                Button("New Canvas") {
                    guard !lock.isLocked else { return }
                    capture?.openNewCanvas()
                }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(lock.isLocked)
                Button("New from Clipboard") {
                    guard !lock.isLocked else { return }
                    capture?.openCanvasFromClipboard()
                }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(!NewCanvasFactory.clipboardHasImage() || lock.isLocked)
                Divider()
                // Unified import: accepts images AND Sealshot `.sealshare`
                // packages in one panel (see CaptureCoordinator.importFiles,
                // which routes packages to ImportPackageCoordinator).
                Button("Import to Library…") { guard !lock.isLocked else { return }; capture?.presentImportPanel() }
                    .keyboardShortcut("o", modifiers: .command)
                    .disabled(lock.isLocked)
                Button("Insert Image on Canvas…") { guard !lock.isLocked else { return }; capture?.insertImageOnCanvas() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                    .disabled(lock.isLocked)
                // For people who'd rather manage captures in Finder than in
                // any app's browser. Not gated on the lock: opening a FOLDER
                // reveals nothing a locked session protects — the packages
                // inside stay encrypted either way.
                Button("Open Library Folder in Finder") {
                    capture?.openLibraryFolderInFinder()
                }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Divider()
                // Export lives in the .newItem group so it renders above the
                // standard Close / Close All items (SwiftUI owns the menu order).
                Button("Export to Image") {
                    guard !lock.isLocked else { return }
                    ExportImageCoordinator.present(sources: exportState.resolveSources(), host: NSApp.keyWindow)
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(exportState.isEmpty || lock.isLocked)
                Button("Export to Video…") {
                    guard !lock.isLocked else { return }
                    VideoExportCoordinator.present(sources: exportState.resolveSources(), host: NSApp.keyWindow)
                }
                .disabled(!exportState.hasVideo || lock.isLocked)
                Button("Export to Package…") {
                    guard !lock.isLocked else { return }
                    ExportPackageCoordinator.present(sources: exportState.resolveSources(), host: NSApp.keyWindow)
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(exportState.isEmpty || lock.isLocked)
            }

            // Edit ▸ object actions. Cut/Copy/Paste are already provided by the
            // standard Edit menu and validated through EditorWindow's responder
            // methods; these are the ones AppKit has no default for.
            CommandGroup(after: .pasteboard) {
                Button("Duplicate") {
                    guard !lock.isLocked else { return }
                    capture?.editor.duplicateSelection()
                }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(!objectMenu.hasSelection || lock.isLocked)

                Divider()

                Button("Bring to Front") {
                    guard !lock.isLocked else { return }
                    capture?.editor.reorderSelection(.toFront)
                }
                .keyboardShortcut("]", modifiers: [.command, .option])
                .disabled(!objectMenu.hasSelection || lock.isLocked)

                Button("Bring Forward") {
                    guard !lock.isLocked else { return }
                    capture?.editor.reorderSelection(.forward)
                }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!objectMenu.hasSelection || lock.isLocked)

                Button("Send Backward") {
                    guard !lock.isLocked else { return }
                    capture?.editor.reorderSelection(.backward)
                }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!objectMenu.hasSelection || lock.isLocked)

                Button("Send to Back") {
                    guard !lock.isLocked else { return }
                    capture?.editor.reorderSelection(.toBack)
                }
                .keyboardShortcut("[", modifiers: [.command, .option])
                .disabled(!objectMenu.hasSelection || lock.isLocked)

                Divider()

                Button("Flip Horizontal") {
                    guard !lock.isLocked else { return }
                    capture?.editor.flipSelection(horizontal: true)
                }
                .disabled(!objectMenu.hasFlippableSelection || lock.isLocked)

                Button("Flip Vertical") {
                    guard !lock.isLocked else { return }
                    capture?.editor.flipSelection(horizontal: false)
                }
                .disabled(!objectMenu.hasFlippableSelection || lock.isLocked)
            }

            // Capture & record. No key equivalents here — these actions have
            // their own user-customizable global shortcuts (KeyboardShortcuts);
            // duplicating them as menu shortcuts would fire twice when frontmost.
            // While recording, the capture/record entries give way to the
            // recording controls (matching the menu-bar status item), so the
            // only actions are pause/resume and stop.
            CommandMenu("Capture") {
                if recordingState.isRecording {
                    Button(recordingState.paused ? "Resume Recording" : "Pause Recording") {
                        recording?.togglePause()
                    }
                    Button("Stop Recording") { recording?.stopRecording() }
                } else {
                    // Capture actions mirror the status-item menu's first group,
                    // in the same order and grouping, so both menus match.
                    Button("Smart Capture") { capture?.triggerUnifiedCapture() }
                    Button("Save As Capture…") { capture?.triggerSaveAsCapture() }
                    Divider()
                    Button("Full Screen Capture") { capture?.triggerFullscreenCapture() }
                    Button("Delayed Capture") { capture?.triggerDelayedCapture() }
                    Button("Scrolling Capture") { capture?.triggerScrollCapture() }
                    Button("Live Capture") { capture?.triggerLiveCapture() }
                    // Titled with the area's size when there is one: this
                    // command fires with no overlay and no confirmation, so
                    // the menu is the only chance to say what it will grab.
                    Button(RepeatCaptureMenuTitle.forRegion(capture?.resolvedRepeatRegion())) {
                        capture?.triggerRepeatCapture()
                    }
                    Divider()
                    Button("Record Full Screen") { recording?.toggle() }
                    Button("Record Selected Area…") { recording?.beginSelection() }
                }
            }

            // View: zoom / fit / panels — added to the system View menu (via the
            // .sidebar placement) so there's a single View menu, not a second
            // one. Zoom shortcuts mirror the editor's own (editor-only keys).
            CommandGroup(after: .sidebar) {
                Group {
                    // Same as File above: the guard (not just `.disabled`) is
                    // what makes the ⌘+ / ⌘- / ⌘0 key equivalents inert while
                    // locked, since App-level `.disabled()` doesn't reliably
                    // gate key equivalents.
                    Button("Zoom In") { guard !lock.isLocked else { return }; capture?.editor.zoomIn() }
                        .keyboardShortcut("+", modifiers: .command)
                    Button("Zoom Out") { guard !lock.isLocked else { return }; capture?.editor.zoomOut() }
                        .keyboardShortcut("-", modifiers: .command)
                    Button("Actual Size") { guard !lock.isLocked else { return }; capture?.editor.zoomActualSize() }
                        .keyboardShortcut("0", modifiers: .command)
                    Divider()
                    Button("Fit to Window") { guard !lock.isLocked else { return }; capture?.editor.fitWindow() }
                    Button("Fit Width") { guard !lock.isLocked else { return }; capture?.editor.fitWidth() }
                    Button("Fit Height") { guard !lock.isLocked else { return }; capture?.editor.fitHeight() }
                    Divider()
                    Button("Show / Hide Info Panel") { guard !lock.isLocked else { return }; capture?.editor.toggleInfoPanel() }
                    Button("Show / Hide Recent Strip") { guard !lock.isLocked else { return }; capture?.editor.toggleRecentStrip() }
                    // These two sit in the section ABOVE deliberately, with the
                    // divider after them rather than before. macOS gives "Enter
                    // Full Screen" an icon and then reserves icon width for
                    // every item sharing its section, so anything in the last
                    // section is drawn indented next to that glyph. Grouping
                    // these with the Show/Hide items keeps them flush and
                    // leaves the system's own section exactly as it was.
                    //
                    // Same guard pattern as the zoom items above: App-level
                    // `.disabled()` doesn't reliably gate a menu item's action.
                    // Locked on purpose — the editor's pip button vanishes with
                    // the toolbar on relock, so leaving this route open would
                    // make the menu the one way to summon a panel whose every
                    // button refuses.
                    Button("Floating Capture Window") {
                        guard !lock.isLocked else { return }
                        capture?.toggleFloatingWindow()
                    }
                    // The floating window's own menu cannot rescue a floating
                    // window you cannot see, so this route has to live out
                    // here in the menu bar.
                    Button("Reset Floating Window Position") {
                        guard !lock.isLocked else { return }
                        capture?.resetFloatingWindowPosition()
                    }
                    Divider()
                }
                // View acts on the (locked) editor content — disable while locked.
                .disabled(lock.isLocked)
            }

            // Replace (not add-after) the .help group to drop the
            // auto-generated "Sealshot Help" item: no help book is bundled, so
            // it only dead-ends in the system "Help isn't available" alert.
            // The Help menu keeps just our own "Send Feedback…".
            CommandGroup(replacing: .help) {
                Button("Send Feedback…") { FeedbackComposer.present() }
            }
        }
    }
}
