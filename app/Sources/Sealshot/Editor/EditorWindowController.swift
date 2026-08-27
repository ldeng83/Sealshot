import AppKit
import AVFoundation
import AVKit
import Combine
import CryptoKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import os.log

private let log = OSLog(subsystem: "com.seal-shot.sealshot", category: "editor")
/// Diagnostics for the "expand canvas to fit" grow — filter in Console with
/// `subsystem:com.seal-shot.sealshot category:canvas-grow`.
private let growLog = OSLog(subsystem: "com.seal-shot.sealshot", category: "canvas-grow")

@MainActor
final class EditorWindowController: NSWindowController {

    private(set) var state: EditorState?
    private let saver: EditorSaveCoordinator
    private let config: CaptureConfig
    private var canvas: EditorCanvasView?
    private var canvasScroll: EditorCanvasScrollView?
    private weak var container: NSStackView?
    private weak var canvasHost: NSView?
    private var sidebar: EditorSidebarView?
    private var recentStrip: RecentStripView
    private var deletedStrip: RecentStripView?
    private let onRecentClickStored: (URL) -> Void
    private let toolbarBuilder = EditorToolbarBuilder()
    private var autosaveWorkItem: DispatchWorkItem?
    private var stripPreviewWorkItem: DispatchWorkItem?
    /// Off-main queue for the strip-preview composite render.
    private let stripPreviewRenderQueue = DispatchQueue(
        label: "com.seal-shot.sealshot.strip-preview", qos: .userInitiated)
    /// Test hook: how many strip-preview renders have been dispatched.
    private(set) var debugStripPreviewRenderCount = 0
    private weak var stripContainer: NSStackView?
    /// Drives the strip wrapper's height; mutated live as the user drags the
    /// resize handle. Its constant is the persisted strip height.
    private var stripHeightConstraint: NSLayoutConstraint?
    /// Current strip height (constraint constant), read by the strip factories
    /// so every (re)mount builds at the user's chosen size.
    private var stripHeight: CGFloat = StripHeightPreference.defaultHeight
    /// The drag handle above the strip. Collapsed alongside the strip wrapper
    /// when the user hides the strip (you can't resize what isn't shown).
    private weak var stripResizeHandle: StripResizeHandle?
    /// Whether the recent strip is currently collapsed. Mirrors the persisted
    /// `StripVisibilityPreference`; toggled by the meta-row chevron / ⌥⌘S.
    private var stripHidden = false
    /// Full-width bottom dock (meta row + recent strip) below the split, so the
    /// side panels never resize it.
    private weak var bottomDock: NSStackView?
    private weak var metaRow: EditorMetaRowView?
    /// Retained token for the captureMetadataDidChange observer so it can be
    /// removed on deinit (mirrors the windowCloseObserver pattern).
    private var metadataChangeObserver: NSObjectProtocol?
    /// Tokens for `.capturesPermanentlyDeleted` / `.capturesTrashed` — a
    /// Library purge or trash-delete of the open (or playing) file must clear
    /// it out of the canvas and strips.
    private var permanentDeleteObserver: NSObjectProtocol?
    private var libraryTrashObserver: NSObjectProtocol?
    private var saveFolderObserver: NSObjectProtocol?

    /// Tracks which strip the user is viewing. In loaded mode this mirrors
    /// `state.bottomTab`; in empty mode it's the source of truth (no state
    /// exists). On upgrade via swap(toState:), copied into the new state.
    private var currentTab: BottomTab = .recent
    /// Strip media filter (All / Images / Videos), persisted across launches.
    private var mediaFilter: StripMediaFilter = StripMediaFilterPreference.load()

    // MARK: - Shell tab state
    /// Readable so `EditorController` can remember it as the window closes and
    /// a Dock-click reopen can come back to the same tab.
    private(set) var currentTabSelection: ShellTab = .editor

    /// On the Editor tab, whether the recent strip is the active surface for
    /// ⌘A: set true on any strip click, cleared when the user clicks the canvas.
    /// Independent of AppKit first responder (which stays on the canvas), so the
    /// open triggered by a plain tile click can't steal it. `focusedStrip` is
    /// the strip that was last clicked (recent vs deleted).
    private var editorStripFocused = false
    private weak var focusedStrip: RecentStripView?
    /// The editor's own content (the split view) — retained so it can be
    /// toggled back when returning to the Editor tab.
    private var editorContentView: NSView?
    private var libraryPlaceholder: NSView?
    private var libraryViewModel: LibraryViewModel?
    /// Keeps the Library index fresh while the tab is visible: saves, OCR
    /// backfill, Finder deletes etc. all land as FSEvents on the save folder.
    private var libraryFolderWatcher: FolderWatcher?
    /// Watches the save folder tree (which contains Deleted/) while strips
    /// exist, so external changes — Finder deletes, OCR backfill rewrites,
    /// other-window saves — reconcile the strips without a tab switch.
    private var stripFolderWatcher: FolderWatcher?
    /// The single app-global undo/redo timeline — annotation edits, capture
    /// file events (delete/restore/import), navigation, video metadata, and
    /// reverts, all interleaved by push order. ⌘Z/⌘⇧Z route through this store;
    /// it also owns persistence (via `GlobalUndoTimelineStore`). Lazy so the
    /// @MainActor shared backend is touched on first main-actor access.
    lazy var globalUndo = GlobalUndoStore(backend: GlobalUndoTimelineStore.shared)
    /// True while a timeline undo/redo is being applied — suppresses the
    /// navigation/checkpoint side effects of the swaps it drives (Tasks 4-5
    /// consult this so a programmatic reopen doesn't record a navigation entry).
    /// Only covers `performTimelineStep`'s SYNCHRONOUS dispatch — see
    /// `navigationSuppressionCount` for the async tail some file events have.
    private(set) var isPerformingUndoRedo = false
    /// Counts file-event undo/redo async reopens that may still be in flight
    /// — `deleteBatch` kicks off a `Task` (via `performBulkDelete`) whose
    /// open-file neighbor switch can run AFTER `performTimelineStep`'s
    /// `defer` has already reset `isPerformingUndoRedo` to false. Without
    /// this, that reopen would call `presentFile`/`playVideoInCanvas` looking
    /// like a user click and mint a spurious `.navigation` entry mid-undo.
    /// Incremented before the `Task` is scheduled, decremented in that same
    /// Task's own `defer` once its synchronous work (including any neighbor
    /// switch) completes. A COUNTER, not a Bool: `performTimelineStep`
    /// returns immediately after scheduling the Task, so two rapid ⌘Z/⌘⇧Z
    /// presses over two file events can have TWO of these Tasks in flight at
    /// once, sharing this state. With a plain Bool, whichever Task finished
    /// first would clear it while the other Task's neighbor switch was still
    /// pending, letting that switch mint a spurious `.navigation` entry (and
    /// via `GlobalUndoStore.record` clearing the redo stack, destroying the
    /// user's ability to ⌘⇧Z the file events back). The counter keeps
    /// suppression active as long as ANY Task is outstanding: two overlapping
    /// Tasks push the count to 2, and it only reaches 0 — un-suppressing —
    /// once the LAST one drains.
    private var navigationSuppressionCount = 0
    /// Single check `presentFile` / `playVideoInCanvas` consult before
    /// recording a `.navigation` entry: true for the synchronous undo/redo
    /// dispatch AND its async file-event tail (see the two flags above).
    var navigationRecordingSuppressed: Bool { isPerformingUndoRedo || navigationSuppressionCount > 0 }
    /// In-memory undo for "Revert to Original" (see RevertHistory). Session-only.
    private let revertHistory = RevertHistory()
    private var importObserver: NSObjectProtocol?
    /// True while a SealMetadataStore write is our own doing (undo/redo
    /// restore, or the rename path which mints its own labeled checkpoint) —
    /// the metadata-undo store hook must not re-mint a checkpoint for those.
    private var suppressMetadataCheckpoints = false
    /// Progress sheet for slow bulk delete / restore batches.
    private let bulkProgress = BulkProgressSheet()
    private var settingsPlaceholder: NSView?
    // Held STRONGLY: `refreshLockOverlay` hides the window toolbar on relock,
    // which makes AppKit release the toolbar item — the only other owner of this
    // control. A weak ref would then deallocate it, and on unlock the toolbar's
    // item provider would rebuild to nothing (tabs vanish permanently). Keeping
    // our own strong ref survives the hide/show cycle. No retain cycle: the
    // control's `target` (this controller) is a non-retaining reference.
    private var tabSwitcher: NSSegmentedControl?
    /// The tool bar and filename live in a header at the top of the editor
    /// content column (NOT titlebar accessories — those are height-capped at
    /// ~toolbar height, so they can't take vertical padding). The whole
    /// `editorContentView` column hides on non-Editor tabs, taking the header
    /// with it. `toolsHost` is rebuilt on empty→loaded; `titleHost` holds the
    /// icon + filename row.
    private weak var splitView: NSSplitView?
    /// Mutable width constraint on the right sidebar, driven by the leading-edge
    /// `SidebarResizeHandle`. Seeds the initial/rebuilt width.
    private var sidebarWidthConstraint: NSLayoutConstraint?
    /// Current sidebar width, updated live as the handle is dragged so a
    /// state-swap rebuild restores the user's chosen width.
    private var sidebarWidth: CGFloat = SidebarWidthPreference.defaultWidth
    private weak var toolsHost: NSView?
    /// The fold plan the tool bar was last BUILT for. Compared against a fresh
    /// plan on every layout pass so the (expensive) rebuild only happens when
    /// the answer actually changes, not on every pixel of a resize drag.
    private var appliedToolbarFold: Set<EditorToolbarFit.ClusterID> = []
    /// Content width currently being negotiated by a resize, if any. Takes
    /// precedence over the laid-out width — see `applyToolbarFit`.
    private var pendingResizeContentWidth: CGFloat?
    private weak var titleHost: NSView?
    /// The native window title is hidden so the tab switcher can sit on the
    /// traffic-light line (as a unified toolbar); the filename is re-rendered
    /// in the header (icon + label) *below* the tool bar.
    private weak var titleLabel: NSTextField?
    private weak var titleIcon: NSImageView?
    /// Spinner in the centered title row, shown while the capture's AI filename
    /// is being generated (mirrors the recent-strip tile spinner).
    private weak var titleRowSpinner: NSProgressIndicator?
    /// ★ Favorite toggle pinned to the right edge of the title bar (was the
    /// Info panel's Workflow section). Reflects/sets the current capture's
    /// `isFavorite`; hidden when there's no saved source URL.
    private weak var titleFavoriteButton: NSButton?
    /// Width of `titleLabel`, recomputed from its text on every title change
    /// (the editable field has no content-based intrinsic width). Below the
    /// row's required inset inequalities, so long titles truncate instead.
    private var titleLabelWidth: NSLayoutConstraint?
    /// Toolbar item id for the centered Editor/Library/Settings switcher.
    private nonisolated static let tabsItemID = NSToolbarItem.Identifier("com.seal-shot.editor.tabs")
    /// Toolbar item id for the floating-capture-window toggle at the row's
    /// trailing edge.
    nonisolated static let floatingItemID =
        NSToolbarItem.Identifier("com.seal-shot.editor.floatingWindow")
    /// Test hook for the private tabs identifier.
    nonisolated static var tabsItemIDForTesting: NSToolbarItem.Identifier { tabsItemID }

    /// Invoked by the toolbar button; wired to the floating controller in
    /// `AppDelegate` so this button and the View menu share one toggle.
    var onToggleFloatingWindow: (() -> Void)?
    private weak var floatingToolbarButton: ActiveToolPillView?
    private var floatingWindowIsOpen = false

    /// The toolbar button reports the PANEL's state, not the editor's — which
    /// is what keeps "window, not mode" legible. Picture-in-picture is the
    /// platform's existing idiom for "give me a small always-on-top version of
    /// this", so it reads on first sight.
    nonisolated static func floatingWindowSymbol(isOpen: Bool) -> String {
        isOpen ? "pip.exit" : "pip.enter"
    }
    /// Persistent container that stays as window.contentView; child views are
    /// shown/hidden rather than swapping contentView directly.
    private weak var shellContainer: NSView?

    // MARK: - License banner
    /// Fixed-height strip pinned to the top of `shellContainer`, ABOVE the
    /// editor/library/settings content (whose top anchors chain off its
    /// bottom instead of the shell's) — spans every tab and pushes content
    /// down when visible, never overlaying it. Height toggles between 0 and
    /// `licenseBannerHeight` (see `updateLicenseBanner`) rather than swapping in
    /// and out, so the constraint graph never changes shape.
    private weak var licenseBannerHost: NSView?
    /// The SwiftUI content mounted inside `licenseBannerHost`, created lazily on
    /// first show and reused (rootView swapped) thereafter — mirrors the
    /// libraryPlaceholder/settingsPlaceholder "mount once, toggle after"
    /// pattern in `selectTab`.
    private weak var licenseBannerContentHost: NSHostingView<LicenseBannerView>?
    private var licenseBannerHeightConstraint: NSLayoutConstraint?
    private let licenseBannerHeight: CGFloat = 34
    /// What the user dismissed the banner at THIS session (nil = nothing
    /// dismissed yet). See `LicenseBannerPolicy` for the exact suppression
    /// rules this feeds.
    private var licenseBannerDismissed: LicenseBannerKind?
    /// Combine subscription driving the banner from `EntitlementStore`'s
    /// `@Published state` — activation/removal/blocklist changes remove or
    /// show the banner live, no relaunch needed.
    private var entitlementCancellable: AnyCancellable?
    /// Token for `NSWindow.didBecomeKeyNotification`, used to opportunistically
    /// re-run `EntitlementStore.refresh()` (see `lastEntitlementRefresh`).
    private var licenseBannerWindowKeyObserver: NSObjectProtocol?
    /// Last time this window becoming key triggered `EntitlementStore.refresh()`.
    /// Seeded at controller init so the window's first activation doesn't
    /// immediately re-trigger a refresh right after the app-launch evaluation.
    private var lastEntitlementRefresh = Date()

    /// Closure invoked when the user clicks the empty-mode Capture toolbar
    /// button or drops a file on the empty canvas. Set by EditorController.
    var onCaptureRequested: (() -> Void)?
    var onWindowCaptureRequested: (() -> Void)?
    var onUnifiedCaptureRequested: (() -> Void)?
    var onDelayedCaptureRequested: (() -> Void)?
    var onScrollCaptureRequested: (() -> Void)?
    var onLiveCaptureRequested: (() -> Void)?
    /// `nil` choice = the cursor's display (default). The toolbar passes a chosen
    /// `DisplayChoice` for multi-monitor capture/record.
    var onFullscreenCaptureRequested: ((DisplayChoice?) -> Void)?
    var onRecordScreenRequested: ((DisplayChoice?) -> Void)?
    var onRecordSelectionRequested: (() -> Void)?
    var onFileDropped: ((URL) -> Void)?
    var onNewCanvasRequested: (() -> Void)?
    var onNewFromClipboardRequested: (() -> Void)?
    var onImportRequested: (() -> Void)?
    /// Import specific files (drop-to-import from the strip / Library grid) —
    /// same downstream path as ⌘O / Import… (CaptureCoordinator.importFiles).
    /// `revealInLibrary` = the drop originated in the Library, so the result
    /// should stay there (batch-selected + highlighted) instead of opening
    /// the editor.
    var onImportFilesRequested: ((_ urls: [URL], _ revealInLibrary: Bool) -> Void)?
    /// The scratch capture on screen should be KEPT — moved into the Library.
    /// Owned by EditorController, which can re-point the session at the moved
    /// file; the window controller only relays the ask.
    var onAddToLibraryRequested: ((URL) -> Void)?
    /// Invoked when a delete removed the open file and no captures remain —
    /// the controller swaps this window for the empty editor instead of
    /// leaving the user with no window at all. Set by EditorController.
    var onAllCapturesDeleted: (() -> Void)?
    var onEnhanceApply: (() -> Void)?      // runs enhance with current enhanceDraft params
    var onEnhanceCancel: (() -> Void)?     // cancels an in-flight enhance run
    /// Cancels an in-flight Smart Redaction scan. The task lives on
    /// `EditorController`, so the swap reaches it the same way it reaches the
    /// enhance run.
    var onRedactionScanCancel: (() -> Void)?
    /// Smart Redact pill tapped. Set by EditorController, which owns the scan.
    var onSmartRedact: (() -> Void)?
    /// Selecting a drawing tool cancels Smart Redact. Set by EditorController.
    var onSmartRedactCancel: (() -> Void)?
    private var enhancingOverlay: NSView?
    /// Non-magnified overlay that draws selection chrome (resize handles, rotate
    /// lollipop, emphasis box) at a constant on-screen size above the canvas scroll.
    private var chromeOverlay: SelectionChromeOverlay?
    /// NSHostingView pinned to fill shellContainer; present only while locked.
    private var lockOverlayHost: NSView?
    /// One-shot explanation shown on the lock screen — see `presentLockNotice`.
    /// Cleared on unlock so it can't resurface on a later, unrelated lock.
    private var lockNotice: String?
    /// Observer token for `.encryptionLockStateDidChange` notifications.
    private var lockStateObserver: NSObjectProtocol?
    /// Observer token for `.recordingDidFinish` — shows a confirmation toast.
    private var recordingFinishObserver: NSObjectProtocol?
    /// Token for the auto-rename request observer (metadata pipeline asks this
    /// window to rename the open capture once the AI title is known).
    private var autoRenameObserver: NSObjectProtocol?
    /// Tokens for the title-row spinner observers (AI filename generation).
    private var nameGenStartObserver: NSObjectProtocol?
    private var nameGenFinishObserver: NSObjectProtocol?
    /// Tokens for the Info-panel summary progress observers.
    private var summaryStartObserver: NSObjectProtocol?
    private var summaryFinishObserver: NSObjectProtocol?
    private var stageProgressObserver: NSObjectProtocol?
    private var videoMetaStartObserver: NSObjectProtocol?
    private var videoMetaProgressObserver: NSObjectProtocol?
    private var videoMetaFinishObserver: NSObjectProtocol?
    /// Re-arms tags/summary generation when Apple Intelligence availability
    /// actually changes (e.g. the user turned it on in System Settings and
    /// came back) — see `AIAvailabilityWatcher`.
    private var aiAvailabilityObserver: NSObjectProtocol?
    /// Sheet window used for the recovery-key entry flow; dismissed on success or cancel.
    private var recoverySheetWindow: NSWindow?
    /// Sheet window for the "I can't unlock…" guided-reset explainer;
    /// dismissed on completed reset or cancel.
    private var lockoutExplainerSheetWindow: NSWindow?
    /// Sheet window for the Locked Archive recovery-code restore flow;
    /// dismissed on Done or Cancel.
    private var archiveRestoreSheetWindow: NSWindow?
    /// Policy + persistence for the periodic recovery-code verification nudge.
    private let recoveryNudgeController = RecoveryVerifyNudgeController()
    /// Sheet window for the recovery-code verification nudge; dismissed on
    /// Verify success, Remind Me Later, or routing to Settings.
    private var recoveryNudgeSheetWindow: NSWindow?

    private weak var emptyCanvas: EmptyCanvasView?

    /// True when the user has made changes worth auto-saving before
    /// switching to a different recent capture. Driven by `state.isDirty`,
    /// which is set only by user-initiated edits (via `recordUndoCheckpoint`)
    /// — loading a file with baked-in annotations does NOT mark dirty.
    var hasUnsavedEdits: Bool {
        state?.isDirty ?? false
    }

    /// Commit any in-progress inline text edit so its text is folded into the
    /// annotation list before a save / file-switch / close. No-op when not
    /// editing.
    func commitPendingTextEdit() {
        canvas?.commitTextEditing()
    }

    /// True when there's no loaded EditorState. Used by EditorController
    /// to decide whether `present(result:)` should swap-in-place or do a
    /// full dismiss+remount.
    var isEmptyMode: Bool { state == nil }

    /// Test hook: the zoom % currently shown in the meta row.
    var debugMetaPercentText: String? { metaRow?.debugPercentText }

    /// Test hooks for the strip hide toggle (see EditorStripToggleSwapTests).
    var debugStripHidden: Bool { stripContainer?.isHidden ?? false }
    /// Which toolbar clusters are folded at the current width.
    var debugFoldedToolbarClusters: Set<EditorToolbarFit.ClusterID> { appliedToolbarFold }
    var debugMetaRow: EditorMetaRowView? { metaRow }
    /// Test hooks for the paste path (see CanvasPasteFitTests).
    var debugState: EditorState? { state }
    var debugCanvasView: EditorCanvasView? { canvas }
    func debugPaste() -> Bool { handlePaste() }
    var debugStripToggleTooltip: String? { metaRow?.debugStripToggleTooltip }
    func debugClickStripToggle() { metaRow?.debugClickStripToggle() }

    /// Test hook: true while at least one file-event undo/redo's async reopen
    /// tail (`deleteBatch`) may still be suppressing navigation recording —
    /// see `navigationSuppressionCount`.
    var debugSuppressNavigationRecording: Bool { navigationSuppressionCount > 0 }
    /// Test hook: the raw overlap counter, for tests that need to see the
    /// count itself (e.g. proving it reaches 2 with two Tasks in flight)
    /// rather than just its `> 0` projection.
    var debugNavigationSuppressionCount: Int { navigationSuppressionCount }
    /// Test hook: the bottom strip tab currently shown (Recent vs Deleted).
    var debugCurrentTab: BottomTab { currentTab }

    /// When the first state is a freshly captured/created image, fit it to the
    /// viewport on first load (ignore the remembered zoom).
    private let initialFitFresh: Bool

    init(
        state: EditorState?,
        saver: EditorSaveCoordinator,
        config: CaptureConfig,
        contentRect: NSRect,
        title: String,
        fitFresh: Bool = false,
        onRecentClick: @escaping (URL) -> Void
    ) {
        self.state = state
        self.saver = saver
        self.config = config
        self.initialFitFresh = fitFresh
        self.onRecentClickStored = onRecentClick

        if let state = state {
            let canvas = EditorCanvasView(state: state)
            canvas.alphaValue = 0   // revealed once the initial zoom has settled
            self.canvas = canvas
            self.canvasScroll = EditorCanvasScrollView(state: state, canvas: canvas)
        }

        // Placeholder; mountStrip(for:) at end of init replaces it with
        // a fresh strip wired to the controller's handlers.
        self.recentStrip = RecentStripView(
            mode: .recent,
            folder: config.saveFolder,
            daysBack: 7,
            onSelect: { _ in }
        )

        let window = EditorWindow(contentRect: contentRect, title: title)
        super.init(window: window)
        // Solely for `windowWillResize` — the tool bar has to fold before a
        // resize is applied, and no notification fires early enough. Nothing
        // else claimed the delegate.
        window.delegate = self
        if let canvas { wireCaptureMenu(on: canvas) }
        // Surface (not backdrop) so the titlebar/tab switcher + the toolbar +
        // file-title header read as one elevated "chrome" layer, separated from
        // the textured canvas by the header hairline below. The canvas keeps
        // its own backdrop via HexPatternBackdropView, so this only repaints the
        // header/titlebar band.
        window.backgroundColor = Theme.surfaceColor
        // Hide the native centered title so the tab switcher can sit above
        // the filename; the filename is re-rendered in installTitleRow.
        window.titleVisibility = .hidden

        // Persisted, user-resizable strip height (drag the handle below the
        // meta row). chrome = 18pt label + 12+12pt padding + 15pt scroller + 1pt slack.
        let stripHeight = StripHeightPreference.load()
        self.stripHeight = stripHeight
        let metaRowHeight: CGFloat = EditorMetaRowView.height

        // canvasHost holds the hex backdrop in BOTH modes; canvas-scroll vs
        // EmptyCanvasView is the only sub-view that differs.
        let canvasHost = NSView()
        canvasHost.translatesAutoresizingMaskIntoConstraints = false
        self.canvasHost = canvasHost
        // Floor the canvas pane's width/height. Without this, the empty editor
        // (no canvas image) has no intrinsic width, so an Auto Layout pass
        // collapses the whole window to the sidebar's ~219pt fitting size —
        // overriding even the window's contentMinSize. A required minimum on
        // the pane keeps the window a sensible size in every mode.
        // 320 rather than the canvas's comfortable size: this is a FLOOR, and
        // with the tool bar now folding at narrow widths it is what decides
        // how small the editor can get (floor + the 200pt sidebar minimum ≈
        // the window's own 560pt minimum).
        NSLayoutConstraint.activate([
            canvasHost.widthAnchor.constraint(greaterThanOrEqualToConstant: 320),
            canvasHost.heightAnchor.constraint(greaterThanOrEqualToConstant: 320),
        ])
        let backdrop = HexPatternBackdropView()
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        canvasHost.addSubview(backdrop)
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: canvasHost.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: canvasHost.trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: canvasHost.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: canvasHost.bottomAnchor),
        ])
        canvasHost.wantsLayer = true
        canvasHost.layer?.masksToBounds = false

        let leftColumn = NSStackView()
        leftColumn.orientation = .vertical
        leftColumn.distribution = .fill
        leftColumn.spacing = 0
        leftColumn.translatesAutoresizingMaskIntoConstraints = false
        let stripWrapper = NSStackView()
        stripWrapper.orientation = .vertical
        stripWrapper.distribution = .fill
        stripWrapper.translatesAutoresizingMaskIntoConstraints = false
        let stripHeightConstraint = stripWrapper.heightAnchor.constraint(equalToConstant: stripHeight)
        stripHeightConstraint.isActive = true
        self.stripHeightConstraint = stripHeightConstraint
        self.stripContainer = stripWrapper

        let metaRow: EditorMetaRowView
        if let state = state {
            // Loaded mode — existing canvas + scroll + full meta row.
            if let canvasScroll = canvasScroll, let canvas = canvas {
                canvasHost.addSubview(canvasScroll)
                NSLayoutConstraint.activate([
                    canvasScroll.leadingAnchor.constraint(equalTo: canvasHost.leadingAnchor),
                    canvasScroll.trailingAnchor.constraint(equalTo: canvasHost.trailingAnchor),
                    canvasScroll.topAnchor.constraint(equalTo: canvasHost.topAnchor),
                    canvasScroll.bottomAnchor.constraint(equalTo: canvasHost.bottomAnchor),
                ])
                styleCanvasScrollAsCard(canvasScroll)
                installChromeOverlay(state: state, canvas: canvas, scroll: canvasScroll, host: canvasHost)
            }

            metaRow = EditorMetaRowView(
                state: state,
                onFitWindow: { [weak self] in self?.routedFitWindow() },
                onZoom100: { [weak self] in self?.routedActualSize() },
                onFitWidth: { [weak self] in self?.routedFitWidth() },
                onFitHeight: { [weak self] in self?.routedFitHeight() },
                onFocus: { [weak self] in self?.routedFocus() },
                onSetZoom: { [weak self] z in self?.routedSetZoom(z) },
                onZoomIn: { [weak self] in self?.routedZoomIn() },
                onZoomOut: { [weak self] in self?.routedZoomOut() },
                onTabChange: { [weak self] tab in
                    self?.currentTab = tab
                    self?.mountStrip(for: tab)
                    self?.updateUndoRedoButtons()
                }
            )
            self.currentTab = state.bottomTab
        } else {
            // Empty mode — drop-capable placeholder.
            let empty = EmptyCanvasView()
            empty.translatesAutoresizingMaskIntoConstraints = false
            self.emptyCanvas = empty
            canvasHost.addSubview(empty)
            NSLayoutConstraint.activate([
                empty.leadingAnchor.constraint(equalTo: canvasHost.leadingAnchor),
                empty.trailingAnchor.constraint(equalTo: canvasHost.trailingAnchor),
                empty.topAnchor.constraint(equalTo: canvasHost.topAnchor),
                empty.bottomAnchor.constraint(equalTo: canvasHost.bottomAnchor),
            ])
            empty.onDrop = { [weak self] url in self?.onFileDropped?(url) }
            empty.onNewCanvas = { [weak self] in self?.onNewCanvasRequested?() }
            empty.onImport = { [weak self] in self?.onImportRequested?() }

            metaRow = EditorMetaRowView(
                initialTab: self.currentTab,
                onTabChange: { [weak self] tab in
                    self?.currentTab = tab
                    self?.mountStrip(for: tab)
                    self?.updateUndoRedoButtons()
                }
            )
        }
        metaRow.translatesAutoresizingMaskIntoConstraints = false
        metaRow.heightAnchor.constraint(equalToConstant: metaRowHeight).isActive = true
        // Same reasoning as the tool bar (see `installToolsBar`): the row must
        // not be able to set the window's minimum width, or the window jams at
        // the row's current content width and the row can then never see a
        // width narrow enough to fold at. It folds instead — presets to a menu
        // button, then the slider — via `EditorMetaRowView.layout`.
        metaRow.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        self.metaRow = metaRow
        metaRow.setMediaFilter(mediaFilter)
        metaRow.onSelectMediaFilter = { [weak self] filter in self?.applyMediaFilter(filter) }
        // The hide toggle is wired only in loaded mode — the empty editor has
        // no canvas to reclaim space for and always shows the strip.
        if state != nil {
            metaRow.onToggleStrip = { [weak self] in self?.toggleStripHidden() }
        }

        // The canvas column (split's middle pane) holds only the canvas. The
        // meta row + recent strip live in a full-width bottom dock *below* the
        // split, so the side panels (Info / Tool Properties) flank only the
        // canvas and never squeeze the strip.
        leftColumn.addArrangedSubview(canvasHost)

        let bottomDock = NSStackView()
        bottomDock.orientation = .vertical
        bottomDock.distribution = .fill
        bottomDock.spacing = 0
        bottomDock.translatesAutoresizingMaskIntoConstraints = false
        // A stack view defends its arranged subviews' fitting width through
        // its OWN compression resistance, so lowering it on the meta row alone
        // is not enough — the dock would re-impose the row's wide fitting size
        // as the window minimum.
        bottomDock.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let resizeHandle = makeStripResizeHandle()
        self.stripResizeHandle = resizeHandle
        bottomDock.addArrangedSubview(metaRow)
        bottomDock.addArrangedSubview(resizeHandle)
        bottomDock.addArrangedSubview(stripWrapper)
        self.bottomDock = bottomDock
        // Resize popover trigger + PRECISE zoom-cluster centring: the cluster
        // tracks the canvas column's centerX (follows Info-panel resizes).
        metaRow.onResizeButtonClicked = { [weak self] btn in
            self?.toggleResizePopover(anchor: btn)
        }
        metaRow.anchorZoomCluster(toCenterOf: canvasHost)

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        // The custom SidebarResizeHandle drives the sidebar width; the split
        // divider's own drag does nothing useful here (panes are autolayout
        // width-constrained) yet its hit area sits right on the boundary and
        // steals clicks meant for the handle — making the user click repeatedly.
        // Zeroing the divider's effective rect (see NSSplitViewDelegate below)
        // hands those boundary clicks to the handle.
        split.delegate = self
        split.translatesAutoresizingMaskIntoConstraints = false
        split.addArrangedSubview(leftColumn)

        if let state = state {
            // Canvas column (index 0, flexes) + right sidebar (index 1, holds
            // its fixed width). The file Info now lives inside the sidebar.
            let sidebar = EditorSidebarView(state: state)
            sidebar.translatesAutoresizingMaskIntoConstraints = false
            installSidebarWidth(sidebar, width: SidebarWidthPreference.load())
            sidebar.onCommitCrop = { [weak self] in self?.commitCrop() }
            sidebar.onCopyCrop = { [weak self] in _ = self?.state?.copyCropRegion() }
            sidebar.onCutCrop  = { [weak self] in _ = self?.state?.cutCropRegion() }
            sidebar.onSoftCrop = { [weak self] in _ = self?.state?.softCropRegion() }
            sidebar.onCopySelectedText = { [weak self] in self?.handleCopy() }
            sidebar.onCopyAllText = { [weak self] in self?.copyLiveText(all: true) }
            sidebar.onEnhanceApply = { [weak self] in self?.onEnhanceApply?() }
            sidebar.onEnhanceCancel = { [weak self] in self?.onEnhanceCancel?() }
            sidebar.onRenameRequested = { [weak self] name in self?.handleInfoPanelRename(to: name) }
            sidebar.onMoveImageTextSearchResult = { [weak self] delta in
                self?.canvas?.moveImageTextSearchResult(by: delta)
            }
            sidebar.onExitImageTextSearch = { [weak self] in self?.exitImageTextSearchToSelect() }
            split.addArrangedSubview(sidebar)
            split.setHoldingPriority(.defaultLow - 1, forSubviewAt: 0)     // canvas flexes
            split.setHoldingPriority(.defaultHigh, forSubviewAt: 1)        // sidebar holds width
            self.sidebar = sidebar
        }

        // `container` is the meta row's parent (used by rebuildMetaRow) — now
        // the bottom dock, not the canvas column.
        self.container = bottomDock

        // Use a persistent container as window.contentView so that swapping
        // shell tabs never reassigns contentView (which can fight the
        // title-bar accessory). The editor split and placeholder views are
        // children of this container; selectTab() toggles isHidden instead.
        // A drag destination, not a plain container: the Library sidebar's
        // collection and Favorites rows accept in-app capture drags, and the
        // destination has to sit on an ANCESTOR of those rows (see
        // LibraryDropIn). Registered only for the capture-list type, so every
        // other drag routes exactly as before.
        let shellContainer = ShellDropContainerView()
        self.shellContainer = shellContainer

        // License banner strip: full-width, pinned to the shell's top edge,
        // ABOVE every tab's content (editorColumn / libraryPlaceholder /
        // settingsPlaceholder all anchor their top to its bottom instead of
        // the shell's, below). Starts collapsed (height 0); `updateLicenseBanner`
        // drives visibility from `EntitlementStore.shared.state`.
        let bannerHost = NSView()
        bannerHost.translatesAutoresizingMaskIntoConstraints = false
        bannerHost.clipsToBounds = true   // belt-and-suspenders vs. content overflow
        bannerHost.isHidden = true        // starts collapsed; updateLicenseBanner unhides
        shellContainer.addSubview(bannerHost)
        self.licenseBannerHost = bannerHost
        let bannerHeight = bannerHost.heightAnchor.constraint(equalToConstant: 0)
        self.licenseBannerHeightConstraint = bannerHeight
        NSLayoutConstraint.activate([
            bannerHost.leadingAnchor.constraint(equalTo: shellContainer.leadingAnchor),
            bannerHost.trailingAnchor.constraint(equalTo: shellContainer.trailingAnchor),
            bannerHost.topAnchor.constraint(equalTo: shellContainer.topAnchor),
            bannerHeight,
        ])

        self.splitView = split

        // Editor content column: a header (tool bar + filename) stacked above
        // the split. Living in content (not a titlebar accessory) means the
        // rows can take real vertical padding. The whole column hides on
        // non-Editor tabs via editorContentView?.isHidden.
        let editorColumn = NSView()
        editorColumn.translatesAutoresizingMaskIntoConstraints = false

        let editorHeader = NSView()
        editorHeader.translatesAutoresizingMaskIntoConstraints = false

        // A width-observing host: the tool bar folds clusters away as the
        // window narrows, and the only reliable signal for "the bar has this
        // much room now" is the host's own layout pass.
        let toolsHost = ToolbarFitHostView()
        toolsHost.onWidthChange = { [weak self] width in
            self?.applyToolbarFit(availableWidth: width)
        }
        toolsHost.translatesAutoresizingMaskIntoConstraints = false
        let titleHost = NSView()
        titleHost.translatesAutoresizingMaskIntoConstraints = false
        self.toolsHost = toolsHost
        self.titleHost = titleHost

        editorHeader.addSubview(toolsHost)
        editorHeader.addSubview(titleHost)
        editorColumn.addSubview(editorHeader)
        editorColumn.addSubview(split)
        editorColumn.addSubview(bottomDock)
        // 1px hairline dividing the header surface from the canvas below
        // (option B). NSBox separator tracks the system separator color across
        // appearance changes on its own.
        let headerSeparator = NSBox()
        headerSeparator.boxType = .separator
        headerSeparator.translatesAutoresizingMaskIntoConstraints = false
        editorColumn.addSubview(headerSeparator)
        shellContainer.addSubview(editorColumn)

        // Padding constants driving the inter-row gaps.
        let headerTopPad: CGFloat = 4     // below the tabs/titlebar
        let toolsTitleGap: CGFloat = 4    // between tool bar and filename
        let headerBottomPad: CGFloat = 8  // below the filename, above the canvas

        NSLayoutConstraint.activate([
            editorColumn.leadingAnchor.constraint(equalTo: shellContainer.leadingAnchor),
            editorColumn.trailingAnchor.constraint(equalTo: shellContainer.trailingAnchor),
            editorColumn.topAnchor.constraint(equalTo: bannerHost.bottomAnchor),
            editorColumn.bottomAnchor.constraint(equalTo: shellContainer.bottomAnchor),

            editorHeader.topAnchor.constraint(equalTo: editorColumn.topAnchor),
            editorHeader.leadingAnchor.constraint(equalTo: editorColumn.leadingAnchor),
            editorHeader.trailingAnchor.constraint(equalTo: editorColumn.trailingAnchor),

            split.topAnchor.constraint(equalTo: editorHeader.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: editorColumn.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: editorColumn.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: bottomDock.topAnchor),

            // Full-width bottom dock (meta row + strip), unaffected by the side
            // panels in the split above it.
            bottomDock.leadingAnchor.constraint(equalTo: editorColumn.leadingAnchor),
            bottomDock.trailingAnchor.constraint(equalTo: editorColumn.trailingAnchor),
            bottomDock.bottomAnchor.constraint(equalTo: editorColumn.bottomAnchor),

            toolsHost.topAnchor.constraint(equalTo: editorHeader.topAnchor, constant: headerTopPad),
            toolsHost.leadingAnchor.constraint(equalTo: editorHeader.leadingAnchor),
            toolsHost.trailingAnchor.constraint(equalTo: editorHeader.trailingAnchor),

            titleHost.topAnchor.constraint(equalTo: toolsHost.bottomAnchor, constant: toolsTitleGap),
            titleHost.leadingAnchor.constraint(equalTo: editorHeader.leadingAnchor),
            titleHost.trailingAnchor.constraint(equalTo: editorHeader.trailingAnchor),
            titleHost.bottomAnchor.constraint(equalTo: editorHeader.bottomAnchor, constant: -headerBottomPad),

            // Hairline sits exactly on the header/canvas boundary, full width.
            headerSeparator.topAnchor.constraint(equalTo: editorHeader.bottomAnchor),
            headerSeparator.leadingAnchor.constraint(equalTo: editorColumn.leadingAnchor),
            headerSeparator.trailingAnchor.constraint(equalTo: editorColumn.trailingAnchor),
            headerSeparator.heightAnchor.constraint(equalToConstant: 1),
        ])
        self.editorContentView = editorColumn

        window.contentView = shellContainer
        window.initialFirstResponder = (state == nil) ? nil : canvas

        installTabSwitcher(on: window)

        window.onExport = { [weak self] in self?.exportCurrent() }
        window.onSelectAll = { [weak self] in
            guard let self else { return }
            switch self.currentTabSelection {
            case .library:
                // ⌘A selects every item visible after the active filter.
                self.libraryViewModel?.selectAll()
            case .editor:
                // ⌘A always targets the CANVAS, even when the strip has focus:
                // all recognized text under the Live Text tool, else all
                // annotation objects. (The strip no longer gets ⌘A by request.)
                if self.state?.selectedTool == .textSelect,
                   self.state?.showsImageTextSearchPanel != true {
                    self.canvas?.selectAllText()
                } else {
                    self.state?.selectAll()
                }
            case .settings:
                break
            }
        }
        window.onCopy = { [weak self] in self?.handleCopy() }
        window.onCut = { [weak self] in self?.handleCut() ?? false }
        window.onSoftCrop = { [weak self] in self?.state?.softCropRegion() ?? false }
        window.onPaste = { [weak self] in self?.handlePaste() ?? false }
        window.onReorder = { [weak self] op in
            guard let self, let state = self.state, let canvas = self.canvas,
                  self.window?.isKeyWindow == true, self.window?.firstResponder === canvas,
                  !state.selectedAnnotationIDs.isEmpty else { return false }
            state.reorderSelected(op)
            return true
        }
        window.onUndo = { [weak self] in self?.handleUndo() }
        window.onRedo = { [weak self] in self?.handleRedo() }
        window.onZoomIn = { [weak self] in self?.routedZoomIn() }
        window.onZoomOut = { [weak self] in self?.routedZoomOut() }
        window.onZoomReset = { [weak self] in self?.routedFitWindow() }
        window.onExportPNG = { [weak self] in self?.exportCurrent() }
        window.onDeleteCurrent = { [weak self] in self?.handleDeleteShortcut() }
        // Edit→Delete removes the selected annotation objects (canvas), unlike
        // ⌘⌫ / onDeleteCurrent which deletes the whole capture file.
        window.onDeleteSelection = { [weak self] in self?.state?.deleteSelected() }
        // ⌘D duplicates the selected objects. Canvas-only, like the other
        // object shortcuts, so it can't fire while a text field has focus —
        // and the window must be KEY, or a background editor behind a sheet
        // or panel would still see its (stale) first responder as the canvas.
        window.onDuplicateSelection = { [weak self] in
            guard let self, let state = self.state, let canvas = self.canvas,
                  self.window?.isKeyWindow == true, self.window?.firstResponder === canvas,
                  !state.isReadOnly, !state.selectedAnnotationIDs.isEmpty else { return false }
            state.duplicateSelected()
            canvas.needsDisplay = true
            return true
        }
        // Edit-menu availability predicates — keep the menu items in step with
        // the editor toolbar / actual state, so e.g. Redo greys out when there
        // is nothing to redo (matching the toolbar's Redo button).
        window.canUndo = { [weak self] in self?.globalUndo.canUndo ?? false }
        window.canRedo = { [weak self] in self?.globalUndo.canRedo ?? false }
        window.canCopy = { [weak self] in
            guard let self, let state = self.state else { return false }
            // Live Text tool copies the text selection; otherwise objects or
            // the whole image are always copyable once a capture is loaded.
            if state.selectedTool == .textSelect, !state.showsImageTextSearchPanel {
                return !(self.canvas?.selectedTextForCopy ?? "").isEmpty
            }
            return true
        }
        window.canCut = { [weak self] in
            guard let state = self?.state, !state.isReadOnly else { return false }
            return !state.selectedAnnotationIDs.isEmpty
        }
        window.canPaste = { [weak self] in
            guard let state = self?.state, !state.isReadOnly else { return false }
            return AnnotationPasteboard.read() != nil || NewCanvasFactory.clipboardHasImage()
        }
        window.canSelectAll = { [weak self] in
            guard let self else { return false }
            switch self.currentTabSelection {
            case .library:
                guard let vm = self.libraryViewModel, !vm.isAlbumBrowser else { return false }
                return !vm.items.isEmpty
            case .editor:
                if self.editorStripFocused, let strip = self.focusedStrip {
                    return !strip.orderedURLs.isEmpty
                }
                guard let state = self.state else { return false }
                if state.selectedTool == .textSelect,
                   !state.showsImageTextSearchPanel { return true }
                return !state.annotations.isEmpty
            case .settings:
                return false
            }
        }
        window.canDeleteSelection = { [weak self] in
            guard let state = self?.state, !state.isReadOnly else { return false }
            return !state.selectedAnnotationIDs.isEmpty
        }
        window.onClearSelection = { [weak self] in
            guard let self else { return false }
            // Esc closes the in-canvas video first (it has no close button).
            if self.videoOverlay != nil { self.dismissCanvasVideo(); return true }
            guard self.recentStrip.hasSelection else { return false }
            self.recentStrip.clearSelection()
            return true
        }
        window.routeKeyWhileEditingText = { [weak self] event in
            self?.canvas?.handleKeyWhileEditingText(event) ?? false
        }
        window.onArrowKey = { [weak self] keyCode in self?.handleArrowKey(keyCode) ?? false }
        window.onCommandArrowKey = { [weak self] keyCode in self?.handleCommandArrowKey(keyCode) ?? false }
        window.onActivateSelection = { [weak self] in self?.handleActivateSelection() ?? false }
        window.onSpaceKey = { [weak self] in self?.handleSpaceKey() ?? false }
        window.onEscapePreview = { [weak self] in self?.handleEscapePreview() ?? false }
        window.isQuickLookOpen = { [weak self] in
            self?.currentTabSelection == .library && self?.libraryViewModel?.quickLookOpen == true
        }
        window.onToggleStrip = { [weak self] in self?.toggleStripHidden() }
        window.onFindInImage = { [weak self] in self?.showImageTextSearch() ?? false }

        installToolsBar(empty: state == nil)
        installTitleRow(on: window)
        setRepresentedCapture(state?.sourceURL, on: window)
        updateTitleRow()

        mountStrip(for: currentTab)
        updateDeletedTabAvailability()

        if state != nil {
            // Open in the user's last-chosen strip visibility.
            applyStripHidden(StripVisibilityPreference.isHidden(), persist: false)
            scheduleFitToWindow(fitFresh: initialFitFresh)
            observeUndoRedo()
            observeSelectedTool()
            observeInfoPanel()
            observeObjectSelection()
            observeEnhanceButton()
            observeRedactionScan()
            observeStripPreview()
            observeAutosave()
        } else {
            // Empty-mode editor: no `observeObjectSelection()` will run, so sync
            // the Edit▸object menu state directly — otherwise it could still
            // show whatever the previously-open document last published.
            syncObjectMenuState()
        }

        // Refresh the strips when metadata is generated for a capture so the
        // display-name label reflects the generated title without a manual
        // refresh. (In-place diff; unchanged files cost one stat each.)
        importObserver = NotificationCenter.default.addObserver(
            forName: .captureFilesImported, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let urls = note.object as? [URL], !urls.isEmpty else { return }
                // One event per gesture; trashedURL is a placeholder until an
                // undo actually moves the files (deleteBatch reads originalURL
                // and returns fresh trashed locations).
                let items = urls.map {
                    DeletionUndoHistory.Item(trashedURL: $0, originalURL: $0)
                }
                let kind: DeletionUndoHistory.Kind =
                    (note.userInfo?["kind"] as? String) == "capture" ? .capture : .importation
                self.globalUndo.record(.fileEvent(.init(
                    items: items, kind: kind, containedOpenFile: false, at: Date())))
                self.updateUndoRedoButtons()
            }
        }
        metadataChangeObserver = NotificationCenter.default.addObserver(
            forName: .captureMetadataDidChange, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshRecentStrip()
                self.updateTitleRow()
                // The open image's metadata changed — re-seed progress flags and
                // trigger summary/tags backfill for the CURRENT url. This also
                // covers the post-capture auto-rename: the eager summary ran
                // against the now-moved provisional path, so the renamed url's
                // metadata-change is where we can finally backfill its summary.
                if self.isOpenExtractionURL(note) {
                    self.syncExtractionState()
                }
                // Also rebuild the Info panel when the changed capture is the open
                // one, so a newly-stored summary (image or video) swaps in live —
                // e.g. the video Summarizing bar becomes the bulleted summary.
                if let url = note.object as? URL, url == self.currentItemURL {
                    self.state?.sidebarRefreshToken &+= 1
                }
            }
        }

        // A Library "Delete Forever" removed files from disk, and a Library
        // "Delete" moved them into Deleted/ — either way the file left the
        // save folder. If one of them is open in the canvas (image or playing
        // video), drop it; always refresh both strips.
        permanentDeleteObserver = NotificationCenter.default.addObserver(
            forName: .capturesPermanentlyDeleted, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let urls = note.object as? [URL] else { return }
                self.handleExternalPurge(urls)
            }
        }
        libraryTrashObserver = NotificationCenter.default.addObserver(
            forName: .capturesTrashed, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let urls = note.object as? [URL] else { return }
                self.handleExternalPurge(urls)
            }
        }
        // The library moved: re-point both strips (and the Deleted subfolder
        // inside it) so they list the new location instead of the old one.
        saveFolderObserver = NotificationCenter.default.addObserver(
            forName: .saveFolderDidChange, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let folder = note.object as? URL else { return }
                self.handleSaveFolderChange(to: folder)
            }
        }

        // The metadata pipeline asks the window owning the capture to perform the
        // AI-title rename itself (so the open file's autosave/undo/index stay in
        // sync). Only this window acts, and only if it represents that URL.
        autoRenameObserver = NotificationCenter.default.addObserver(
            forName: .captureAutoRenameRequested, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self,
                      let oldURL = note.object as? URL,
                      let base = note.userInfo?["base"] as? String,
                      self.window?.representedURL?.standardizedFileURL == oldURL.standardizedFileURL
                else { return }
                self.autoRenameRepresentedCapture(toBase: base)
            }
        }

        // Title-row spinner follows AI filename generation for this capture.
        // The registry is the source of truth (set during the post-capture swap,
        // which runs after the start notification), so just refresh on each event.
        nameGenStartObserver = NotificationCenter.default.addObserver(
            forName: .captureNameGenerationStarted, object: nil, queue: .main
        ) { [weak self] note in MainActor.assumeIsolated {
            guard let self else { return }
            self.updateTitleRow()
            // Tags pipeline started for the open image (and tags aren't written
            // yet) — show the Tags progress bar.
            if self.isOpenExtractionURL(note), self.openImageTagsMissing() {
                self.state?.isGeneratingTags = true
                self.armExtractionTimeout()
            }
        } }
        nameGenFinishObserver = NotificationCenter.default.addObserver(
            forName: .captureNameGenerationFinished, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.updateTitleRow() } }

        summaryStartObserver = NotificationCenter.default.addObserver(
            forName: .captureSummaryGenerationStarted, object: nil, queue: .main
        ) { [weak self] note in MainActor.assumeIsolated {
            guard let self, self.isOpenExtractionURL(note) else { return }
            self.state?.isGeneratingSummary = true
            self.state?.sidebarRefreshToken += 1
            self.armExtractionTimeout()
        } }
        summaryFinishObserver = NotificationCenter.default.addObserver(
            forName: .captureSummaryGenerationFinished, object: nil, queue: .main
        ) { [weak self] note in MainActor.assumeIsolated {
            guard let self, self.isOpenExtractionURL(note) else { return }
            self.state?.isGeneratingSummary = false
            self.state?.sidebarRefreshToken += 1
        } }

        // Observe lock-state changes so the lock overlay tracks the session.
        lockStateObserver = NotificationCenter.default.addObserver(
            forName: .encryptionLockStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshLockOverlay()
                // On unlock, manifests become readable: let the index re-resolve
                // any .seal capture dates it couldn't read while locked, then
                // refresh so the strip/Library settle into correct order in one
                // sweep (rather than one capture at a time as files are edited).
                if !EncryptionSession.shared.isEnabled || EncryptionSession.shared.isUnlocked {
                    Task { @MainActor in
                        await LibraryIndexStore.shared.sessionDidUnlock()
                        self.refreshRecentStrip()
                        self.libraryViewModel?.reload()
                    }
                }
                // Offer the periodic recovery-code check-in right after an
                // actual unlock (never while locked or when encryption is
                // off — see the guards inside).
                if EncryptionSession.shared.isEnabled && EncryptionSession.shared.isUnlocked {
                    self.maybePresentRecoveryVerifyNudge()
                }
            }
        }
        // Show the lock overlay immediately if the session is already locked at launch.
        refreshLockOverlay()

        // A finished recording is a global event; show an in-app toast when this
        // window is frontmost (the coordinator also reveals the file in Finder).
        recordingFinishObserver = NotificationCenter.default.addObserver(
            forName: .recordingDidFinish, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Eagerly generate the recording's tags + summary now (like image
                // capture tags at save), serial via the coordinator. Scratch
                // recordings are skipped: the AI passes are library work, and
                // spending minutes of frame OCR on a file that may be swept
                // away in 7 days is the wrong trade. Keeping it re-announces
                // the file, and the pass runs then.
                if let url = note.object as? URL, !ScratchCapture.isScratch(url) {
                    VideoMetadataCoordinator.shared.ensure(for: url)
                }
                // Refresh the Library (videos now live there) if it's been built.
                self.libraryViewModel?.reload()
                guard self.window?.isKeyWindow == true,
                      let host = self.canvasHost ?? self.window?.contentView else { return }
                EditorToastView.show("Recording saved", in: host)
            }
        }

        // Image tag/summary stepped milestones → determinate Info-panel bars for
        // the open image.
        stageProgressObserver = NotificationCenter.default.addObserver(
            forName: .captureStageProgress, object: nil, queue: .main
        ) { [weak self] note in MainActor.assumeIsolated {
            guard let self, self.isOpenExtractionURL(note),
                  let stage = note.userInfo?[MetadataCoordinator.stageKey] as? String,
                  let frac = note.userInfo?[MetadataCoordinator.fractionKey] as? Double else { return }
            if stage == "tags" { self.state?.imageTagsProgress = frac }
            else if stage == "summary" { self.state?.imageSummaryProgress = frac }
        } }

        // Video metadata generation progress → drive the open recording's Info
        // panel bars (mirrors the image isGeneratingTags/Summary pattern).
        videoMetaStartObserver = NotificationCenter.default.addObserver(
            forName: VideoMetadataCoordinator.started, object: nil, queue: .main
        ) { [weak self] note in MainActor.assumeIsolated {
            guard let self, self.isOpenRecording(note) else { return }
            self.state?.isGeneratingVideoTags = true
            self.state?.videoSummaryProgress = 0
            self.state?.sidebarRefreshToken += 1
        } }
        videoMetaProgressObserver = NotificationCenter.default.addObserver(
            forName: VideoMetadataCoordinator.progress, object: nil, queue: .main
        ) { [weak self] note in MainActor.assumeIsolated {
            guard let self, self.isOpenRecording(note),
                  let frac = note.userInfo?[VideoMetadataCoordinator.progressFractionKey] as? Double
            else { return }
            self.state?.videoSummaryProgress = frac
        } }
        videoMetaFinishObserver = NotificationCenter.default.addObserver(
            forName: VideoMetadataCoordinator.finished, object: nil, queue: .main
        ) { [weak self] note in MainActor.assumeIsolated {
            guard let self, self.isOpenRecording(note) else { return }
            self.state?.isGeneratingVideoTags = false
            self.state?.videoSummaryProgress = nil
            self.state?.sidebarRefreshToken += 1
        } }

        // Seed Info-panel tags/summary progress + summary backfill for the image
        // this window opened with. `swap()` handles later image switches; this
        // covers the initial open (first capture / opening an existing image).
        syncExtractionState()

        // Apple Intelligence availability is polled at the three moments
        // above (metadata change, initial open, image swap) but never
        // observed — turning it on in System Settings with a capture already
        // open otherwise leaves generation un-armed until some unrelated
        // event happens to re-run one of those three. Re-sync whenever the
        // watcher confirms the status actually changed; it already
        // re-derives both flags through the existing gates, so no new
        // generation logic is needed here.
        AIAvailabilityWatcher.shared.start()
        aiAvailabilityObserver = NotificationCenter.default.addObserver(
            forName: .aiAvailabilityDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.syncExtractionState()
            }
        }

        // Armed ONCE for the controller's lifetime (config outlives every
        // state swap): live save-location changes from Settings.
        observeSaveFolder()

        // License banner: reacts live to EntitlementStore.state (activation,
        // removal, blocklist) — no relaunch needed to clear it.
        updateLicenseBanner()
        entitlementCancellable = EntitlementStore.shared.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateLicenseBanner() }
        // Opportunistic refresh so an overnight day-rollover or expiry takes
        // effect without relaunch: at most once per 6h, when this window
        // becomes key. (No NSWindowDelegate on this controller — matches the
        // rest of the file's notification-based observers, e.g. the export
        // selection sync in RecentStripView.)
        licenseBannerWindowKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, Date().timeIntervalSince(self.lastEntitlementRefresh) >= 6 * 3600 else { return }
                self.lastEntitlementRefresh = Date()
                EntitlementStore.shared.refresh()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not implemented") }

    // MARK: - License banner

    /// Re-evaluate `LicenseBannerPolicy` against the current entitlement state
    /// + this session's dismissal, and reflect the result: collapse/expand
    /// `bannerHost`'s height and (re)mount `LicenseBannerView` with the right
    /// kind. Called on init, on every `EntitlementStore.state` change, and
    /// after a dismiss.
    private func updateLicenseBanner() {
        guard let bannerHost = licenseBannerHost else { return }
        let kind = LicenseBannerPolicy.banner(for: EntitlementStore.shared.state,
                                            dismissed: licenseBannerDismissed)
        guard let kind else {
            licenseBannerHeightConstraint?.constant = 0
            // NSView stopped clipping subviews by default (macOS 14) — a
            // collapsed host still DRAWS its mounted SwiftUI content over the
            // toolbar unless hidden.
            bannerHost.isHidden = true
            return
        }
        if let content = licenseBannerContentHost {
            content.rootView = makeLicenseBannerView(kind: kind)
        } else {
            let host = NSHostingView(rootView: makeLicenseBannerView(kind: kind))
            host.translatesAutoresizingMaskIntoConstraints = false
            // Same macOS 26 reentrant-layout guard as the Library/Settings
            // hosts (selectTab) — the strip's height is driven externally by
            // `licenseBannerHeightConstraint`, never by the hosted content.
            host.sizingOptions = []
            bannerHost.addSubview(host)
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: bannerHost.leadingAnchor),
                host.trailingAnchor.constraint(equalTo: bannerHost.trailingAnchor),
                host.topAnchor.constraint(equalTo: bannerHost.topAnchor),
                host.bottomAnchor.constraint(equalTo: bannerHost.bottomAnchor),
            ])
            licenseBannerContentHost = host
        }
        bannerHost.isHidden = false
        licenseBannerHeightConstraint?.constant = licenseBannerHeight
    }

    private func makeLicenseBannerView(kind: LicenseBannerKind) -> LicenseBannerView {
        LicenseBannerView(
            kind: kind,
            onOpenSettings: { [weak self] in
                EntitlementStore.shared.presentLicenseSettings()
                self?.selectTab(.settings)
            },
            onDismiss: { [weak self] in
                guard let self else { return }
                self.licenseBannerDismissed = kind
                self.updateLicenseBanner()
            })
    }

    // MARK: - Info-panel extraction progress

    /// True when `note.object` is the `.seal` URL currently open in this editor.
    private func isOpenExtractionURL(_ note: Notification) -> Bool {
        guard let url = note.object as? URL, let open = state?.sourceURL else { return false }
        return url.standardizedFileURL == open.standardizedFileURL
    }

    /// Whether a video-metadata notification's URL is the recording currently
    /// playing in the canvas (so only its Info panel reacts to progress).
    private func isOpenRecording(_ note: Notification) -> Bool {
        guard let url = note.object as? URL, let open = playingVideoURL else { return false }
        return url.standardizedFileURL == open.standardizedFileURL
    }

    /// Whether the open image has no tags yet (treat unreadable as missing).
    private func openImageTagsMissing() -> Bool {
        guard let url = state?.sourceURL,
              let manifest = try? SealMetadataStore.readManifest(at: url) else { return true }
        return manifest.metadata?.smartKeywords.isEmpty ?? true
    }

    /// Seed the Info-panel progress flags for the open image and kick off summary
    /// backfill if it's missing. Called when an image is swapped in.
    private func syncExtractionState() {
        guard let url = state?.sourceURL, url.pathExtension.lowercased() == "seal" else {
            state?.isGeneratingTags = false
            state?.isGeneratingSummary = false
            return
        }
        let manifest = try? SealMetadataStore.readManifest(at: url)
        // The capture pipeline (fresh captures) generates tags + summary
        // concurrently; the registry says it's in flight for this url.
        let pipelineInFlight = NameGenerationRegistry.shared.contains(url)
        let summaryEligible = AIAvailability.isFoundationModelAvailable && AIFeaturePreference().enabled

        // Tags: backfill on open when missing (idempotent; needs a generator,
        // i.e. AI enabled); show progress while in flight. Pure images are
        // TERMINAL (OCR ran, no text → no keywords possible): without the
        // shared gate, every metadata-change notification re-armed the
        // backfill and the keywords bar looped forever. Live Capture scenes
        // are exempt below (`isScene:`) so a scene can heal past a stale
        // wallpaper-OCR marker; `generateTags` only reports a write when the
        // marker actually changes, so a text-free scene still goes terminal
        // after one pass. An UNREADABLE manifest (nil) is NOT "missing" —
        // generation can't read it either, and arming it anyway livelocked
        // the main thread (capture while locked → unlock: notify → sync →
        // ensure → skip → notify …).
        let tagsMissing = manifest.map {
            MetadataCoordinator.needsTagBackfill(
                smartKeywordsEmpty: $0.metadata?.smartKeywords.isEmpty ?? true,
                ocrText: $0.ocrText,
                isScene: $0.captureKind == .liveCapture)
        } ?? false
        if tagsMissing, AIFeaturePreference().enabled, !pipelineInFlight,
           !AppDelegate.isRunningUnitTests {
            MetadataCoordinator.shared.ensureTags(for: url)
        }
        state?.isGeneratingTags = tagsMissing && NameGenerationRegistry.shared.contains(url)

        // Summary: a fresh capture's pipeline produces it in parallel with tags →
        // show its bar alongside tags. An existing image backfills on open (when
        // it has OCR text to summarize); a legacy image with no OCR shows
        // nothing. A manual override OR a deliberate suppression (v13) counts
        // as present, so a cleared summary shows no generating bar.
        let userSummaryPresent = manifest?.metadata?.hasUserSummaryOverride ?? false
        // Same unreadable-manifest rule as tags: nil manifest → not actionable.
        let summaryMissing = manifest != nil
            && manifest?.metadata?.summary == nil && !userSummaryPresent
        if summaryMissing, summaryEligible {
            if pipelineInFlight {
                state?.isGeneratingSummary = true
            } else if MetadataCoordinator.shared.isSummaryInFlight(for: url)
                        || SummaryGating.shouldGenerate(
                            aiEnabled: summaryEligible, foundationModelAvailable: true,
                            summaryPresent: false, ocrText: manifest?.ocrText) {
                state?.isGeneratingSummary = true
                if !AppDelegate.isRunningUnitTests {
                    MetadataCoordinator.shared.ensureSummary(for: url)
                }
            } else {
                state?.isGeneratingSummary = false
            }
        } else {
            state?.isGeneratingSummary = false
        }
        // Seed/clear the determinate-bar fractions to match the flags: seed a
        // small starting value so the bar isn't empty before the first milestone,
        // and clear when generation is done.
        if state?.isGeneratingTags == true {
            if state?.imageTagsProgress == nil { state?.imageTagsProgress = 0.1 }
        } else {
            state?.imageTagsProgress = nil
        }
        if state?.isGeneratingSummary == true {
            if state?.imageSummaryProgress == nil { state?.imageSummaryProgress = 0.1 }
        } else {
            state?.imageSummaryProgress = nil
        }
        if state?.isGeneratingTags == true || state?.isGeneratingSummary == true {
            armExtractionTimeout()
        }
    }

    /// Safety net: clear a stuck progress flag if its finish notification never
    /// arrives (e.g. a generation path that exits without posting).
    private func armExtractionTimeout() {
        // Key to the image that armed it, so switching images doesn't let a
        // stale timer clear the new image's legitimately-in-progress bar.
        let armedURL = state?.sourceURL
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.state?.sourceURL == armedURL else { return }
                if self.state?.isGeneratingTags == true {
                    self.state?.isGeneratingTags = false
                    self.state?.sidebarRefreshToken += 1
                }
                if self.state?.isGeneratingSummary == true {
                    self.state?.isGeneratingSummary = false
                    self.state?.sidebarRefreshToken += 1
                }
            }
        }
    }

    deinit {
        // Safe: NSWindowController is always deallocated on the main thread.
        canvasVideoPlayer?.pause()
        if let obs = metadataChangeObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        if let obs = permanentDeleteObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        if let obs = libraryTrashObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        if let obs = saveFolderObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        if let obs = lockStateObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        if let obs = recordingFinishObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        if let obs = autoRenameObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        if let obs = nameGenStartObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        if let obs = nameGenFinishObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        if let obs = summaryStartObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        if let obs = summaryFinishObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        for obs in [stageProgressObserver, videoMetaStartObserver,
                    videoMetaProgressObserver, videoMetaFinishObserver] {
            if let obs { NotificationCenter.default.removeObserver(obs) }
        }
        if let obs = licenseBannerWindowKeyObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        if let obs = aiAvailabilityObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    /// Auto-fit the canvas image to the viewport on the next runloop tick.
    /// The contentView's bounds are only valid after the window has been
    /// shown and laid out, so this can't run synchronously from init or swap.
    private func scheduleFitToWindow(fitFresh: Bool = false) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.canvasScroll?.applyInitialZoom(fitFresh: fitFresh)
            self.canvasScroll?.layoutSubtreeIfNeeded()
            self.revealCanvas()   // safety net if the synchronous settle couldn't
        }
    }

    /// Reveal the canvas once its initial zoom/layout has settled, so the image
    /// never paints at the wrong scale for a frame when switching/loading.
    private func revealCanvas() {
        canvas?.alphaValue = 1
    }

    /// Fit the canvas synchronously during an on-screen swap. The window is
    /// already visible, so forcing the freshly-installed scroll to lay out
    /// makes its clip-view bounds valid immediately, letting us fit (zoom +
    /// scroll position) within the same runloop tick — before the first paint.
    /// This removes the one-frame flash the async scheduleFitToWindow() leaves,
    /// most visibly on focus-cropped images (the synchronous pre-fit zoom only
    /// sizes whole-image fits; focus needs fit(imageRect:) to also scroll).
    /// scheduleFitToWindow() still runs afterward as a no-op safety net in case
    /// layout couldn't settle here (e.g. a not-yet-shown window).
    private func fitCanvasSynchronously(fitFresh: Bool = false) {
        guard let scroll = canvasScroll else { return }
        scroll.layoutSubtreeIfNeeded()
        scroll.applyInitialZoom(fitFresh: fitFresh)   // sets zoom + canvas frame synchronously
        scroll.layoutSubtreeIfNeeded()   // settle centering at the new frame
        revealCanvas()                   // now safe to show — no wrong-scale frame
    }

    func swap(toState newState: EditorState, title: String, fitFresh: Bool = false) {
        UndoDiag.note("swap \(UndoDiag.name(state?.sourceURL)) "
            + "(dirty:\(state?.isDirty ?? false)) → \(UndoDiag.name(newState.sourceURL)) "
            + "(global u:\(globalUndo.undoStack.count) r:\(globalUndo.redoStack.count))")
        // A pending autosave targets the OLD state — cancel it before the
        // swap so it can't fire against the wrong (now-replaced) state.
        autosaveWorkItem?.cancel()
        // A pending strip-preview render is likewise stale; observeStripPreview
        // re-renders for the new state right after the swap.
        stripPreviewWorkItem?.cancel()
        // An in-flight enhance belongs to the OLD state: its result is thrown
        // away by the identity guard in the completion handler, so letting it
        // run only burns CPU — and `isEnhancing` stays true until it finishes,
        // which makes Enhance Clarity on the newly-opened capture silently do
        // nothing. Cancel it, then clear the "Enhancing…" overlay so it doesn't
        // linger over the new file.
        //
        // Unconditional: `endLiveTextEnhanceSession` below also fires this hook,
        // but only for a LIVE TEXT enhance session — a run the user started
        // themselves has no session and used to slip through. Cancelling a nil
        // task is a no-op, so the overlap is harmless.
        onEnhanceCancel?()
        hideEnhancingOverlay()
        // Same reasoning for the other long canvas work. These used to cancel
        // at each navigation SITE (presentFile, presentRecording), which missed
        // `present(_:)` — the path a brand-new capture takes — so capturing
        // mid-scan left the work running against the capture just navigated
        // away from. Cancelling here covers every path that swaps state.
        onRedactionScanCancel?()
        cancelCanvasProgressAction()   // Extract Data, video summarize
        // Opening a file (e.g. clicking an image in the strip) exits video playback.
        dismissCanvasVideo()

        // Fresh content (a new capture or a scratch canvas) becomes the sole
        // highlighted item: clear any lingering strip multi-selection so the
        // previously clicked/selected thumbnail doesn't stay tinted alongside
        // the new capture's open ring. Plain navigation (fitFresh == false)
        // leaves the click-selection intact.
        if fitFresh { recentStrip.clearSelection() }

        // Detect upgrade from empty mode BEFORE updating self.state.
        let wasEmpty = (self.state == nil)

        // Navigating to a DIFFERENT capture commits any pending "Revert to
        // Original" undo: RevertHistory is per-capture + session-scoped, but the
        // controller is reused across captures. Revert/undo/redo swaps keep the
        // same sourceURL, so this guard naturally excludes them.
        if newState.sourceURL != self.state?.sourceURL {
            revertHistory.clear()
        }

        // Preserve the user's current bottom tab across the swap.
        // newState is freshly constructed in EditorController.presentFile
        // with bottomTab defaulting to .recent — blindly replacing self.state
        // would silently flip the user out of the Deleted tab whenever they
        // click a thumbnail (the segmented control stays unchanged, so the
        // strip and the segment label would disagree on the next mountStrip).
        let preservedTab = state?.bottomTab ?? currentTab
        // AI tools (Live Text, Smart Redact, Extract, Enhance Clarity, Remove
        // Background) are per-image and often expensive to run — carrying one to
        // the next image would auto-trigger it on every image the user browses
        // to. So when the outgoing image has an AI tool/mode active, DON'T carry
        // it: reset the new image to the neutral Select tool and the Info panel
        // instead (the drawing tools still carry — see below).
        let outgoingAIActive = state.map(Self.isAIToolActive) ?? false
        // Keep the active tool across the swap (a brand-new/empty editor has
        // none yet → neutral .select), so switching images mid-annotation
        // doesn't kick the user back to the neutral tool. AI tools are the
        // exception (reset to .select).
        let carriedTool: EditorTool = outgoingAIActive ? .select : (state?.selectedTool ?? .select)
        // Keep the Info/Properties mode across the swap too, so 'i' stays
        // selected while the user switches between images. A brand-new editor
        // (no prior state) opens in Info by default. After an AI tool, land on Info.
        let carriedInfoMode: SidebarPanelMode = outgoingAIActive ? .info : (state?.sidebarPanelMode ?? .info)
        // Keep the Enhance Clarity panel open across the swap too — switching
        // images should stay on the tool even if the new image isn't enhanced.
        // (But not when we're resetting AI tools — Enhance is one of them.)
        let carriedEnhance = outgoingAIActive ? false : (state?.enhanceEditing ?? false)
        // Carry the per-tool creation settings (widths/colors/blur/etc.) so
        // switching images keeps the user's chosen styling.
        let previousState = state
        // End any Live Text enhance session on the outgoing state (restores
        // its logical enhanced visibility, cancels an in-flight generation)
        // and reset the transition tracker so a carried-over Live Text tool
        // begins a fresh session on the NEW state via observeSelectedTool.
        if let previousState { endLiveTextEnhanceSession(on: previousState) }
        liveTextEnhanceLastTool = .select
        self.state = newState
        self.state?.bottomTab = preservedTab
        self.currentTab = preservedTab
        // Remember a real, non-trashed capture so the next launch reopens it
        // (scratch canvases and deleted files keep the previous memory).
        if let url = newState.sourceURL, !newState.isReadOnly {
            LastSelectedCapturePreference.store(url)
        }
        // Seed Info-panel tags/summary progress for the newly opened image.
        syncExtractionState()

        // Pre-fit the zoom synchronously so the new canvas renders at the
        // correct scale on its very first frame. EditorState.zoom defaults to
        // 1.0 (100%), so without this the canvas would briefly show at native
        // size before scheduleFitToWindow() shrinks it a tick later — a visible
        // flash on every image switch. Whole-image fit only; the focus-rect
        // path keeps the async fit (it also adjusts scroll position). The
        // viewport size is already known here: the old clip view (loaded→loaded)
        // or the canvas host (empty→loaded) is laid out and matches the new
        // scroll's pinned frame, so this mirrors what fitToWindow() computes.
        do {
            let viewport = canvasScroll?.contentView.bounds.size
                ?? canvasHost?.bounds.size ?? .zero
            let imgSize = newState.croppedRect?.size
                ?? CGSize(width: newState.sourceImage.width, height: newState.sourceImage.height)
            if viewport.width > 0, viewport.height > 0,
               imgSize.width > 0, imgSize.height > 0 {
                // Honor the user's remembered zoom across switches; fall back to
                // fit when nothing's remembered (first launch). Applies to focus-
                // cropped images too so they don't flash at the default scale.
                let fit = EditorCanvasScrollView.clampZoom(
                    EditorCanvasScrollView.fitZoom(
                        imageSize: imgSize,
                        viewportSize: viewport,
                        inset: EditorCanvasScrollView.fitInset
                    )
                )
                // A freshly captured/created image always fits; switches honor
                // THIS capture's remembered zoom (per-image, keyed by URL).
                newState.zoom = fitFresh
                    ? fit
                    : EditorCanvasScrollView.initialZoom(
                        remembered: ImageZoomMemory.load(for: newState.sourceURL), fit: fit)
            }
        }

        let newCanvas = EditorCanvasView(state: newState)
        newCanvas.alphaValue = 0   // revealed once the initial zoom has settled
        wireCaptureMenu(on: newCanvas)
        let newScroll = EditorCanvasScrollView(state: newState, canvas: newCanvas)

        if wasEmpty {
            // --- Empty → Loaded upgrade path ---
            if let host = canvasHost {
                // Remove empty canvas placeholder.
                emptyCanvas?.removeFromSuperview()
                // Install the real canvas scroll.
                styleCanvasScrollAsCard(newScroll)
                host.addSubview(newScroll)
                NSLayoutConstraint.activate([
                    newScroll.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                    newScroll.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                    newScroll.topAnchor.constraint(equalTo: host.topAnchor),
                    newScroll.bottomAnchor.constraint(equalTo: host.bottomAnchor),
                ])
                installChromeOverlay(state: newState, canvas: newCanvas, scroll: newScroll, host: host)
            }
            canvas = newCanvas
            canvasScroll = newScroll

            // Add the right sidebar (none existed in empty mode). Canvas is
            // index 0 (flexes); sidebar is index 1 (holds width).
            if let split = splitView {
                let newSidebar = EditorSidebarView(state: newState)
                newSidebar.translatesAutoresizingMaskIntoConstraints = false
                split.addArrangedSubview(newSidebar)
                installSidebarWidth(newSidebar, width: SidebarWidthPreference.load())
                split.setHoldingPriority(.defaultLow - 1, forSubviewAt: 0)
                split.setHoldingPriority(.defaultHigh, forSubviewAt: 1)
                sidebar = newSidebar
                newSidebar.onCommitCrop = { [weak self] in self?.commitCrop() }
                newSidebar.onCopyCrop = { [weak self] in _ = self?.state?.copyCropRegion() }
                newSidebar.onCutCrop  = { [weak self] in _ = self?.state?.cutCropRegion() }
                newSidebar.onSoftCrop = { [weak self] in _ = self?.state?.softCropRegion() }
                newSidebar.onCopySelectedText = { [weak self] in self?.handleCopy() }
                newSidebar.onCopyAllText = { [weak self] in self?.copyLiveText(all: true) }
                newSidebar.onEnhanceApply = { [weak self] in self?.onEnhanceApply?() }
                newSidebar.onEnhanceCancel = { [weak self] in self?.onEnhanceCancel?() }
                newSidebar.onRenameRequested = { [weak self] name in
                    self?.handleInfoPanelRename(to: name)
                }
                newSidebar.onMoveImageTextSearchResult = { [weak self] delta in
                    self?.canvas?.moveImageTextSearchResult(by: delta)
                }
                newSidebar.onExitImageTextSearch = { [weak self] in
                    self?.exitImageTextSearchToSelect()
                }
            }

            // Replace compact empty-mode meta row with full loaded-mode row.
            rebuildMetaRow(for: newState)

            // Replace the empty-mode tool bar (Capture only) with the full
            // loaded-mode bar (undo/redo, tools, export/copy).
            installToolsBar(empty: false)

            // Finishing touches shared with loaded→loaded path.
            setRepresentedCapture(newState.sourceURL, on: window)
            setWindowTitle(title)
            window?.initialFirstResponder = newCanvas
            window?.makeFirstResponder(newCanvas)
            restoreCarriedTool(carriedTool, infoMode: carriedInfoMode, enhanceEditing: carriedEnhance, on: newState)
            toolbarBuilder.setSelectedTool(carriedTool)
            recentStrip.selectedURL = newState.sourceURL
            fitCanvasSynchronously(fitFresh: fitFresh)
            scheduleFitToWindow(fitFresh: fitFresh)
            observeUndoRedo()
            observeSelectedTool()
            observeInfoPanel()
            observeObjectSelection()
            observeEnhanceButton()
            observeRedactionScan()
            observeStripPreview()
            observeAutosave()
            return  // skip loaded→loaded swap path
        }

        // --- Loaded → Loaded swap path ---
        styleCanvasScrollAsCard(newScroll)
        if let host = canvasHost {
            // canvasScroll lives inside canvasHost (behind the backdrop).
            // Swap it out and pin the new scroll to the host's edges.
            canvasScroll?.removeFromSuperview()
            host.addSubview(newScroll)
            NSLayoutConstraint.activate([
                newScroll.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                newScroll.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                newScroll.topAnchor.constraint(equalTo: host.topAnchor),
                newScroll.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            ])
            installChromeOverlay(state: newState, canvas: newCanvas, scroll: newScroll, host: host)
        }
        canvas = newCanvas
        canvasScroll = newScroll

        // The meta row also observes the OLD state for its zoom %/dimensions;
        // rebind it to newState or the percentage freezes after switching.
        rebuildMetaRow(for: newState)

        setRepresentedCapture(newState.sourceURL, on: window)
        setWindowTitle(title)
        window?.initialFirstResponder = newCanvas
        window?.makeFirstResponder(newCanvas)
        restoreCarriedTool(carriedTool, infoMode: carriedInfoMode, enhanceEditing: carriedEnhance, on: newState)
        if let previousState { newState.adoptCreationSettings(from: previousState) }
        toolbarBuilder.setSelectedTool(carriedTool)

        // Rebind the existing sidebar to newState in place (recreating it flashed).
        // Done AFTER the swap's own state mutations above — `restoreCarriedTool`
        // sets `sidebarPanelMode` and `adoptCreationSettings` sets
        // `blurMode`/`blurRegionShape`, all of which the sidebar observes. Arming
        // the sidebar's observation against the FINAL state means it rebuilds
        // exactly once; rebinding earlier let those later mutations fire a
        // redundant 50ms-deferred second rebuild — a visible info-panel flash
        // (most noticeable on Revert to Original, where the image is unchanged).
        // The sidebar's action closures use `self?.state?...` which already
        // resolves to newState (self.state was updated above).
        sidebar?.rebind(state: newState)

        // Don't rebuild the strip on every recent-strip click — that would
        // re-read the folder (autoSaveIfDirty in presentFile bumps mtimes,
        // causing thumbnails to visibly reshuffle). Just update the
        // selection highlight. Strip rebuilds happen only in handleDelete
        // and handleRestore, where the folder contents genuinely change.
        recentStrip.selectedURL = newState.sourceURL
        fitCanvasSynchronously(fitFresh: fitFresh)
        scheduleFitToWindow(fitFresh: fitFresh)
        observeUndoRedo()
        observeSelectedTool()
        observeInfoPanel()
        observeObjectSelection()
        observeEnhanceButton()
        observeRedactionScan()
        observeStripPreview()
        observeAutosave()
    }

    /// Restore a carried-over tool onto a freshly-presented state WITHOUT the
    /// assignment counting as a user tool selection. A user picking a tool
    /// auto-switches the sidebar from Info to Properties; an internal carry-over
    /// during an image switch must not, because the sidebar mode is remembered
    /// across image switches (per spec). Reasserts the seeded mode if the
    /// `selectedTool.didSet` auto-switch flipped it.
    /// Carry the active tool AND the Info/Properties mode across an image swap.
    /// The tool is set first; its `didSet` runs `afterToolSelected()` (which can
    /// flip Info→Properties), so the carried mode is applied AFTER — keeping the
    /// 'i' selection sticky while the user browses between images.
    private func restoreCarriedTool(_ tool: EditorTool, infoMode: SidebarPanelMode,
                                    enhanceEditing: Bool, on newState: EditorState) {
        newState.selectedTool = tool
        // A read-only (deleted) capture can't be edited: force the Info panel on
        // screen and grey out every editing pill. A live capture re-enables them.
        newState.sidebarPanelMode = newState.isReadOnly ? .info : infoMode
        newState.enhanceEditing = enhanceEditing
        toolbarBuilder.setEnhanceActive(enhanceEditing)
        toolbarBuilder.setReadOnly(newState.isReadOnly)
    }

    /// Whether an AI tool/mode is active on `state`. These are per-image and are
    /// intentionally NOT carried across an image switch (see `swap`) — carrying
    /// one would auto-trigger it on every image the user browses to:
    ///   • Live Text       — the `.textSelect` tool (auto-runs OCR)
    ///   • Enhance Clarity  — `enhanceEditing`
    ///   • Smart Redact     — a `redactionScan` scan/review in progress
    /// Extract Structured Data opens its own window and Remove Background is a
    /// one-shot cutout, so neither leaves a persistent per-image mode to reset;
    /// and the freshly-loaded state starts them idle regardless.
    static func isAIToolActive(_ state: EditorState) -> Bool {
        if state.selectedTool == .textSelect { return true }
        if state.showsImageTextSearchPanel { return true }
        if state.enhanceEditing { return true }
        switch state.redactionScan {
        case .scanning, .found: return true
        case .idle, .empty: return false
        }
    }

    // MARK: - Shell tab switcher

    /// Put the Editor/Library/Settings switcher on the traffic-light line by
    /// hosting it as the centered item of a unified window toolbar. (Titlebar
    /// accessories can only attach *below* that line, so a toolbar is the only
    /// way to share the row with the window controls.)
    private func installTabSwitcher(on window: NSWindow) {
        _ = makeTabSwitcher()

        let toolbar = NSToolbar(identifier: "com.seal-shot.editor.tabsToolbar")
        toolbar.delegate = self
        toolbar.allowsUserCustomization = false
        // `allowsUserCustomization` only governs the "Customize Toolbar…" sheet;
        // AppKit still offers Icon and Text / Icon Only / Text Only on
        // right-click, and the choice persists and overrides the display mode
        // set below — which is how the tab switcher ended up with a stray
        // "View" label under it. This switcher is the window's only toolbar
        // item and has no business being relabelled. macOS 15+ only; on 14 the
        // menu remains, with no supported way to suppress it.
        if #available(macOS 15.0, *) {
            toolbar.allowsDisplayModeCustomization = false
        }
        toolbar.displayMode = .iconOnly
        // Suppress the system divider AppKit draws below a unified toolbar
        // (the line between the tabs row and the tool bar).
        toolbar.showsBaselineSeparator = false
        // Centre the switcher EXPLICITLY rather than by symmetric flexible
        // spaces: the trailing floating-window item would otherwise push it
        // off-centre by half its own width.
        toolbar.centeredItemIdentifier = Self.tabsItemID
        window.toolbar = toolbar
        if #available(macOS 11.0, *) {
            window.toolbarStyle = .unified
        }
    }

    /// The floating-capture-window toggle that sits at the trailing edge of the
    /// tab-switcher row.
    private func makeFloatingWindowToolbarItem() -> NSToolbarItem {
        // The editor's own pill button, so it matches the tool buttons and —
        // the part that matters — gets their accent-tinted ACTIVE state. The
        // pip.enter/pip.exit glyph swap alone was too quiet to read as "this is
        // currently on".
        let pill = ActiveToolPillView(
            symbolName: Self.floatingWindowSymbol(isOpen: floatingWindowIsOpen),
            accessibilityLabel: "Floating capture window",
            symbolPointSize: 16
        ) { [weak self] in
            self?.onToggleFloatingWindow?()
        }
        floatingToolbarButton = pill
        refreshFloatingToolbarButton()

        let item = NSToolbarItem(itemIdentifier: Self.floatingItemID)
        item.view = pill
        item.label = "Floating Capture Window"
        return item
    }

    /// Report the PANEL's state on the button. Picture-in-picture is the
    /// platform's existing idiom for "give me a small always-on-top version of
    /// this", so it reads on first sight; `pip.exit` while open is what keeps
    /// "window, not mode" legible — it describes the panel, not the editor.
    func setFloatingWindowOpen(_ open: Bool) {
        floatingWindowIsOpen = open
        refreshFloatingToolbarButton()
    }

    private func refreshFloatingToolbarButton() {
        let label = floatingWindowIsOpen ? "Close the floating capture window"
                                         : "Open the floating capture window"
        guard let pill = floatingToolbarButton else { return }
        pill.setBaseSymbol(Self.floatingWindowSymbol(isOpen: floatingWindowIsOpen))
        // The accent-tinted pill background is the state readout; the glyph
        // swap on its own was too subtle to notice.
        pill.isActive = floatingWindowIsOpen
        pill.tooltipText = label
        pill.setAccessibilityLabel(label)
    }

    /// Builds (or rebuilds) the Editor/Library/Settings switcher control, stores
    /// the strong reference, and re-arms the encryption nav-lock observation.
    /// Also called from the toolbar item provider as a safety net if the control
    /// was ever torn down (e.g. an unusual hide/show sequence).
    @discardableResult
    private func makeTabSwitcher() -> NSSegmentedControl {
        let seg = NSSegmentedControl(
            labels: ShellTab.allCases.map { $0.title },
            trackingMode: .selectOne,
            target: self,
            action: #selector(tabSwitcherChanged(_:))
        )
        seg.selectedSegment = currentTabSelection.rawValue
        self.tabSwitcher = seg
        observeEncryptionOperation()   // disable tabs while encrypting/decrypting
        return seg
    }

    /// Re-render the (now hidden) native window title as a centered
    /// icon + filename row inside `titleHost` (the second header row).
    private func installTitleRow(on window: NSWindow) {
        guard let host = titleHost else { return }

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyDown
        self.titleIcon = icon

        // Read-only: renaming moved to the Info panel's Name field (the title
        // bar shows the name; the panel edits it).
        let label = NSTextField(string: window.title)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isEditable = false
        label.isSelectable = true
        label.isBordered = false
        label.isBezeled = false
        label.drawsBackground = false
        label.focusRingType = .none
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        label.textColor = .labelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        label.usesSingleLineMode = true
        self.titleLabel = label

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.isDisplayedWhenStopped = false
        spinner.isHidden = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.setContentHuggingPriority(.required, for: .horizontal)
        self.titleRowSpinner = spinner

        let row = NSStackView(views: [spinner, icon, label])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 5
        row.translatesAutoresizingMaskIntoConstraints = false

        host.addSubview(row)

        // ★ Favorite toggle at the title bar's right edge — same vertical level
        // as the centered filename. Outline star = not favorite; filled gold =
        // favorite. Sits in the trailing margin the centered row reserves (it
        // never extends past host.trailing - 80), so they don't overlap.
        let favorite = NSButton()
        favorite.translatesAutoresizingMaskIntoConstraints = false
        favorite.isBordered = false
        favorite.bezelStyle = .toolbar
        favorite.setButtonType(.toggle)
        favorite.imagePosition = .imageOnly
        favorite.image = NSImage(systemSymbolName: "star",
                                 accessibilityDescription: "Favorite")
        favorite.alternateImage = NSImage(systemSymbolName: "star.fill",
                                          accessibilityDescription: "Favorite")
        favorite.toolTip = "Favorite"
        favorite.target = self
        favorite.action = #selector(toggleFavorite(_:))
        favorite.setContentHuggingPriority(.required, for: .horizontal)
        host.addSubview(favorite)
        self.titleFavoriteButton = favorite

        // Sized to the text in `sizeTitleLabelToContent()`. High (not required)
        // so the leading/trailing inset inequalities win for long titles and
        // force truncation rather than overflow.
        let labelWidth = label.widthAnchor.constraint(equalToConstant: 0)
        labelWidth.priority = .defaultHigh
        self.titleLabelWidth = labelWidth
        NSLayoutConstraint.activate([
            row.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            row.topAnchor.constraint(equalTo: host.topAnchor),
            row.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            // Don't let a long filename push past the window edges.
            row.leadingAnchor.constraint(greaterThanOrEqualTo: host.leadingAnchor, constant: 80),
            row.trailingAnchor.constraint(lessThanOrEqualTo: host.trailingAnchor, constant: -80),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            spinner.widthAnchor.constraint(equalToConstant: 14),
            spinner.heightAnchor.constraint(equalToConstant: 14),
            labelWidth,
            favorite.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -12),
            favorite.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            favorite.widthAnchor.constraint(equalToConstant: 18),
            favorite.heightAnchor.constraint(equalToConstant: 18),
        ])
        updateTitleRow()
    }

    /// Backstop so the title spinner can never sit there indefinitely, matching
    /// the strip's per-tile spinner (`markNameRefining`, same 8s). The registry
    /// clears on every exit path, so this only fires if generation genuinely
    /// hangs — but "spins forever" is the one failure a progress hint must not
    /// have.
    private var titleRefiningTimeout: DispatchWorkItem?

    /// Show/hide the title-row spinner (and collapse it in the stack when off).
    private func setTitleRowRefining(_ refining: Bool) {
        guard let spinner = titleRowSpinner else { return }
        titleRefiningTimeout?.cancel()
        titleRefiningTimeout = nil
        spinner.isHidden = !refining
        if refining {
            spinner.startAnimation(nil)
            let timeout = DispatchWorkItem { [weak self] in
                guard let spinner = self?.titleRowSpinner else { return }
                spinner.isHidden = true
                spinner.stopAnimation(nil)
                self?.titleRefiningTimeout = nil
            }
            titleRefiningTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: timeout)
        } else {
            spinner.stopAnimation(nil)
        }
    }

    /// Sync the title row's filename + icon with the window title and
    /// represented URL. Call whenever either changes.
    /// The item the title bar + favorite star represent: the video playing in
    /// the canvas when there is one, otherwise the open capture (the window's
    /// represented URL). So switching from an image to a video shows the video's
    /// name/favorite, not the previous image's.
    private var currentItemURL: URL? { playingVideoURL ?? window?.representedURL }

    /// Public alias of `currentItemURL` for navigation-entry recording
    /// (`EditorController.presentFile`, `playVideoInCanvas`): the item the
    /// canvas is showing right now — the playing video, else the open
    /// capture — same identity the title bar uses.
    var currentDisplayedItemURL: URL? { currentItemURL }

    private func updateTitleRow() {
        if let url = currentItemURL {
            titleLabel?.stringValue = CaptureDisplayName.resolve(for: url)
            // Kind icon matching the Library's (photo / play.rectangle), not
            // the generic Finder document icon.
            let isVideo = playingVideoURL != nil
            titleIcon?.image = NSImage(
                systemSymbolName: isVideo ? "play.rectangle" : "photo",
                accessibilityDescription: isVideo ? "Video" : "Image")?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
            titleIcon?.contentTintColor = .secondaryLabelColor
            titleIcon?.isHidden = false
            setTitleRowRefining(MetadataCoordinator.shouldShowTitleRefining(
                pipelineInFlight: NameGenerationRegistry.shared.contains(url),
                willGenerateAIName: MetadataCoordinator.willGenerateAINameNow))
        } else {
            titleLabel?.stringValue = window?.title ?? ""
            titleIcon?.isHidden = true
            setTitleRowRefining(false)
        }
        // An editable, bezel-less NSTextField reports no intrinsic width, so
        // inside the centered stack it collapses to ~0pt and only the icon
        // shows. Size it to its text explicitly (capped by the row's leading/
        // trailing insets, so long titles still truncate).
        sizeTitleLabelToContent()
        updateFavoriteButton()
    }

    /// Reflect the current capture's favorite state on the title-bar star.
    /// Hidden for unsaved/scratch sessions (no source URL to persist against).
    private func updateFavoriteButton() {
        guard let button = titleFavoriteButton else { return }
        guard let url = currentItemURL else {
            button.isHidden = true
            return
        }
        button.isHidden = false
        let manifest = try? SealMetadataStore.readManifest(at: url)
        let fav = manifest.map { CaptureWorkflow.isFavorite($0) } ?? false
        button.state = fav ? .on : .off
        button.contentTintColor = fav ? .systemYellow : .secondaryLabelColor
    }

    /// Persist the favorite toggle from the title-bar star.
    @objc private func toggleFavorite(_ sender: NSButton) {
        guard let url = currentItemURL else { return }
        let fav = sender.state == .on
        // `try?` on a Void-returning throwing call yields nil only when it threw.
        if (try? SealMetadataStore.setWorkflow(isFavorite: fav, to: url)) == nil {
            NSSound.beep()
            sender.state = fav ? .off : .on   // revert the visual on failure
        } else {
            NotificationCenter.default.post(name: .captureMetadataDidChange, object: url)
        }
        sender.contentTintColor = (sender.state == .on) ? .systemYellow : .secondaryLabelColor
    }

    /// Drive the editable title field's width from its rendered text, since it
    /// has no content-based intrinsic width of its own.
    private func sizeTitleLabelToContent() {
        guard let label = titleLabel else { return }
        let font = label.font ?? .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        let width = (label.stringValue as NSString)
            .size(withAttributes: [.font: font]).width
        // +4pt slack so the trailing glyph isn't clipped by rounding.
        titleLabelWidth?.constant = ceil(width) + 4
    }

    /// Set the window title and keep the re-rendered title row in sync.
    private func setWindowTitle(_ title: String) {
        window?.title = title
        updateTitleRow()
    }

    @objc private func tabSwitcherChanged(_ sender: NSSegmentedControl) {
        guard let tab = ShellTab(segmentIndex: sender.selectedSegment) else { return }
        selectTab(tab)
    }

    /// Swap window content + editor-toolbar visibility for the chosen tab.
    func selectTab(_ tab: ShellTab) {
        currentTabSelection = tab
        tabSwitcher?.selectedSegment = tab.rawValue
        // Re-derive the block on every navigation. The gate is cheap to
        // compute and this is the user's natural "why is this still stuck?"
        // moment — a stale disable can never outlive a tab switch.
        updateBlockingUIState()

        // Leaving the editor pauses any playing canvas video — Library/Settings
        // shouldn't keep it (and its audio) running behind them. The position is
        // kept so returning to the editor resumes from where it left off.
        if tab != .editor { canvasVideoPlayer?.pause() }

        // Lazily create placeholder views on first use.
        if tab == .library && libraryPlaceholder == nil {
            let vm = LibraryViewModel(
                config: config,
                onOpen: { [weak self] url in self?.onRecentClickStored(url) },
                onPlayVideo: { [weak self] url in self?.playVideoInCanvas(url: url) },
                onCaptureNew: { [weak self] in self?.onCaptureRequested?() },
                onImport: { [weak self] in self?.onImportRequested?() })
            vm.onImportFiles = { [weak self] urls in self?.onImportFilesRequested?(urls, true) }
            vm.onRestoreArchive = { [weak self] in self?.presentArchiveRestoreSheet() }
            vm.globalUndo = globalUndo
            libraryViewModel = vm
            let host = NSHostingView(rootView: LibraryView(viewModel: vm))
            host.translatesAutoresizingMaskIntoConstraints = false
            // Edge-pinned to fill the shell — the SwiftUI content must never
            // push min/max size extrema onto the window. Doing so re-enters
            // the constraint pass mid-update and crashes
            // (NSInternalInconsistencyException) on macOS 26.
            host.sizingOptions = []
            libraryPlaceholder = host
        }
        if tab == .settings && settingsPlaceholder == nil {
            let host = NSHostingView(rootView: SettingsView(config: config))
            host.translatesAutoresizingMaskIntoConstraints = false
            // Same macOS 26 reentrant-layout guard as the Library host above.
            host.sizingOptions = []
            settingsPlaceholder = host
        }

        // Add placeholder views to the shell container if not yet present.
        // Top-pinned below the license banner strip (bannerHost), like
        // editorColumn, so the banner spans every tab and pushes content
        // down instead of overlaying it.
        if let container = shellContainer, let bannerHost = licenseBannerHost {
            [libraryPlaceholder, settingsPlaceholder].compactMap { $0 }.forEach { view in
                if view.superview == nil {
                    view.translatesAutoresizingMaskIntoConstraints = false
                    container.addSubview(view)
                    NSLayoutConstraint.activate([
                        view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                        view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                        view.topAnchor.constraint(equalTo: bannerHost.bottomAnchor),
                        view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                    ])
                }
            }
        }

        // While locked, NO tab's content may render. Every placeholder carries
        // the `|| locked` term, not just the editor column: relying on the
        // overlay to cover them makes "hidden" and "covered" two different
        // guarantees, and only the weaker one applied. A tab visited for the
        // first time while locked is also added to `container` AFTER the
        // overlay, so it would z-order above the thing meant to hide it —
        // `raiseLockOverlay()` below re-asserts the ordering.
        let locked = EncryptionSession.shared.isEnabled && !EncryptionSession.shared.isUnlocked
        editorContentView?.isHidden = ShellTab.isContentHidden(.editor, selected: tab, locked: locked)
        libraryPlaceholder?.isHidden = ShellTab.isContentHidden(.library, selected: tab, locked: locked)
        settingsPlaceholder?.isHidden = ShellTab.isContentHidden(.settings, selected: tab, locked: locked)
        raiseLockOverlay()

        if tab == .library {
            if libraryFolderWatcher == nil {
                let watcher = FolderWatcher()
                watcher.onChange = { [weak self] in
                    guard let self, self.currentTabSelection == .library else { return }
                    self.libraryViewModel?.reload()
                }
                libraryFolderWatcher = watcher
            }
            // Re-arms automatically if the save folder changed in Settings
            // (watch() is a no-op for the same folder). FSEvents is recursive,
            // so the Deleted/ trash subfolder is covered by the same stream.
            libraryFolderWatcher?.watch(config.saveFolder)
            libraryViewModel?.reload()
        }
        // The header (tool bar + filename) lives inside editorContentView, so
        // it hides automatically with the column on Library/Settings. The tabs
        // toolbar stays on the top line.
    }

    /// Rebuild the full-mode meta row bound to `newState`, replacing the
    /// current one in place. Required on EVERY state swap: the meta row
    /// captures its `EditorState` at init for zoom/dimension observation,
    /// so a stale instance keeps showing the previous image's zoom % and
    /// never reacts to the new image's zoom changes.
    private func rebuildMetaRow(for newState: EditorState) {
        guard let oldMeta = metaRow,
              let leftColumn = container,
              let idx = leftColumn.arrangedSubviews.firstIndex(of: oldMeta) else { return }
        let newMeta = EditorMetaRowView(
            state: newState,
            onFitWindow: { [weak self] in self?.routedFitWindow() },
            onZoom100: { [weak self] in self?.routedActualSize() },
            onFitWidth: { [weak self] in self?.routedFitWidth() },
            onFitHeight: { [weak self] in self?.routedFitHeight() },
            onFocus: { [weak self] in self?.routedFocus() },
            onSetZoom: { [weak self] z in self?.routedSetZoom(z) },
            onZoomIn: { [weak self] in self?.routedZoomIn() },
            onZoomOut: { [weak self] in self?.routedZoomOut() },
            onTabChange: { [weak self] tab in
                self?.currentTab = tab
                self?.mountStrip(for: tab)
            }
        )
        newMeta.translatesAutoresizingMaskIntoConstraints = false
        newMeta.heightAnchor.constraint(equalToConstant: EditorMetaRowView.height).isActive = true
        // Re-wire the strip toggle and mirror the current collapsed state —
        // a fresh meta row defaults to a no-op toggle and a visible-strip
        // chevron, which left the hide control dead after every swap.
        newMeta.onToggleStrip = { [weak self] in self?.toggleStripHidden() }
        newMeta.setStripHidden(stripHidden)
        // Likewise re-wire the media filter — a fresh meta row defaults to a
        // no-op handler, which left the All/Images/Videos control dead after a
        // swap (the editor swaps in a capture right after opening).
        newMeta.setMediaFilter(mediaFilter)
        newMeta.onSelectMediaFilter = { [weak self] filter in self?.applyMediaFilter(filter) }
        // Re-wire the Resize trigger + canvas-centred zoom cluster too — a
        // fresh meta row defaults to a no-op click handler and row-centring.
        newMeta.onResizeButtonClicked = { [weak self] btn in
            self?.toggleResizePopover(anchor: btn)
        }
        leftColumn.insertArrangedSubview(newMeta, at: idx)
        leftColumn.removeArrangedSubview(oldMeta)
        oldMeta.removeFromSuperview()
        self.metaRow = newMeta
        if let host = canvasHost { newMeta.anchorZoomCluster(toCenterOf: host) }
        // The fresh meta row defaults its Deleted tab to enabled — re-apply the
        // trash-empty state.
        updateDeletedTabAvailability()
    }

    // MARK: - Undo/redo button state

    /// Observe `canUndo`/`canRedo` and reflect them on the toolbar buttons,
    /// re-arming after each change. Call again after a state swap so the
    /// tracking follows the new state.
    private func observeUndoRedo() {
        guard let state = state else { return }
        wireTimelineCheckpoints(state)
        updateUndoRedoButtons()
        wireMetadataUndo(state)
    }

    /// Route this state's checkpoints onto the app-global timeline: every
    /// minted edit checkpoint records an `.edit` entry, and an optimistic
    /// checkpoint's cancellation removes the matching top edit. Re-wired on
    /// every state adoption (init / swap) so the closures target the live state.
    private func wireTimelineCheckpoints(_ state: EditorState) {
        state.onCheckpoint = { [weak self, weak state] snapshot in
            guard let self else { return }
            self.globalUndo.record(.edit(capture: state?.sourceURL, snapshot: snapshot))
            self.updateUndoRedoButtons()
        }
        state.onDiscardCheckpoint = { [weak self, weak state] action in
            guard let self else { return }
            self.globalUndo.removeTopEdit(action: action, capture: state?.sourceURL)
            self.updateUndoRedoButtons()
        }
    }

    /// Metadata edits (rename / summary / tags) are ⌘Z steps. The store hook
    /// mints a checkpoint whenever a user-editable field of the OPEN document
    /// changes — one seam catches every Info-panel edit control. Generators
    /// write other fields (smartKeywords, generated summary) and never trip
    /// it; our own restore writes and the rename path (which mints its own
    /// labeled checkpoint) are suppressed via `suppressMetadataCheckpoints`.
    private func wireMetadataUndo(_ state: EditorState) {
        state.metadataPatchProvider = { [weak self] in
            guard let url = self?.state?.sourceURL,
                  let manifest = try? SealMetadataStore.readManifest(at: url) else { return nil }
            return MetadataUndoPatch(from: manifest.metadata)
        }
        SealMetadataStore.didUpdateMetadata = { [weak self] url, pre, post in
            guard let self, !self.suppressMetadataCheckpoints else { return }
            let before = MetadataUndoPatch(from: pre)
            let after = MetadataUndoPatch(from: post)
            guard before != after else { return }
            if let state = self.state, !state.isReadOnly, url == state.sourceURL {
                let action: String
                if before.tags != after.tags { action = "Edit Tags" }
                else if before.userSummary != after.userSummary { action = "Edit Summary" }
                else { action = "Rename" }
                state.recordUndoCheckpoint(action: action, metadata: before)
                self.updateUndoRedoButtons()
            } else if self.isVideoPackage(url) {
                // Metadata-only edit (title/summary/tags) to a video capture —
                // never a `state.sourceURL` match since videos play in an
                // overlay (`playingVideoURL`) rather than becoming the open
                // EditorState document; `presentFile` early-returns to
                // `presentRecording`/`playVideoInCanvas` for `.seal` video
                // packages before ever assigning `sourceURL`. So this branch
                // is unreachable for the currently-open item even when it is
                // read-only (deleted-tab view) — belt-and-braces, not a
                // real overlap with the `state.sourceURL` branch above.
                self.globalUndo.record(.videoMetadata(item: url, before: before, after: after))
                self.updateUndoRedoButtons()
            }
        }
    }

    /// Cheap "is this `.seal` package a video capture" check for an arbitrary
    /// URL (not necessarily open/playing). `.seal` is shared by image and
    /// video packages, so the extension alone can't tell — read the manifest
    /// (a small `manifest.json`, not the multi-GB payload) and check the v8
    /// `video` field, which is present only for video captures.
    private func isVideoPackage(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "seal" else { return false }
        return (try? SealMetadataStore.readManifest(at: url))?.video != nil
    }

    /// Keep the toolbar's active-tool highlight in sync with `selectedTool`,
    /// including programmatic switches (e.g. Esc → Select) that don't go
    /// through the toolbar's own click handler. Re-arms after each change.
    private func observeSelectedTool() {
        guard let state = state else { return }
        syncToolbarHighlights()
        handleLiveTextEnhanceTransition()
        withObservationTracking {
            _ = state.selectedTool
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.observeSelectedTool()
            }
        }
    }

    /// Tool last seen by the Live Text enhance-session handler, so entering /
    /// leaving `.textSelect` is detected across programmatic switches too.
    private var liveTextEnhanceLastTool: EditorTool = .select

    /// Live Text OCRs `displayBase`, and super-resolved glyphs read far
    /// better than raw small fonts — so picking the tool temporarily shows
    /// the enhanced base (generating it via the normal Enhance pipeline +
    /// overlay when the capture has none), and leaving the tool restores the
    /// user's prior original/enhanced choice. Saves are unaffected mid-
    /// session (`persistedShowingEnhanced`).
    private func handleLiveTextEnhanceTransition() {
        guard let state else { return }
        let tool = state.selectedTool
        defer { liveTextEnhanceLastTool = tool }
        guard tool != liveTextEnhanceLastTool else { return }
        if tool == .textSelect {
            // Video mode has no image base to enhance.
            guard state.playingVideoURL == nil else { return }
            let action = state.beginLiveTextEnhanceSession()
            if state.showsImageTextSearchPanel {
                switch action {
                case .none:
                    primeImageTextSearchScanStage(state)
                case .showedExisting:
                    state.imageTextSearchScanStage = .recognizingCurrentBase
                case .needsGeneration:
                    state.imageTextSearchScanStage = .waitingForEnhancementDecision
                }
            }
            if action == .needsGeneration, OCRPerformanceClass.current == .cpuOnly {
                // Without a Neural Engine, super-resolution is a net loss: it
                // doubles each side, so the OCR that follows runs over 4x the
                // pixels and lands in a much higher tile count — measured in
                // the field at 15 tiles / ~20s for the enhanced base versus 6
                // tiles for the raw one. Vision's per-request floor is ~120ms
                // here (~14ms on an M4), so that trade only pays where the
                // recognition itself is cheap. Read the raw base instead —
                // exactly the path taken when the probe finds no text.
                if state.showsImageTextSearchPanel {
                    state.imageTextSearchScanStage = .recognizingCurrentBase
                }
            } else if action == .needsGeneration {
                // Only pay for super-resolution when the image actually has
                // text. Probe the raw base first; enhance only if text is found.
                // If none, leave the raw base — the overlay OCR reports no text.
                //
                // Hold the canvas off the raw base for the length of the probe
                // and any enhancement that follows. Set BEFORE the probe: the
                // canvas reacts to the tool change on this same turn, so a flag
                // set after the await would arrive too late to stop it.
                state.liveTextAwaitingEnhancement = true
                let raw = state.sourceImage
                Task { @MainActor [weak self] in
                    let hasText = await Self.rawImageHasText(raw)
                    guard let self, self.state === state,
                          state.selectedTool == .textSelect,
                          state.liveTextEnhanceRestore != nil else {
                        // Tool left, capture swapped, or the session ended
                        // under us — release the canvas, or Live Text stays
                        // wedged for this capture.
                        state.liveTextAwaitingEnhancement = false
                        return
                    }
                    if hasText {
                        if state.showsImageTextSearchPanel {
                            state.imageTextSearchScanStage = .waitingForEnhancedOCR
                        }
                        // Stays set — `runEnhanceApply` clears it when the
                        // enhanced base lands (or the attempt fails).
                        self.onEnhanceApply?()
                    } else {
                        // No text: nothing will replace this base, so the
                        // canvas reads it now.
                        state.liveTextAwaitingEnhancement = false
                        if state.showsImageTextSearchPanel {
                            state.imageTextSearchScanStage = .recognizingCurrentBase
                        }
                    }
                }
            }
        } else if liveTextEnhanceLastTool == .textSelect {
            if state.endLiveTextEnhanceSession() { onEnhanceCancel?() }
        }
    }

    /// Quick text-presence probe on the raw image. Used to skip the expensive
    /// Live Text auto-enhance when there is no text to read.
    ///
    /// This used to run the FULL recognition pipeline to produce a boolean —
    /// measured at ~28s on a Mac without a Neural Engine, i.e. the probe cost
    /// far more than the enhancement it exists to avoid. `containsText` is a
    /// single `.fast` pass (~60ms) with the same presence sensitivity.
    private static func rawImageHasText(_ image: CGImage) async -> Bool {
        await TextRecognizer().containsText(image)
    }

    /// End an active Live Text enhance session (used by `swap` for the
    /// outgoing state, whose observation is about to be torn down).
    private func endLiveTextEnhanceSession(on state: EditorState) {
        if state.endLiveTextEnhanceSession() { onEnhanceCancel?() }
    }

    /// Reflect the app-global timeline's undo/redo availability on the toolbar.
    func updateUndoRedoButtons() {
        // Buttons mirror the app-global timeline on every tab (the Deleted tab
        // included) — a capture/import undo lands the user there, and redo must
        // stay available to bring the item back. See `performTimelineStep`.
        // Persisted entries can outlive what they reference (trash emptied,
        // Delete Forever, capture removed) — prune dead tops on BOTH sides
        // FIRST so a button never claims an undo/redo that would silently
        // no-op (field bug: enabled Undo button doing nothing).
        pruneTimeline(redo: false)
        pruneTimeline(redo: true)
        toolbarBuilder.setUndoEnabled(globalUndo.canUndo)
        toolbarBuilder.setRedoEnabled(globalUndo.canRedo)
    }

    /// Disable the Editor/Library/Settings tab switcher while an encrypt/decrypt
    /// operation runs, so the user can't navigate away mid-migration. Re-arms
    /// after each change (mirrors observeInfoPanel).
    private func observeEncryptionOperation() {
        updateTabSwitcherEnabled()
        withObservationTracking {
            _ = EncryptionSession.shared.operationInProgress
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeEncryptionOperation() }
        }
    }

    /// Tabs are disabled while an encryption migration OR a blocking AI action
    /// (Extract Data / Smart Redact / summarize / Enhance run) is in flight.
    private func updateTabSwitcherEnabled() {
        tabSwitcher?.isEnabled = !EncryptionSession.shared.operationInProgress
            && !hasBlockingOverlay
    }

    // MARK: - Blocking AI action gate

    /// Whether a blocking overlay is on screen right now. While it is, the
    /// toolbar and tab switcher are frozen — the overlay's Cancel button and
    /// the recent strip (whose navigation cancels the action) stay interactive
    /// as the escape hatches.
    ///
    /// DERIVED, not counted. This used to be a `blockingAIActionCount` latch
    /// incremented in the two `show…Overlay` methods and decremented in their
    /// `hide` counterparts — two increment sites against a dozen decrement
    /// sites scattered through async cancel/finish/teardown paths. A single
    /// missed decrement (see `runEnhanceApply`, whose task returned through a
    /// weak-capture guard placed above its `defer`) left the count stuck above
    /// zero with no overlay to justify it, and the tabs stayed dead for the
    /// rest of the session with no way back short of relaunching. Reading the
    /// overlays makes that state unrepresentable: no overlay, no block.
    private var hasBlockingOverlay: Bool {
        enhancingOverlay != nil || canvasProgressOverlay != nil
    }

    /// Re-apply the block to the toolbar and tabs. Idempotent and cheap, so it
    /// is safe to call from anywhere the answer might have changed — every
    /// overlay show/hide, tab navigation, and lock-state change does.
    func updateBlockingUIState() {
        toolbarBuilder.setInteractionEnabled(!hasBlockingOverlay)
        updateTabSwitcherEnabled()
    }

    /// Test hook: whether navigation and the toolbar are currently frozen.
    var debugBlockingOverlayActive: Bool { hasBlockingOverlay }

    /// Navigation makes an in-flight canvas-progress action (Extract Data,
    /// video summarize) stale — cancel it, same as the redaction scan.
    func cancelCanvasProgressAction() {
        progressActionTask?.cancel()
    }

    /// Reflect the sidebar's current mode on the Info / Find pills; re-arm after
    /// each change. Call again after a state swap so tracking follows new state.
    private func observeInfoPanel() {
        guard let state = state else { return }
        syncToolbarHighlights()
        withObservationTracking {
            _ = state.sidebarPanelMode
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.syncToolbarHighlights()
                self?.observeInfoPanel()
            }
        }
    }

    /// Reflect Smart Redact's lifecycle on the toolbar: the pill stays lit while
    /// a scan runs OR its review panel is up, and the armed tool stays deselected
    /// for the duration. Re-arms after each change (mirrors observeInfoPanel).
    private func observeRedactionScan() {
        guard let state = state else { return }
        syncToolbarHighlights()
        withObservationTracking {
            _ = state.redactionScan.isActive
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.syncToolbarHighlights()
                self?.observeRedactionScan()
            }
        }
    }

    /// Single authority for mutually-exclusive toolbar highlights. Exactly one
    /// long-lived mode is lit: Find, Info, Enhance, Smart Redact, or the active
    /// tool. A sidebar-owning mode clears every tool pill, including Select.
    private func syncToolbarHighlights() {
        guard let state = state else { return }
        let info = state.showsInfoPanel
        let search = state.showsImageTextSearchPanel
        let enhance = state.enhanceEditing
        let redact = state.redactionScan.isActive
        toolbarBuilder.setInfoActive(info)
        toolbarBuilder.setImageTextSearchActive(search)
        toolbarBuilder.setEnhanceActive(enhance)
        toolbarBuilder.setSmartRedactScanning(redact)
        if info || search || enhance || redact {
            toolbarBuilder.clearToolHighlight()
        } else {
            toolbarBuilder.setSelectedTool(state.selectedTool)
        }
    }

    /// Keep the menu-bar Edit▸object items in step with the canvas selection.
    /// Re-arms after each change (mirrors observeInfoPanel).
    private func observeObjectSelection() {
        guard let state = state else { return }
        syncObjectMenuState()
        withObservationTracking {
            _ = state.selectedAnnotationIDs
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.syncObjectMenuState()
                self?.observeObjectSelection()
            }
        }
    }

    private func syncObjectMenuState() {
        guard let state = state, !state.isReadOnly else {
            ObjectMenuState.shared.update(hasSelection: false, hasFlippableSelection: false)
            return
        }
        let selected = state.annotations.filter { state.selectedAnnotationIDs.contains($0.id) }
        ObjectMenuState.shared.update(
            hasSelection: !selected.isEmpty,
            hasFlippableSelection: selected.contains { EditorState.isFlippable($0.geometry) })
    }

    /// Highlight the toolbar Enhance pill while the Enhance panel is open
    /// (enhanceEditing = true). Re-arms after each change (mirrors observeInfoPanel).
    private func observeEnhanceButton() {
        guard let state = state else { return }
        updateEnhanceButton()
        withObservationTracking {
            _ = state.enhanceEditing
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.updateEnhanceButton()
                self?.observeEnhanceButton()
            }
        }
    }

    private func updateEnhanceButton() {
        // Full sync so entering/leaving Enhance also clears/restores the tool
        // highlight (Enhance is mutually exclusive with the annotation tools).
        syncToolbarHighlights()
    }

    /// Reflect scan progress on the Smart Redact pill (highlight while running).
    func setSmartRedactScanning(_ scanning: Bool) {
        toolbarBuilder.setSmartRedactScanning(scanning)
    }

    /// A clean Smart Redact scan reports as a canvas toast — the same surface
    /// as every other transient outcome message (undo hints, "No text
    /// found") — not as a flash on the toolbar pill, which reads as tool
    /// state rather than a result.
    func flashNoSensitiveContent() {
        guard let host = canvasHost ?? window?.contentView else { return }
        EditorToastView.show("No sensitive content found", in: host)
    }

    // MARK: - Autosave (.seal on every change, debounced)

    /// Observe edits and schedule a debounced `.seal` autosave. Re-arms after
    /// each change and is re-called after a state swap so tracking follows the
    /// new state (mirrors observeUndoRedo / observeStripPreview).
    private func observeAutosave() {
        guard let state = state else { return }
        withObservationTracking {
            _ = state.annotations
            _ = state.croppedRect
            _ = state.focusRect
            _ = state.isDirty
            // Clearing this on mouseUp re-fires the observation, re-scheduling
            // a save that was deferred during the drag.
            _ = state.interactionInProgress
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.scheduleAutosave()
                self?.observeAutosave()
            }
        }
    }

    /// Debounce: (re)schedule a save ~0.8s out, cancelling any pending one.
    private func scheduleAutosave() {
        guard let state = state, state.isDirty, !state.isReadOnly else { return }
        autosaveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.performAutosave() }
        autosaveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    /// Write the `.seal` package (no clipboard). Reassigns the URL when a legacy
    /// `.png` migrates to a new `.seal` sibling. Errors are logged.
    ///
    /// The heavy encode/encrypt/write runs off the main thread (see
    /// `EditorSaveCoordinator.autosave`); only the composite render and the
    /// completion side-effects touch the main thread. Skipped while a canvas
    /// drag is in flight — the flag clearing on mouseUp re-schedules it.
    private func performAutosave() {
        guard let state = state, state.isDirty, !state.isReadOnly,
              !state.interactionInProgress else { return }
        // Optimistic: the snapshot the coordinator takes now faithfully
        // captures the document, so mark clean immediately. Any edit during the
        // background write re-dirties the state and schedules another autosave;
        // a write failure re-dirties below so it retries.
        let target = state
        let oldURL = target.sourceURL
        target.markClean()
        saver.autosave(state: target) { [weak self] result in
            guard let self, self.state === target else { return }
            switch result {
            case .success(let newURL):
                if newURL != oldURL {
                    // First scratch save (no prior URL) rebinds every scratch
                    // `.edit` in the timeline to the new file; a legacy-png
                    // migration renames its existing entries.
                    if oldURL == nil { self.globalUndo.rebindScratch(to: newURL) }
                    else if let oldURL { self.globalUndo.renameCapture(from: oldURL, to: newURL) }
                }
                if newURL != target.sourceURL {
                    target.sourceURL = newURL
                    self.setRepresentedCapture(newURL, on: self.window)
                    self.recentStrip.selectedURL = newURL
                    self.setWindowTitle(newURL.lastPathComponent)
                }
            case .failure(let error):
                target.markDirty()
                os_log("editor autosave failed: %{public}@",
                       log: log, type: .error, String(describing: error))
            }
        }
    }

    // MARK: - Live strip preview

    /// Keep the open file's recent-strip thumbnail in sync with unsaved edits:
    /// re-render the composite whenever annotations or the crop change, and
    /// push it onto the matching tile. Re-arms after each change, and is
    /// re-called after a state swap so tracking follows the new state.
    private func observeStripPreview() {
        updateStripPreview()
        armStripPreviewObservation()
    }

    /// Re-arming half of `observeStripPreview`: renders go through the
    /// debounce only, so the per-change re-subscription never composites
    /// inline (observation is one-shot, so this re-runs on every change).
    private func armStripPreviewObservation() {
        guard let state = state else { return }
        withObservationTracking {
            _ = state.annotations
            _ = state.croppedRect
            _ = state.focusRect
            // Base swaps change the rendered look too: Remove Background's
            // cutout and the Enhance toggle must refresh the thumbnail.
            _ = state.showingCutout
            _ = state.showingEnhanced
            // Clearing this on mouseUp re-fires the observation, which is
            // what runs the work deferred during the drag.
            _ = state.interactionInProgress
            // A NEW canvas starts with no URL, and `updateStripPreview` needs
            // one (the strip matches tiles by URL), so every render before the
            // first autosave is skipped. That save assigns the URL — track it,
            // or the tile that appears then keeps showing the saved composite
            // until some OTHER tracked property happens to change. Also covers
            // rename/move, which reassign `sourceURL` too.
            _ = state.sourceURL
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.scheduleStripPreviewUpdate()
                self?.armStripPreviewObservation()
            }
        }
    }

    /// Debounce the preview: it composites the FULL-RESOLUTION image on the
    /// main thread, and annotations change on every mouse event of a drag —
    /// rendering per tick makes the drag visibly lag. One render shortly
    /// after the last change is all the thumbnail needs. While a canvas
    /// interaction is in flight the render is skipped outright (a pointer
    /// pause mid-drag would otherwise let the debounce fire and hitch the
    /// drag); mouseUp clears the flag, which re-schedules via observation.
    private func scheduleStripPreviewUpdate() {
        stripPreviewWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard self?.state?.interactionInProgress != true else { return }
            self?.updateStripPreview(countForDiagnostics: true)
        }
        stripPreviewWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// Composite the live editor state and hand it to the recent strip's tile
    /// for the open file. No-op unless the recent strip is showing a file we
    /// can match by URL. The render runs off the main thread (now that
    /// `render()` is thread-safe) and the tile is updated back on main — so the
    /// ~120ms composite never hitches the UI.
    /// `countForDiagnostics` marks the EDIT-driven path (the debounced
    /// observation): only those renders move `debugStripPreviewRenderCount`.
    /// The strip also re-applies content whenever the library folder changes
    /// under it — FSEvents is recursive and the folder is shared, so another
    /// process (or another Sealshot session) touching the library mid-test
    /// used to land here and read as a phantom drag render.
    private func updateStripPreview(countForDiagnostics: Bool = false) {
        guard currentTab == .recent,
              let state = state,
              let url = state.sourceURL else { return }
        if countForDiagnostics { debugStripPreviewRenderCount += 1 }
        // Snapshot the render inputs on the main thread, render off it.
        // displayBase (not sourceImage): the preview must show the ACTIVE
        // base — the Remove Background cutout or the enhanced bitmap — with
        // the background fill, exactly like the saved composite.
        let base = state.displayBase
        let scale = state.displayScale
        let annotations = state.annotations
        let crop = state.croppedRect
        let focus = state.focusRect
        let assets = state.decodedImageAssets()
        let fill = state.backgroundFill
        stripPreviewRenderQueue.async { [weak self] in
            let composite = render(image: base, annotations: annotations, crop: crop,
                                   scale: scale, focus: focus, assets: assets,
                                   backgroundFill: fill)
            DispatchQueue.main.async {
                guard let self, self.state?.sourceURL == url else { return }
                self.recentStrip.updateThumbnail(for: url, image: composite)
            }
        }
    }

    // MARK: - Canvas scroll styling

    private func styleCanvasScrollAsCard(_ scroll: EditorCanvasScrollView) {
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 8
        scroll.layer?.masksToBounds = false
        scroll.layer?.shadowOpacity = 0.15
        scroll.layer?.shadowOffset = CGSize(width: 0, height: -2)
        scroll.layer?.shadowRadius = 12
        scroll.layer?.shadowColor = NSColor.black.cgColor
        scroll.contentView.wantsLayer = true
        scroll.contentView.layer?.cornerRadius = 8
        scroll.contentView.layer?.masksToBounds = true
    }

    // MARK: - Chrome overlay

    /// Create (or rebind) the selection chrome overlay, ensure it is a subview of
    /// `host` ABOVE `scroll`, and (re)pin its edges to the host view. Call this
    /// each time a new scroll view is installed in the host so z-order is correct
    /// and the overlay is bound to the current state + canvas + scroll.
    ///
    /// On rebind the overlay is NOT removed from its superview — re-adding an
    /// already-present subview only reorders z-order and KEEPS its constraints to
    /// `host` active, so the overlay frame survives image swaps.
    private func installChromeOverlay(state: EditorState,
                                      canvas: EditorCanvasView,
                                      scroll: EditorCanvasScrollView,
                                      host: NSView) {
        if let existing = chromeOverlay {
            existing.rebind(state: state, canvas: canvas, scroll: scroll)
            // Re-raise above the (possibly new) scroll view without removing from superview,
            // which would destroy the constraints. Re-adding an already-present view only
            // reorders z-order and preserves its Auto Layout constraints to `host`.
            host.addSubview(existing, positioned: .above, relativeTo: scroll)
        } else {
            let overlay = SelectionChromeOverlay(state: state, canvas: canvas, scroll: scroll)
            host.addSubview(overlay, positioned: .above, relativeTo: scroll)
            // Pin to `host` (not `scroll`): host persists across image swaps, so
            // these constraints remain valid after the scroll view is replaced.
            NSLayoutConstraint.activate([
                overlay.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                overlay.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                overlay.topAnchor.constraint(equalTo: host.topAnchor),
                overlay.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            ])
            chromeOverlay = overlay
        }
    }

    // MARK: - Bottom tab

    /// Content changed (new capture, delete, restore): reconcile both strips
    /// in place. Cheap when nothing changed for a given folder. The visible
    /// strip updates via diff — no rebuild, no thumbnail reshuffle.
    /// The open capture's file moved on disk (scratch capture kept into the
    /// Library). Re-point the session at the new URL in place: the canvas,
    /// zoom, scroll, and undo state all stay exactly as they are — only the
    /// URL, the title, and the strip's idea of "the open file" change.
    ///
    /// A PLAYING video is re-pointed through `playingVideoURL`, not
    /// `sourceURL`: the video plays in an overlay over whatever document is
    /// open, so assigning it to `sourceURL` would rename the image underneath
    /// it and leave the player's own bookkeeping pointing at a path that no
    /// longer exists.
    func notePresentedFileMoved(to url: URL) {
        if playingVideoURL != nil {
            playingVideoURL = url
            state?.playingVideoURL = url
            // The post-recording summary/tag pass is skipped for scratch
            // recordings (minutes of frame OCR on a file that may be swept
            // away). Keeping it is the moment that work becomes worthwhile.
            VideoMetadataCoordinator.shared.ensure(for: url)
        } else {
            state?.sourceURL = url
        }
        window?.title = url.lastPathComponent
        refreshRecentStrip()
        // `selectedURL` is the OPEN item, distinct from the selection set that
        // `selectAsClicked` paints: only assigning it arms the strip's
        // reveal-and-scroll. Without this the kept capture was highlighted at
        // whatever position it landed, often off the right-hand end of a strip
        // the user then had to scroll by hand to find the thing they just filed.
        // Order matters: refresh first so the tile exists to scroll to, and the
        // reveal window keeps re-asserting for ~1.2s while async refreshes
        // rebuild tiles underneath it.
        recentStrip.selectedURL = url
        recentStrip.selectAsClicked(url)
    }

    /// Drop the highlight in both strips — the canvas is about to show a file
    /// neither strip lists (a scratch capture).
    func clearStripSelection() {
        recentStrip.clearSelection()
        deletedStrip?.clearSelection()
    }

    func refreshRecentStrip() {
        recentStrip.refresh()
        deletedStrip?.refresh()
        updateDeletedTabAvailability()
    }

    /// Apply the All/Images/Videos filter to both strips and remember it.
    /// New strips read the persisted value on creation, so this only needs to
    /// update the ones that already exist.
    private func applyMediaFilter(_ filter: StripMediaFilter) {
        mediaFilter = filter
        StripMediaFilterPreference.store(filter)
        recentStrip.mediaFilter = filter
        deletedStrip?.mediaFilter = filter
    }

    /// Show the strip for `tab`, building it on first visit (ensureStrip)
    /// and refreshing its content. Called from init, the meta-row's
    /// onTabChange callback, and the restore / permanent-delete handlers
    /// that switch tabs.
    private func mountStrip(for tab: BottomTab) {
        guard let wrapper = stripContainer else { return }
        let strip = ensureStrip(for: tab)
        for view in wrapper.arrangedSubviews where view !== strip {
            view.isHidden = true
        }
        strip.isHidden = false
        // Tab switches no longer rebuild the strip, so the old implicit
        // selection reset has to be explicit.
        strip.clearSelection()
        strip.refresh()
        ensureStripFolderWatcher()
        // Re-highlight the currently-open capture when it belongs to the tab
        // being shown, so a Recent↔Deleted round-trip doesn't drop the strip
        // selection while the canvas keeps showing that image. A deleted
        // (read-only) file lives in the Deleted strip; a live one in Recent.
        if let open = state?.sourceURL,
           (tab == .deleted) == (state?.isReadOnly == true) {
            strip.selectAsClicked(open)
        }
    }

    /// Build each strip at most once; afterwards switching only toggles
    /// visibility (NSStackView drops hidden arranged subviews from layout).
    private func ensureStrip(for tab: BottomTab) -> RecentStripView {
        switch tab {
        case .recent:
            if recentStrip.superview == nil {
                // Placeholder from init hasn't been wired up yet — build the
                // real strip (makeRecentStrip replaces self.recentStrip).
                _ = makeRecentStrip()
                stripContainer?.addArrangedSubview(recentStrip)
            }
            return recentStrip
        case .deleted:
            if let deletedStrip { return deletedStrip }
            let strip = makeDeletedStrip()
            deletedStrip = strip
            stripContainer?.addArrangedSubview(strip)
            return strip
        }
    }

    private func ensureStripFolderWatcher() {
        guard stripFolderWatcher == nil else { return }
        let watcher = FolderWatcher()
        watcher.onChange = { [weak self] in
            guard let self else { return }
            self.recentStrip.refresh()
            self.deletedStrip?.refresh()
            self.reconcileOpenFileExistence()
            self.updateDeletedTabAvailability()
        }
        watcher.watch(config.saveFolder)
        stripFolderWatcher = watcher
    }

    /// React immediately when Settings changes the save location — otherwise
    /// the strips (folder captured at build), both FSEvents watchers (armed on
    /// the old folder), and the Library keep showing the old location until
    /// relaunch. One-shot observation, re-armed after each change.
    private func observeSaveFolder() {
        withObservationTracking {
            _ = config.saveFolder
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.handleSaveFolderChanged()
                self?.observeSaveFolder()
            }
        }
    }

    private func handleSaveFolderChanged() {
        let folder = config.saveFolder
        stripFolderWatcher?.watch(folder)     // no-op when unchanged
        libraryFolderWatcher?.watch(folder)
        recentStrip.updateFolder(folder)
        deletedStrip?.updateFolder(folder.appendingPathComponent(
            SealDeleter.deletedSubfolderName, isDirectory: true))
        libraryViewModel?.reload()
    }

    /// When the open capture's `.seal` disappears from disk — deleted from the
    /// Library, externally, or any path that doesn't route through the strip's
    /// delete (which swaps the open file itself) — switch to a remaining
    /// capture, or the empty editor if none are left. No-op for an unsaved
    /// scratch canvas (no `sourceURL`) and for files that still exist (e.g. a
    /// read-only deleted capture being viewed, or the editor's own autosave).
    private func reconcileOpenFileExistence() {
        // A video playing in the canvas is the current view (an overlay above the
        // hidden image state, whose `sourceURL` is stale). If that underlying
        // image is gone — e.g. it was just deleted and the delete flow switched
        // to a VIDEO neighbor — do NOT yank a replacement image in over the
        // video; that view was chosen deliberately.
        guard videoOverlay == nil else { return }
        guard let open = state?.sourceURL,
              !FileManager.default.fileExists(atPath: open.path) else { return }
        // Clear first so the swapped-in file's autoSaveIfDirty can't reincarnate
        // the deleted capture (mirrors performBulkDelete).
        state?.annotations = []
        state?.croppedRect = nil; state?.contentClip = nil
        // Opening the neighbor routes through presentFile, which forces the
        // editor tab. If the user is in the Library (e.g. they just deleted the
        // open file there), don't yank them to the editor — reconcile its open
        // file in the background and restore the tab they were on.
        let tabBefore = currentTabSelection
        if let next = findRecentCaptures(in: config.saveFolder, coveringDays: 7).first {
            onRecentClickStored(next)
        } else {
            onAllCapturesDeleted?()
        }
        if tabBefore != .editor { selectTab(tabBefore) }
    }

    /// The draggable bar between the meta row and the strip. Live-resizes the
    /// strip (and scales its thumbnails); persists on mouse-up.
    private func makeStripResizeHandle() -> StripResizeHandle {
        let handle = StripResizeHandle()
        handle.currentHeight = { [weak self] in
            self?.stripHeightConstraint?.constant ?? StripHeightPreference.defaultHeight
        }
        handle.onDrag = { [weak self] proposed in self?.applyStripHeight(proposed) }
        handle.onCommit = { [weak self] in
            guard let self else { return }
            StripHeightPreference.store(self.stripHeight)
        }
        return handle
    }

    /// Toggle handler for the meta-row chevron and ⌥⌘S. Flips the collapsed
    /// state and persists it. No-op in the empty editor, which always shows
    /// the strip.
    private func toggleStripHidden() {
        guard state != nil else { return }
        applyStripHidden(!stripHidden, persist: true)
    }

    /// Collapse or show the recent strip and its drag handle, handing the freed
    /// vertical space to the canvas. NSStackView drops hidden arranged subviews
    /// from layout, so the dock shrinks to just the meta row. The strip-height
    /// constraint is left untouched, so showing again restores the same height.
    private func applyStripHidden(_ hidden: Bool, persist: Bool) {
        stripHidden = hidden
        stripContainer?.isHidden = hidden
        stripResizeHandle?.isHidden = hidden
        metaRow?.setStripHidden(hidden)
        if persist { StripVisibilityPreference.store(hidden) }
    }

    /// Clamp `height`, drive the strip wrapper constraint, and live-scale the
    /// mounted strip's thumbnails. Used during a drag (not yet persisted).
    private func applyStripHeight(_ height: CGFloat) {
        let clamped = StripHeightPreference.clamp(height)
        stripHeight = clamped
        stripHeightConstraint?.constant = clamped
        recentStrip.setThumbHeight(StripHeightPreference.thumbHeight(forStripHeight: clamped))
        deletedStrip?.setThumbHeight(StripHeightPreference.thumbHeight(forStripHeight: clamped))
    }

    private func makeRecentStrip() -> RecentStripView {
        let strip = RecentStripView(
            mode: .recent,
            folder: config.saveFolder,
            daysBack: 7,
            thumbHeight: StripHeightPreference.thumbHeight(forStripHeight: stripHeight)
        ) { [weak self] url in
            self?.openFromStrip(url)
        }
        strip.onStripInteraction = { [weak self, weak strip] in
            self?.editorStripFocused = true
            self?.focusedStrip = strip
        }
        strip.onDelete = { [weak self] url in self?.handleDelete(url) }
        strip.onBulkDelete = { [weak self] urls in self?.handleBulkDelete(urls) }
        strip.onShowInLibrary = { [weak self] url in self?.showInLibrary(url) }
        // Tiles land asynchronously now, so the synchronous updateStripPreview
        // below would no-op on first build. Re-mirror whenever content lands.
        strip.onContentApplied = { [weak self] in self?.updateStripPreview() }
        strip.onPlayVideo = { [weak self] url, autoPlay in self?.playVideoInCanvas(url: url, autoPlay: autoPlay) }
        strip.onImportFiles = { [weak self] urls in self?.onImportFilesRequested?(urls, false) }
        strip.selectedURL = state?.sourceURL
        recentStrip = strip
        // Mirror any unsaved edits onto the freshly built tile immediately,
        // so a remount (tab switch, delete/restore) doesn't briefly show the
        // last-saved image for the open file.
        updateStripPreview()
        return strip
    }

    private func makeDeletedStrip() -> RecentStripView {
        let deletedFolder = config.saveFolder.appendingPathComponent(
            SealDeleter.deletedSubfolderName, isDirectory: true
        )
        let strip = RecentStripView(
            mode: .deleted,
            folder: deletedFolder,
            daysBack: 30,
            thumbHeight: StripHeightPreference.thumbHeight(forStripHeight: stripHeight)
        ) { [weak self] url in
            // Click in .deleted mode opens the file in the editor for
            // read-only viewing. EditorController.presentFile detects
            // the Deleted folder and sets state.isReadOnly = true.
            self?.openFromStrip(url)
        }
        strip.onStripInteraction = { [weak self, weak strip] in
            self?.editorStripFocused = true
            self?.focusedStrip = strip
        }
        strip.onRestore = { [weak self] url in self?.handleRestore(url) }
        strip.onBulkRestore = { [weak self] urls in self?.handleBulkRestore(urls) }
        strip.onPermanentDelete = { [weak self] url in self?.handlePermanentDelete(url) }
        strip.onBulkPermanentDelete = { [weak self] urls in self?.handleBulkPermanentDelete(urls) }
        strip.onShowInLibrary = { [weak self] url in self?.showInLibrary(url) }
        strip.onPlayVideo = { [weak self] url, autoPlay in self?.playVideoInCanvas(url: url, autoPlay: autoPlay) }
        return strip
    }

    /// Routes a recent-strip click through to the editor.
    private func openFromStrip(_ url: URL) {
        onRecentClickStored(url)
    }

    /// Switch to the Library tab and highlight `url` there (the strip's
    /// "Show in Library" action). selectTab lazily builds + reloads the model;
    /// reveal moves it to the section that contains the file and selects it,
    /// which scrolls the Library to the item.
    private func showInLibrary(_ url: URL) {
        selectTab(.library)
        libraryViewModel?.reveal(url)
    }

    /// Post-import routing: same behavior as the strip's "Show in Library".
    func revealInLibrary(_ url: URL) { showInLibrary(url) }

    /// Post-import reveal for drops that ORIGINATE in the Library: stay on
    /// the Library tab, select the whole imported batch, and ring-highlight
    /// it (same marks as delete/restore) so the landing spot is obvious.
    func revealImportedInLibrary(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        selectTab(.library)
        libraryViewModel?.reveal(urls)
        ActivityHighlightStore.shared.mark(urls)
    }

    /// Wire a canvas's empty-area right-click menu to the same capture actions
    /// the strip thumbnail offers (Show in Finder / Show in Library / Delete).
    private func wireCaptureMenu(on canvas: EditorCanvasView) {
        canvas.onCopyCapture = { [weak self] in self?.copyCaptureImage() }
        canvas.onShowCaptureInFinder = { url in
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        canvas.onShowCaptureInLibrary = { [weak self] url in self?.showInLibrary(url) }
        canvas.onAddCaptureToLibrary = { [weak self] url in self?.onAddToLibraryRequested?(url) }
        canvas.onDeleteCapture = { [weak self] url in self?.handleDelete(url) }
        // Exports reuse the same entry points as the File menu and the strip,
        // so the open capture exports identically however the user asks.
        canvas.onExportCapture = { [weak self] _, kind in
            guard let self else { return }
            switch kind {
            case .image: self.exportCurrent()
            case .video: self.exportCurrentAsVideo()
            case .package: self.exportAsPackage()
            }
        }
        // Evaluated when the menu opens, so it always reflects the capture that
        // is open right now. A playing video counts even before its manifest is
        // consulted.
        canvas.isVideoCapture = { [weak self] in
            guard let self else { return false }
            if self.playingVideoURL != nil { return true }
            guard let url = self.state?.sourceURL else { return false }
            return self.isVideoPackage(url)
                || Self.exportVideoExtensions.contains(url.pathExtension.lowercased())
        }
        canvas.onLiveTextEmpty = { [weak self] in
            guard let host = self?.canvasHost else { return }
            EditorToastView.show("No text found", in: host)
        }
        canvas.onLiveTextRecognitionChanged = { [weak self] label in
            self?.showLiveTextProgress(label)
        }
        canvas.onImageTextSearchStatusChanged = { [weak self] status in
            self?.sidebar?.updateImageTextSearch(status: status)
        }
        canvas.onRevertToOriginal = { [weak self] in self?.revertToOriginal() }
        canvas.onCommitCrop = { [weak self] in self?.commitCrop() }
        canvas.onAnnotationSettled = { [weak self] in self?.expandCanvasToFitAnnotations() }
        canvas.onSummarizeCapture = { [weak self] in self?.runAITextAction(.summarize) }
        canvas.onChatAboutCapture = { [weak self] in self?.runCaptureChat() }
        // Clicking the canvas makes it the active surface for ⌘A again (after a
        // strip click had pointed ⌘A at the tiles).
        canvas.onUserMouseDown = { [weak self] in self?.editorStripFocused = false }
    }

    // MARK: - On-device AI text actions (Summarize / Extract)

    enum AITextActionKind { case summarize, extract }

    /// OCR the current image, run the on-device Foundation Model, and show the
    /// result in a copyable sheet. Gated on availability (the menu items only
    /// appear when this is possible), so the body assumes macOS 26 is reachable.
    func runAITextAction(_ kind: AITextActionKind) {
        guard AIAvailability.isFoundationModelAvailable, AIFeaturePreference().enabled else { return }
        // A video summary samples frames across the whole clip rather than
        // OCR'ing the single static source image.
        if kind == .summarize, canvasVideoPlayer != nil {
            summarizeCanvasVideo()
            return
        }
        guard let state else { return }
        // OCR the focus area when one is set, else the crop, else the whole
        // image (resolved to source-image space).
        let rect = EditorState.aiOCRRect(
            sourceSize: CGSize(width: state.sourceImage.width, height: state.sourceImage.height),
            croppedRect: state.croppedRect, focusRect: state.focusRect)
        let image = state.sourceImage.cropping(to: rect.integral) ?? state.sourceImage
        Task { @MainActor [weak self] in
            let layout = try? await TextRecognizer().recognize(image)
            let ocrText = layout?.lines.map(\.text).joined(separator: "\n") ?? ""
            guard !ocrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                self?.presentAIError("This capture has no readable text.")
                return
            }
            var result: String?
            if #available(macOS 26, *) {
                let actions = FoundationTextActions()
                if kind == .summarize {
                    if case let .text(t) = await actions.summarize(ocrText: ocrText) { result = t }
                } else {
                    result = await actions.extract(ocrText: ocrText)
                }
            }
            guard let text = result, !text.isEmpty else {
                self?.presentAIError("Apple Intelligence couldn't produce a result. Try again.")
                return
            }
            self?.presentAIResult(title: kind == .summarize ? "Summary" : "Extracted Text", body: text)
        }
    }

    private func presentAIResult(title: String, body: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 440, height: 240))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let textView = NSTextView(frame: scroll.bounds)
        textView.isEditable = false
        textView.isRichText = false
        textView.string = body
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 6, height: 6)
        scroll.documentView = textView
        alert.accessoryView = scroll
        alert.addButton(withTitle: "Copy")
        alert.addButton(withTitle: "Close")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(body, forType: .string)
            }
        }
    }

    private func presentAIError(_ message: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Apple Intelligence"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }

    /// A recent-strip click couldn't open its capture (unreadable / written by a
    /// newer build). Undo the strip's optimistic selection so the still-open
    /// file stays the only highlighted tile, and tell the user why the click did
    /// nothing (otherwise it's a silent no-op that also looked like two tiles
    /// were selected).
    func presentOpenFailure(url: URL, error: Error) {
        recentStrip.restoreSelectionToOpenFile()
        let name = url.deletingPathExtension().lastPathComponent
        let newerBuild: Bool
        if case AnnotationCodecError.unsupportedVersion = error { newerBuild = true }
        else { newerBuild = false }
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Couldn't open \(name)"
        alert.informativeText = newerBuild
            ? "This capture was created by a newer version of Sealshot and can't be opened here."
            : "This capture couldn't be read — it may be incomplete or damaged."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }

    private func presentStructuredError(_ message: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Extract Structured Data"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }

    private var chatSheetWindow: NSWindow?

    /// Open the "Ask about this Capture" chat: OCR the current image, build a
    /// model-backed chat engine (with a library-search tool), and present it as
    /// a sheet. Gated — the menu item only shows when the model is available.
    func runCaptureChat() {
        guard let state, chatSheetWindow == nil, let window,
              AIAvailability.isFoundationModelAvailable, AIFeaturePreference().enabled else { return }
        let image: CGImage
        if let crop = state.croppedRect, let cropped = state.sourceImage.cropping(to: crop) {
            image = cropped
        } else {
            image = state.sourceImage
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let layout = try? await TextRecognizer().recognize(image)
            let ocrText = layout?.lines.map(\.text).joined(separator: "\n") ?? ""
            guard self.chatSheetWindow == nil, #available(macOS 26, *) else { return }
            let engine = FoundationCaptureChatEngine(ocrText: ocrText, saveFolder: self.config.saveFolder)
            let viewModel = CaptureChatViewModel(engine: engine)
            let hosting = NSHostingController(
                rootView: CaptureChatView(viewModel: viewModel,
                                          onClose: { [weak self] in self?.dismissChatSheet() }))
            let sheet = NSWindow(contentViewController: hosting)
            sheet.styleMask = [.titled]
            sheet.isReleasedWhenClosed = false
            self.chatSheetWindow = sheet
            window.beginSheet(sheet, completionHandler: nil)
        }
    }

    private func dismissChatSheet() {
        guard let sheet = chatSheetWindow, let window else { return }
        window.endSheet(sheet)
        chatSheetWindow = nil
    }

    // MARK: - Structured Data Extraction

    /// Extract structured data (tables, detected data, Markdown) from the current
    /// image using the on-device pipeline. On-demand persisted: re-running on the
    /// same focus area loads the cached result instantly; a different focus area
    /// re-extracts. No Apple Intelligence required (FM only polishes the Markdown).
    func runStructuredExtract() {
        guard let state, let url = currentItemURL else { return }
        let rect = EditorState.aiOCRRect(
            sourceSize: CGSize(width: state.sourceImage.width, height: state.sourceImage.height),
            croppedRect: state.croppedRect, focusRect: state.focusRect)
        let image = state.sourceImage.cropping(to: rect.integral) ?? state.sourceImage
        let focusRect = RectDTO(rect.integral)

        // Cache hit (same focus area, current version) → present instantly.
        if let cached = (try? SealMetadataStore.readManifest(at: url))?.extraction,
           cached.matches(focusRect: focusRect) {
            presentExtractionResult(record: cached, image: image, focusRect: focusRect, url: url)
            return
        }
        extractAndPresent(image: image, focusRect: focusRect, url: url)
    }

    /// Run the full pipeline (staged progress + cancel), persist, then present.
    private func extractAndPresent(image: CGImage, focusRect: RectDTO, url: URL) {
        runWithCanvasProgress(label: ExtractionStage.reading.label, work: { [weak self] progress -> ExtractionRecord? in
            let result = await StructuredExtractionCoordinator.extract(image: image) { frac, label in
                progress.fraction = frac
                progress.label = label
            }
            // Cancelled runs return a PARTIAL result — bail before it can
            // surface an error alert, keep composing, or poison the cache.
            if Task.isCancelled { return nil }
            if case .failed(let reason) = result.status {
                self?.presentStructuredError(reason); return nil
            }
            if StructuredExtractionResult.isEmpty(result.items) {
                self?.presentStructuredError("No structured data found in this capture."); return nil
            }
            progress.fraction = ExtractionStage.composing.fraction
            progress.label = ExtractionStage.composing.label
            let layout = try? await TextRecognizer().recognize(image)
            let ocrText = layout?.lines.map(\.text).joined(separator: "\n") ?? ""
            let md = await MarkdownExtractionCoordinator().markdown(items: result.items, ocrText: ocrText)
            // Cancel during compose: don't persist a half-built record — the
            // next Extract would "instantly finish" from the poisoned cache.
            if Task.isCancelled { return nil }
            let record = ExtractionRecord(items: result.items, markdown: md,
                                          focusRect: focusRect, version: ExtractionRecord.currentVersion)
            try? SealMetadataStore.setExtraction(record, to: url)
            return record
        }, onResult: { [weak self] record in
            self?.presentExtractionResult(record: record, image: image, focusRect: focusRect, url: url)
            self?.offerGLiNERDownloadIfNeeded()
        })
    }

    /// Re-run the pipeline for the same focus area, replacing the cached record
    /// (the window's "Re-extract" action — covers image/annotation edits).
    func reExtract(image: CGImage, focusRect: RectDTO, url: URL) {
        extractAndPresent(image: image, focusRect: focusRect, url: url)
    }

    private func presentExtractionResult(record: ExtractionRecord, image: CGImage,
                                         focusRect: RectDTO, url: URL) {
        ExtractionResultWindowController(
            record: record,
            exportBaseName: CaptureDisplayName.resolve(for: url),
            onReExtract: { [weak self] in
                self?.reExtract(image: image, focusRect: focusRect, url: url)
            }).present()
    }

    /// Offers a one-time download prompt for the GLiNER on-device model when
    /// running on Apple Silicon and the model is not yet downloaded. Shows the
    /// alert AFTER the results sheet has been presented (non-blocking). If the
    /// model is already ready, downloading, or verifying, or the device is not
    /// Apple Silicon, this is a no-op.
    private func offerGLiNERDownloadIfNeeded() {
        guard RedactionEngineLoader.isAppleSilicon else { return }
        let modelState = RedactionModelManager.shared.state
        switch modelState {
        case .notDownloaded, .failed: break
        default: return
        }
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Download Enhanced Extraction Model?"
        alert.informativeText = "Download the on-device model (~400 MB) for richer extraction (contacts, organizations, form fields)?"
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Not Now")
        alert.alertStyle = .informational
        DispatchQueue.main.async {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn {
                    RedactionModelManager.shared.start()
                }
            }
        }
    }

    // MARK: - Arrow-key navigation

    /// Route a plain arrow key to whichever list the active tab shows. Editor
    /// tab → recent strip (← / → open the neighbor; ↑ / ↓ ignored, the strip is
    /// a single row). Library tab → grid/list selection (all four arrows).
    /// Returns true if the key was consumed.
    private func handleArrowKey(_ keyCode: UInt16) -> Bool {
        switch currentTabSelection {
        case .editor:
            switch keyCode {
            case 123: return recentStrip.selectAdjacent(offset: -1)   // left
            case 124: return recentStrip.selectAdjacent(offset: +1)   // right
            default:  return false                                    // up/down
            }
        case .library:
            return libraryViewModel?.moveSelection(keyCode) ?? false
        case .settings:
            return false
        }
    }

    /// Route a ⌘+arrow to the list extreme. Editor tab → recent strip (⌘← first,
    /// ⌘→ last; ↑/↓ ignored, the strip is a single row). Library tab → grid
    /// row/column extreme (or list first/last for ↑/↓). Returns true if consumed.
    private func handleCommandArrowKey(_ keyCode: UInt16) -> Bool {
        switch currentTabSelection {
        case .editor:
            switch keyCode {
            case 123: return recentStrip.selectExtreme(toEnd: false)   // first
            case 124: return recentStrip.selectExtreme(toEnd: true)    // last
            default:  return false                                     // up/down
            }
        case .library:
            return libraryViewModel?.moveSelectionToExtreme(keyCode) ?? false
        case .settings:
            return false
        }
    }

    /// Return/Enter opens the highlighted Library item. The recent strip opens
    /// on arrow already, so the Editor tab ignores it.
    private func handleActivateSelection() -> Bool {
        guard currentTabSelection == .library else { return false }
        return libraryViewModel?.openSelected() ?? false
    }

    private func handleSpaceKey() -> Bool {
        guard currentTabSelection == .library else { return false }
        // Video preview open: Space toggles playback (Finder Quick Look
        // behavior). Image previews and closed states keep the open/close.
        if libraryViewModel?.quickLookOpen == true,
           libraryViewModel?.quickLookLoader?.togglePlayPause() == true {
            return true
        }
        libraryViewModel?.toggleQuickLook()
        return true
    }

    private func handleEscapePreview() -> Bool {
        guard currentTabSelection == .library,
              libraryViewModel?.quickLookOpen == true else { return false }
        libraryViewModel?.closeQuickLook()
        return true
    }

    /// ⌘⌫ routes to the active tab (like the arrow/return keys). Library tab →
    /// delete the grid selection in place (move to Trash), staying in the
    /// Library — never switching to the editor or opening a neighbor. Trash
    /// section is left to the toolbar's confirmed "Delete Forever". Editor tab →
    /// move the open file to Trash and swap to the neighbor (prior behavior).
    private func handleDeleteShortcut() {
        switch currentTabSelection {
        case .library:
            guard let vm = libraryViewModel, !vm.selection.isEmpty, !vm.section.isTrash else { return }
            vm.delete(Array(vm.selection))
        case .editor:
            guard let state, let url = state.sourceURL, !state.isReadOnly else { return }
            handleDelete(url)
        case .settings:
            break
        }
    }

    // MARK: - Tool bar (header row in the editor content column)

    /// Build (or rebuild) the tool bar into `toolsHost` (the first row of the
    /// editor header, built in init). On empty→loaded the bar view is swapped
    /// in place.
    private func installToolsBar(empty: Bool) {
        toolbarBuilder.onSelectTool = { [weak self] tool in
            guard let self else { return }
            // Picking any tool dismisses a Smart Redact scan/review — including
            // the review phase the builder's own deactivation can't see.
            // (userSelectedTool below closes the Enhance panel the same way.)
            self.cancelRedactionIfActive()
            // Always exits Info, even when re-selecting the already-active tool.
            self.state?.userSelectedTool(tool)
            self.toolbarBuilder.setSelectedTool(tool)
            os_log("editor tool → %{public}@", log: log, type: .info, String(describing: tool))
        }
        toolbarBuilder.onCopyAll = { [weak self] in self?.handleCopy() }
        toolbarBuilder.onExportPNG = { [weak self] in self?.exportCurrent() }
        toolbarBuilder.onUndo = { [weak self] in self?.handleUndo() }
        toolbarBuilder.onRedo = { [weak self] in self?.handleRedo() }
        toolbarBuilder.onFindInImage = { [weak self] in _ = self?.showImageTextSearch() }
        toolbarBuilder.onCapture = { [weak self] in self?.onCaptureRequested?() }
        toolbarBuilder.onCaptureWindow = { [weak self] in self?.onWindowCaptureRequested?() }
        toolbarBuilder.onCaptureUnified = { [weak self] in self?.onUnifiedCaptureRequested?() }
        toolbarBuilder.onCaptureDelayed = { [weak self] in self?.onDelayedCaptureRequested?() }
        toolbarBuilder.onCaptureScroll = { [weak self] in self?.onScrollCaptureRequested?() }
        toolbarBuilder.onCaptureLive = { [weak self] in self?.onLiveCaptureRequested?() }
        toolbarBuilder.onCaptureFullscreen = { [weak self] in self?.onFullscreenCaptureRequested?(nil) }
        toolbarBuilder.onRecordScreen = { [weak self] in self?.onRecordScreenRequested?(nil) }
        toolbarBuilder.onRecordSelection = { [weak self] in self?.onRecordSelectionRequested?() }
        // The 'i' pill shows Info like a tool button: clicking it when Info is
        // already on screen is a no-op (the menu's Show/Hide item still toggles).
        // Info and Smart Redact are mutually exclusive, so opening Info cancels an
        // active redaction scan/review.
        toolbarBuilder.onToggleInfo = { [weak self] in
            self?.cancelRedactionIfActive()
            if self?.state?.showsImageTextSearchPanel == true {
                self?.state?.userSelectedTool(.select)
            }
            self?.state?.showInfoPanel()
        }
        toolbarBuilder.onEnhanceTapped = { [weak self] in
            guard let self, let state = self.state else { return }
            // Re-tapping the already-active pill keeps Enhance open — it must
            // not deselect back to the Select tool (closing is done by picking
            // a tool or another AI pill).
            guard !state.enhanceEditing else { return }
            // The AI pills are mutually exclusive: opening Enhance dismisses a
            // Smart Redact scan/review instead of yielding to it. Both this and
            // exitLiveTextIfActive run before the flip — userSelectedTool
            // resets enhanceEditing, which would invert a naive toggle.
            self.cancelRedactionIfActive()
            self.exitLiveTextIfActive()
            self.deselectToolForAIAction()
            state.sidebarPanelMode = .properties
            state.enhanceEditing = true
            self.toolbarBuilder.setEnhanceActive(true)
        }
        toolbarBuilder.onRemoveBackgroundTapped = { [weak self] in
            // A one-shot action: leave the current tool and sidebar untouched.
            self?.removeBackground()
        }
        toolbarBuilder.onSmartRedact = { [weak self] in
            self?.exitLiveTextIfActive()
            self?.deselectToolForAIAction()
            // Close Enhance here, not just in the scan core, so the panel drops
            // even on the paths that defer the scan (first-use consent sheet).
            self?.state?.enhanceEditing = false
            // Smart Redact and file Info ('i') are mutually exclusive — leave
            // Info so its pill can't stay lit alongside the Redact pill (the
            // redaction panel takes the sidebar regardless of this mode).
            self?.state?.sidebarPanelMode = .properties
            self?.onSmartRedact?()
        }
        toolbarBuilder.onSmartRedactCancel = { [weak self] in self?.onSmartRedactCancel?() }
        toolbarBuilder.onSummarize = { [weak self] in self?.runAITextAction(.summarize) }
        toolbarBuilder.onExtractStructuredData = { [weak self] in
            guard let self else { return }
            // Extract opens its own window and leaves the current tool/sidebar as
            // they were. It still dismisses the other panel-owning AI modes
            // (Live Text / Smart Redact / Enhance) that would otherwise linger.
            self.exitLiveTextIfActive()
            self.cancelRedactionIfActive()
            self.state?.enhanceEditing = false
            self.state?.sidebarPanelMode = .properties
            self.runStructuredExtract()
        }
        toolbarBuilder.onNewCanvas = { [weak self] in self?.onNewCanvasRequested?() }
        toolbarBuilder.onNewFromClipboard = { [weak self] in self?.onNewFromClipboardRequested?() }
        toolbarBuilder.onImportToLibrary = { [weak self] in self?.onImportRequested?() }
        toolbarBuilder.onInsertImage = { [weak self] in self?.presentInsertImagePanel() }
        toolbarBuilder.hasCanvasProvider = { [weak self] in self?.state != nil }

        guard let host = toolsHost else { return }
        host.subviews.forEach { $0.removeFromSuperview() }

        // Rebuilds for a different reason (empty↔loaded) must keep whatever
        // fold the current width calls for, or the bar springs back to full
        // width and re-clamps the window.
        let bar = toolbarBuilder.makeToolbarView(empty: empty, folded: appliedToolbarFold)
        host.addSubview(bar)
        // The trailing edge is deliberately NOT required. Pinned at required
        // priority, the bar's own intrinsic width (28pt per pill, none of them
        // compressible) propagates up through the header to the window, which
        // is what made the editor un-shrinkable in the first place — and it
        // would ALSO defeat the folding, because the host could then never
        // observe a width narrower than the bar it contains. Folding needs the
        // host's width to be an input, not an output.
        //
        // At low priority the constraint still holds whenever there is room,
        // so the bar fills the header and its centring spacers work. When the
        // window is dragged narrower than the current bar, it breaks instead:
        // the bar overflows for a single layout pass, the host reports its
        // real width, a cluster folds, and the bar fits again. `clipsToBounds`
        // keeps that one frame from painting over the header.
        host.clipsToBounds = true
        // Releasing the trailing edge is not enough on its own: a stack view
        // also defends its fitting width through compression resistance (750
        // by default), and THAT is what the window's automatic minimum is
        // computed from. With it lowered, the bar can be squeezed narrower
        // than its content for the pass it takes the fold to land.
        bar.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let fill = bar.trailingAnchor.constraint(equalTo: host.trailingAnchor)
        fill.priority = .defaultLow
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            fill,
            bar.topAnchor.constraint(equalTo: host.topAnchor),
            bar.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        // The rebuilt bar knows nothing of the live session; re-assert what
        // the controller already tracks (same reason `applyReadOnly` exists).
        syncToolbarHighlights()
    }

    /// Fold or unfold toolbar clusters for the width the bar now has.
    ///
    /// Called from the host's layout pass, so it runs on every frame of a
    /// resize drag — hence the plan comparison: rebuilding the bar is cheap
    /// but not free, and rebuilding it identically 60 times a second would
    /// drop the pill under the pointer mid-click.
    private func applyToolbarFit(availableWidth: CGFloat, allowUnfold: Bool = false) {
        guard availableWidth > 0 else { return }
        // While a resize is in flight the width being negotiated wins over the
        // width the window still has. Rebuilding the bar triggers a layout
        // pass immediately, and that pass runs BEFORE the new window size is
        // applied — so without this it would look at the old, wider window and
        // undo the fold that was just made to allow the resize. Measured:
        // fold to 7 → relayout at the old 1400 → back to 1, and the window
        // lands at 894 instead of 560.
        let width = pendingResizeContentWidth ?? availableWidth
        // The meta row folds its zoom controls on the same width, for the same
        // reason — it is the other row that would otherwise set the floor.
        metaRow?.applyZoomFit(availableWidth: width, allowRestore: allowUnfold)
        // Only a resize the user ASKED for may un-fold. A layout pass may add
        // folds but never remove them: its width is an effect of the current
        // fold, so folding back for it re-raises the window's minimum, which
        // widens the next pass — a ratchet that walks the window back open
        // (measured: a drag to 560 climbing 560 → 657 → 725 and sticking).
        let fitted = EditorToolbarFit.plan(availableWidth: width,
                                           current: appliedToolbarFold)
        let plan = allowUnfold ? fitted : fitted.union(appliedToolbarFold)
        guard plan != appliedToolbarFold else { return }
        appliedToolbarFold = plan
        installToolsBar(empty: state == nil)
    }

    /// Drop out of the Live Text tool back to Select, exactly as if the user
    /// clicked the Select pill. Smart Redact / Extract / Enhance are actions
    /// whose results Live Text's overlay would sit on top of, so they exit it.
    private func exitLiveTextIfActive() {
        guard let state, state.selectedTool == .textSelect else { return }
        state.userSelectedTool(.select)
        toolbarBuilder.setSelectedTool(.select)
    }

    /// Enter/focus Find in Image. Search owns the visible mode while arming Live
    /// Text underneath, which runs its raw probe, optional auto-enhance, and
    /// final OCR. The toolbar still highlights Search alone.
    @discardableResult
    private func showImageTextSearch() -> Bool {
        guard currentTabSelection == .editor,
              let state,
              !state.isReadOnly,
              state.playingVideoURL == nil else { return false }
        cancelRedactionIfActive()
        state.enhanceEditing = false
        if state.selectedTool != .textSelect {
            state.userSelectedTool(.textSelect)
        }
        state.showImageTextSearchPanel()
        primeImageTextSearchScanStage(state)
        sidebar?.focusImageTextSearchField()
        syncToolbarHighlights()
        return true
    }

    /// When Search is entered from an already-running Live Text session, the
    /// selected tool does not transition and its observer cannot seed the scan
    /// stage. Derive the current point in that same pipeline here.
    private func primeImageTextSearchScanStage(_ state: EditorState) {
        guard let stage = imageTextSearchScanStageOnEnteringSearch(
            showingEnhanced: state.showingEnhanced,
            hasEnhancedImage: state.enhancedImage != nil,
            enhanceSessionActive: state.liveTextEnhanceRestore != nil,
            enhanceRunning: state.enhanceRunning,
            liveTextHasText: state.liveTextHasText)
        else { return }
        state.imageTextSearchScanStage = stage
    }

    /// Esc from the search field/canvas returns to the neutral Select mode.
    private func exitImageTextSearchToSelect() {
        guard let state, state.showsImageTextSearchPanel else { return }
        state.userSelectedTool(.select)
        window?.makeFirstResponder(canvas)
    }

    /// An AI action (Smart Redact, Extract, Enhance, Remove Background) is
    /// mutually exclusive with the annotation tools — clicking one deselects an
    /// armed tool so it doesn't come back when the action ends. The tool drops to
    /// the neutral Select cursor UNDERNEATH, but its pill is NOT lit: while an AI
    /// mode is active `syncToolbarHighlights` clears every tool highlight (the AI
    /// pill or 'i' owns it), so nothing "drops to a highlighted Select". Sets
    /// `selectedTool` directly rather than via `userSelectedTool` so it does NOT
    /// reset `enhanceEditing` (the Enhance toggle depends on that surviving).
    /// Live Text is itself a tool (`.textSelect`), already exclusive via the tool
    /// group, so it doesn't route through here.
    private func deselectToolForAIAction() {
        guard let state, state.selectedTool != .select else { return }
        state.selectedTool = .select
    }

    /// Cancel Smart Redact whether it's mid-scan OR sitting in the review
    /// panel (.found). The toolbar's own deactivateSmartRedact only covers the
    /// scan phase — the pill highlight is off during review — so tool clicks
    /// and the other AI pills route through here for full mutual exclusion.
    private func cancelRedactionIfActive() {
        guard let state else { return }
        switch state.redactionScan {
        case .scanning, .found: onSmartRedactCancel?()
        case .idle, .empty: break
        }
    }

    /// Copy recognized Live Text to the pasteboard and confirm on the matching
    /// sidebar button (NOT the whole-image Copy button in the toolbar). `all`
    /// first selects every line; otherwise the current drag selection is used.
    private func copyLiveText(all: Bool) {
        guard let canvas = canvas else { return }
        if all { canvas.selectAllText() }
        let text = canvas.selectedTextForCopy
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        sidebar?.flashLiveTextCopied(all: all)
    }

    /// Copy the whole composite image (base + annotations + crop/focus) to the
    /// clipboard. Backs the canvas right-click "Copy" item — always whole-image,
    /// independent of the current selection.
    private func copyCaptureImage() {
        guard let state = state else { return }
        do {
            try saver.copy(state: state)
            toolbarBuilder.flashCopied()
        } catch {
            os_log("editor copy failed: %{public}@",
                   log: log, type: .error, String(describing: error))
        }
    }

    private func handleCopy() {
        guard let state = state else { return }
        // Crop tool with an active selection: ⌘C copies the crop region.
        if state.pendingCrop != nil {
            _ = state.copyCropRegion()
            return
        }
        if state.selectedTool == .textSelect, !state.showsImageTextSearchPanel {
            copyLiveText(all: false)
            return
        }
        switch copyTarget(selectionCount: state.selectedAnnotationIDs.count) {
        case .objects:
            let selected = state.annotations.filter { state.selectedAnnotationIDs.contains($0.id) }
            AnnotationPasteboard.write(Self.clipboardPayload(for: selected, state: state))
            // Don't flash the Copy (whole-image) button — that misleads the user
            // into thinking the whole image was copied. Toast that it's objects.
            if let host = canvasHost ?? window?.contentView {
                let n = selected.count
                EditorToastView.show(n == 1 ? "Object copied" : "\(n) objects copied", in: host)
            }
        case .wholeImage:
            do {
                try saver.copy(state: state)
                toolbarBuilder.flashCopied()
            } catch {
                os_log("editor copy failed: %{public}@",
                       log: log, type: .error, String(describing: error))
            }
        }
    }

    /// Clipboard payload for `selected`: the annotations plus the bitmap
    /// bytes any `.image` members reference, so cross-document paste can
    /// re-materialize the assets.
    private static func clipboardPayload(for selected: [Annotation],
                                         state: EditorState) -> AnnotationClipboardPayload {
        var assets: [String: Data] = [:]
        for a in selected {
            if case let .image(_, assetID) = a.geometry,
               let data = state.imageAssets[assetID] { assets[assetID] = data }
        }
        return AnnotationClipboardPayload(annotations: selected, assets: assets)
    }

    /// ⌘X — only acts when annotations are selected and the canvas is the
    /// first responder (so it doesn't steal ⌘X from a text field). Returns
    /// true if consumed.
    private func handleCut() -> Bool {
        guard let state = state, let canvas = canvas, !state.isReadOnly else { return false }
        guard window?.firstResponder === canvas else { return false }
        // Crop tool with an active selection: ⌘X cuts the crop region.
        if state.pendingCrop != nil { return state.cutCropRegion() }
        guard !state.selectedAnnotationIDs.isEmpty else { return false }
        let selected = state.annotations.filter { state.selectedAnnotationIDs.contains($0.id) }
        AnnotationPasteboard.write(Self.clipboardPayload(for: selected, state: state))
        state.deleteSelected()
        return true
    }

    /// ⌘V — only acts when the canvas is the first responder. Returns true
    /// if something was pasted. Annotation payload wins; a raw image on the
    /// clipboard falls through to become an overlay on the open capture.
    private func handlePaste() -> Bool {
        guard let canvas = canvas else { return false }
        guard window?.firstResponder === canvas else { return false }
        // Whether this is the empty surface File ▸ New Canvas hands you must be
        // read BEFORE anything lands on it — a paste is exactly what stops it
        // being empty.
        let blankSurface = state.map(isBlankDrawingSurface) ?? false

        // Sealshot's OWN clipboard format (a copy from another capture) — the
        // content arrives at the size it had there, which is routinely bigger
        // than an 800×500 canvas.
        if canvas.pasteAnnotations() {
            if blankSurface {
                // No-ops when the paste already fits, so a small paste leaves
                // the canvas alone.
                expandCanvasToFitAnnotations()
            }
            let size = state?.visibleImageSize ?? .zero
            CanvasPasteDiag.note("paste: annotation payload"
                                 + " blankSurface=\(blankSurface ? 1 : 0)"
                                 + " canvasNow=\(Int(size.width))x\(Int(size.height))")
            return true
        }

        // No annotation payload: a raw image from another app becomes an
        // overlay on the open capture.
        guard let state = state, let image = NewCanvasFactory.fromClipboard() else { return false }
        let tooBig = CGFloat(image.width) > state.visibleImageSize.width
            || CGFloat(image.height) > state.visibleImageSize.height
        let grows = blankSurface && tooBig
        CanvasPasteDiag.snapshot(image: image, state: state, grew: grows)
        if grows {
            // Blank canvas, image too big for it: the canvas is a drawing
            // surface with nothing to preserve, so the IMAGE wins and the
            // surface grows to it — the same result ⇧⌘N (New from Clipboard)
            // gives. Scaling it down to a quarter of an 800×500 canvas throws
            // away the pixels the user just copied.
            state.insertImageAnnotation(image, at: nil, atNaturalSize: true)
            expandCanvasToFitAnnotations()
        } else {
            state.insertImageAnnotation(image, at: nil)
        }
        canvas.needsDisplay = true
        return true
    }

    /// Whether the document is the empty drawing surface File ▸ New Canvas
    /// hands you — nothing drawn on it, and a fully transparent base.
    ///
    /// Deliberately narrow. On a capture, the canvas IS the content and a
    /// pasted picture belongs inside it — growing a screenshot to wrap a photo
    /// in transparent margin would be nonsense — and once anything is on the
    /// surface, resizing it would move the ground under work already done.
    private func isBlankDrawingSurface(_ state: EditorState) -> Bool {
        guard !state.isReadOnly, state.annotations.isEmpty else { return false }
        return NewCanvasFactory.isBlankCanvas(state.sourceImage)
    }

    /// Move `url` into the Deleted folder. If it was the currently-open
    /// file, load the next-most-recent or close the window if Recent is
    /// now empty. Then refresh the strip. Records one undoable event.
    func handleDelete(_ url: URL) {
        handleBulkDelete([url])
    }

    /// Move every URL in `urls` to the Deleted folder and record ONE
    /// undoable event for the whole gesture (⌘Z restores the batch).
    func handleBulkDelete(_ urls: [URL]) {
        Task { @MainActor in
            let result = await performBulkDelete(urls)
            globalUndo.record(.fileEvent(.init(items: result.items, kind: .deletion,
                containedOpenFile: result.containedOpenFile, at: Date())))
            updateUndoRedoButtons()
            ActivityHighlightStore.shared.mark(result.items.map(\.trashedURL))
        }
    }

    /// Core delete machinery shared by user-initiated deletes and
    /// deletion-redo: moves files to Deleted/, handles the open-file
    /// neighbor switch, refreshes the strip. Per-URL errors are logged and
    /// swallowed — the batch continues. Recording on the deletion undo
    /// stack is the CALLER's job (redo must push, not record).
    @discardableResult
    private func performBulkDelete(
        _ urls: [URL]
    ) async -> (items: [DeletionUndoHistory.Item], containedOpenFile: Bool) {
        // The strip's CURRENT on-screen order (newest-first, media-filtered),
        // captured before the deletion refreshes it. Picking the neighbor from
        // what the user actually sees — rather than re-deriving a listing —
        // makes the post-delete selection the next visible item, not a
        // surprise pick. See `stripNeighbor` / `StripNeighborTests`.
        let beforeOrder = recentStrip.orderedURLs
        // What's actually on screen: a playing video takes precedence over the
        // open image underneath it. Deleting whichever is current must move the
        // editor on — keyed on `state.sourceURL` alone, deleting the active
        // VIDEO went unrecognized (the "random pick" bug). See `postDeletePlan`.
        let plan = postDeletePlan(deleting: Set(urls),
                                  openImage: state?.sourceURL,
                                  playingVideo: playingVideoURL,
                                  displayed: beforeOrder)

        if urls.count > 1, let window { bulkProgress.begin(total: urls.count, verb: "Deleting", in: window) }
        defer { bulkProgress.end() }

        var items: [DeletionUndoHistory.Item] = []
        for (index, url) in urls.enumerated() {
            do {
                let trashed = try SealDeleter.delete(url: url, saveFolder: config.saveFolder)
                items.append(.init(trashedURL: trashed, originalURL: url))
            } catch {
                os_log("bulk delete failed for %{public}@: %{public}@",
                       log: log, type: .error, url.path, String(describing: error))
            }
            bulkProgress.update(done: index + 1, total: urls.count, verb: "Deleting")
            // Let the run loop breathe so the bar paints and the app stays
            // responsive on big batches / slow (cloud-synced) folders.
            await Task.yield()
        }
        if plan.clearOpenImage {
            // Clear the open image's editor state so its autoSaveIfDirty can't
            // reincarnate the file we just deleted.
            self.state?.annotations = []
            self.state?.croppedRect = nil; self.state?.contentClip = nil
        }
        if plan.switchNeeded {
            // Item immediately to the right of the on-screen item (any type),
            // skipping others in this batch; falls back leftward at the right
            // end. Routed through the strip's own click so a video neighbor
            // plays and an image opens, and the tile gets selected — exactly
            // as if the user had clicked the next tile.
            if let next = plan.switchTo {
                recentStrip.handlePlainClick(url: next)
            } else {
                // Nothing left to show — swap to the empty editor rather
                // than closing (which would leave the app with no window).
                onAllCapturesDeleted?()
                return (items, plan.clearOpenImage)
            }
        }
        refreshRecentStrip()
        return (items, plan.clearOpenImage)
    }

    /// Restore every URL in `urls` from Deleted back into the save folder.
    /// Switch the bottom tab to Recent and open the first-restored file
    /// in the editor. Per-URL errors are logged and swallowed.
    func handleBulkRestore(_ urls: [URL]) {
        Task { @MainActor in
            await performBulkRestore(urls)
        }
    }

    private func performBulkRestore(_ urls: [URL]) async {
        if urls.count > 1, let window { bulkProgress.begin(total: urls.count, verb: "Restoring", in: window) }
        defer { bulkProgress.end() }

        var newURLs: [URL] = []
        var items: [DeletionUndoHistory.Item] = []
        func isLegacyVideo(_ url: URL) -> Bool {
            let ext = url.pathExtension.lowercased()
            return ext != "seal" && RecordingsLibrary.videoExtensions.contains(ext)
        }
        for (index, url) in urls.enumerated() {
            do {
                // .seal packages (image and video) restore to the save folder.
                // Legacy recordings (.sealrec/.mov/.mp4) restore to Recordings/.
                let newURL = isLegacyVideo(url)
                    ? try SealDeleter.restore(url: url, toFolder: RecordingsLibrary.folder(forSaveFolder: config.saveFolder))
                    : try SealDeleter.restore(url: url, saveFolder: config.saveFolder)
                newURLs.append(newURL)
                items.append(.init(trashedURL: url, originalURL: newURL))
            } catch {
                os_log("bulk restore failed for %{public}@: %{public}@",
                       log: log, type: .error, url.path, String(describing: error))
            }
            bulkProgress.update(done: index + 1, total: urls.count, verb: "Restoring")
            await Task.yield()
        }
        // One undoable event for the whole restore gesture (⌘Z re-deletes). Only
        // captures (.seal packages) can be the open file, so the batch "contains
        // the open file" only if it has a non-legacy-video.
        globalUndo.record(.fileEvent(.init(items: items, kind: .restoration,
            containedOpenFile: newURLs.contains { !isLegacyVideo($0) }, at: Date())))
        updateUndoRedoButtons()
        ActivityHighlightStore.shared.mark(newURLs)
        self.state?.bottomTab = .recent
        self.currentTab = .recent
        metaRow?.setActiveTab(.recent)
        mountStrip(for: currentTab)
        // The hidden Deleted strip changed too — refresh it now rather than
        // waiting for the FSEvents debounce. (mountStrip above already
        // refreshed the Recent strip.)
        deletedStrip?.refresh()
        // Open the first restored capture in the editor (legacy recordings play, not open).
        if let firstCapture = newURLs.first(where: { !isLegacyVideo($0) }) {
            onRecentClickStored(firstCapture)
        }
        updateDeletedTabAvailability()
    }

    /// The trash subfolder holding deleted captures — the source for the
    /// Deleted strip and the read-only-open-file delete fallback.
    private var deletedCapturesFolder: URL {
        config.saveFolder.appendingPathComponent(
            SealDeleter.deletedSubfolderName, isDirectory: true)
    }

    /// The Deleted strip item to open after purging `batch` while `open` is the
    /// currently-viewed file: the VISUAL neighbor in the strip's display order —
    /// the item just AFTER the deleted one, else the one just BEFORE it —
    /// skipping anything also in the batch. Falls back to the first surviving
    /// item (or the newest deleted capture on disk if the strip is unavailable).
    /// Returns nil when nothing survives → the caller shows the empty canvas.
    private func deletedStripNeighbor(afterPurging batch: [URL], open: URL?) -> URL? {
        let batchSet = Set(batch.map(\.standardizedFileURL))
        // The strip hasn't refreshed yet, so its order still includes `open`.
        let order = deletedStrip?.orderedURLs
            ?? findRecentCaptures(in: deletedCapturesFolder, coveringDays: 30)
        func survives(_ url: URL) -> Bool {
            !batchSet.contains(url.standardizedFileURL)
                && FileManager.default.fileExists(atPath: url.path)
        }
        if let open,
           let idx = order.firstIndex(where: { $0.standardizedFileURL == open.standardizedFileURL }) {
            if let after = order[(idx + 1)...].first(where: survives) { return after }
            if let before = order[..<idx].reversed().first(where: survives) { return before }
            return nil
        }
        return order.first(where: survives)
    }

    /// The library moved. Re-point both strips at the new folder — they hold
    /// their folder from init (`updateFolder`), so without this they keep
    /// listing the previous library. Re-run the Deleted-tab check afterwards:
    /// the new folder's trash is almost certainly a different size, and may be
    /// empty while the Deleted tab is the active one.
    private func handleSaveFolderChange(to folder: URL) {
        recentStrip.updateFolder(folder)
        deletedStrip?.updateFolder(deletedCapturesFolder)
        updateDeletedTabAvailability()
    }

    /// Grey out the Deleted strip tab when the trash holds no captures, and
    /// bounce off it if it's somehow the active tab while empty. Cheap disk
    /// scan; called from the strip refresh chokepoints.
    func updateDeletedTabAvailability() {
        let hasDeleted = !listCaptures(in: deletedCapturesFolder).isEmpty
        metaRow?.setDeletedTabEnabled(hasDeleted)
        if !hasDeleted, currentTab == .deleted {
            state?.bottomTab = .recent
            currentTab = .recent
            metaRow?.setActiveTab(.recent)
            mountStrip(for: .recent)
        }
    }

    /// Public entry: one-URL permanent delete. Shows the confirmation
    /// alert first; on confirm, removes the file via SealDeleter.
    func handlePermanentDelete(_ url: URL) {
        confirmAndPermanentlyDelete([url])
    }

    /// Public entry: bulk permanent delete. Shows the confirmation alert
    /// with the count; on confirm, removes all files.
    func handleBulkPermanentDelete(_ urls: [URL]) {
        confirmAndPermanentlyDelete(urls)
    }

    /// Show an NSAlert sheet asking the user to confirm before hard-
    /// deleting. Cancel is the default button (Esc dismisses; Enter
    /// triggers Cancel). On Delete, calls performPermanentDelete.
    private func confirmAndPermanentlyDelete(_ urls: [URL]) {
        guard let window, !urls.isEmpty else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = urls.count == 1
            ? "Permanently delete \"\(urls[0].lastPathComponent)\"?"
            : "Permanently delete \(urls.count) items?"
        alert.informativeText = "These files will be deleted immediately and cannot be recovered."
        alert.addButton(withTitle: "Cancel")    // first = default; Esc/Enter cancels
        alert.addButton(withTitle: "Delete")    // destructive

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            // .alertFirstButtonReturn = Cancel; .alertSecondButtonReturn = Delete
            guard response == .alertSecondButtonReturn else { return }
            self.performPermanentDelete(urls)
        }
    }

    /// Remove every URL in `urls` from disk via SealDeleter. If any was
    /// the currently-open file (the user was viewing a deleted file
    /// read-only), swap to the next-most-recent Recent file or close
    /// the window. Refresh the strip. Per-URL errors are logged and
    /// swallowed so the batch continues.
    private func performPermanentDelete(_ urls: [URL]) {
        // `state` is nil when nothing is open in the canvas (empty editor, or
        // a video-only session opened via presentRecording) — Deleted-strip
        // purges must still run, so never bail on it.
        //
        // Capture the user's current tab BEFORE any swap. If the open
        // file is in the batch, onRecentClickStored → presentFile → swap
        // will replace self.state with a fresh EditorState whose
        // bottomTab defaults to .recent, which would otherwise flip the
        // strip back to Recent even though the user wants to stay in
        // Deleted.
        let previousTab = state?.bottomTab ?? currentTab
        // Capture BEFORE the swap replaces `state`: a read-only open file is a
        // deleted capture, so its fallback must come from the Deleted strip, not
        // Recent (see the fallback branch below).
        let openWasDeleted = state?.isReadOnly ?? false
        let openURL = state?.sourceURL

        var openFileWasInBatch = false
        if urls.count > 1, let window { bulkProgress.begin(total: urls.count, verb: "Deleting", in: window) }
        for (index, url) in urls.enumerated() {
            if url == state?.sourceURL { openFileWasInBatch = true }
            // Purging the video currently playing in the canvas closes it —
            // AVPlayer would otherwise keep streaming a removed file.
            if url == playingVideoURL { dismissCanvasVideo() }
            do {
                try SealDeleter.permanentlyDelete(url: url)
            } catch {
                os_log("permanent delete failed for %{public}@: %{public}@",
                       log: log, type: .error, url.path, String(describing: error))
            }
            bulkProgress.update(done: index + 1, total: urls.count, verb: "Deleting")
        }
        bulkProgress.end()
        if openFileWasInBatch {
            // Same dirty-state-clear trick as handleBulkDelete so that
            // autoSaveIfDirty (inside presentFile via onRecentClickStored)
            // doesn't reincarnate anything. Read-only files shouldn't be
            // dirty in the first place, but staying consistent with
            // handleBulkDelete keeps the flow robust.
            self.state?.annotations = []
            self.state?.croppedRect = nil; self.state?.contentClip = nil
            // A deleted (read-only) capture falls back to the VISUAL NEIGHBOR in
            // the Deleted strip (the item after the deleted one, else before it),
            // not a global newest-first pick; a live capture falls back to Recent.
            let next = openWasDeleted
                ? deletedStripNeighbor(afterPurging: urls, open: openURL)
                : findRecentCaptures(in: config.saveFolder, coveringDays: 7).first
            if let next {
                onRecentClickStored(next)
                // `self.state` is now the new EditorState — restore the tab.
                self.state?.bottomTab = previousTab
                self.currentTab = previousTab
            } else {
                // Nothing left to show — swap to the empty editor rather
                // than closing (which would leave the app with no window).
                onAllCapturesDeleted?()
                return
            }
        }
        mountStrip(for: previousTab)
        // Both strips can be affected; refresh the one mountStrip didn't.
        switch previousTab {
        case .recent: deletedStrip?.refresh()
        case .deleted: recentStrip.refresh()
        }
        // Re-select the open capture in the visible strip: mountStrip cleared the
        // selection, and a programmatic fallback-open (onRecentClickStored) never
        // ran the strip's own click-selection — so without this the newly-shown
        // image sits on the canvas unhighlighted in the strip. selectAsClicked
        // matches a manual click's highlight and is replaced by the next click.
        if let openNow = state?.sourceURL {
            switch previousTab {
            case .recent:  recentStrip.selectAsClicked(openNow)
            case .deleted: deletedStrip?.selectAsClicked(openNow)
            }
        }
        updateDeletedTabAvailability()
    }

    /// Files were permanently deleted elsewhere (the Library's Delete
    /// Forever). The disk work is done; this window only has to stop
    /// showing them: close a purged playing video, swap away from a purged
    /// open image, and refresh both strips.
    private func handleExternalPurge(_ urls: [URL]) {
        if let playing = playingVideoURL, urls.contains(playing) {
            dismissCanvasVideo()
        }
        if let open = state?.sourceURL, urls.contains(open) {
            // The file is gone — clear the dirty flags so autoSaveIfDirty
            // (inside the presentFile swap) can't reincarnate it.
            let openWasDeleted = state?.isReadOnly ?? false
            state?.annotations = []
            state?.croppedRect = nil; state?.contentClip = nil
            // A deleted (read-only) capture falls back to the visual neighbor in
            // the Deleted strip; a live capture falls back to Recent.
            let next = openWasDeleted
                ? deletedStripNeighbor(afterPurging: urls, open: open)
                : findRecentCaptures(in: config.saveFolder, coveringDays: 7).first
            if let next {
                // Opening the neighbor routes through presentFile, which
                // forces the editor tab. These notifications come from Library
                // deletes — don't yank the user out of the Library; reconcile
                // the canvas in the background and restore their tab
                // (mirrors reconcileOpenFileExistence).
                let tabBefore = currentTabSelection
                onRecentClickStored(next)
                if tabBefore != .editor { selectTab(tabBefore) }
            } else {
                onAllCapturesDeleted?()
                return
            }
        }
        recentStrip.refresh()
        deletedStrip?.refresh()
        // Re-select the open capture in whichever strip now contains it (a
        // deleted file → the Deleted strip; a live one → Recent), so the
        // fallback-opened image is highlighted like a manual click.
        if let openNow = state?.sourceURL {
            if state?.isReadOnly == true { deletedStrip?.selectAsClicked(openNow) }
            else { recentStrip.selectAsClicked(openNow) }
        }
        updateDeletedTabAvailability()
    }

    /// Move `url` from Deleted back into the save folder, then open the
    /// restored file in the editor. Refresh both strips so the moved
    /// file appears in Recent and disappears from Deleted.
    func handleRestore(_ url: URL) {
        // .seal packages (both image and video captures) restore uniformly to
        // the save folder. Legacy recordings (.sealrec/.mov/.mp4 from the
        // strip's Deleted tab) restore to Recordings/ — those aren't opened
        // in the editor, they play back.
        let ext = url.pathExtension.lowercased()
        let isLegacyVideo = ext != "seal"
            && RecordingsLibrary.videoExtensions.contains(ext)
        let newURL: URL
        do {
            newURL = isLegacyVideo
                ? try SealDeleter.restore(url: url, toFolder: RecordingsLibrary.folder(forSaveFolder: config.saveFolder))
                : try SealDeleter.restore(url: url, saveFolder: config.saveFolder)
        } catch {
            os_log("restore failed for %{public}@: %{public}@",
                   log: log, type: .error, url.path, String(describing: error))
            return
        }
        // Record the restore as an undoable event (⌘Z re-deletes it). A restored
        // capture is opened below (so undo handles the open-file swap); a legacy
        // video is not, so it never contains the open file.
        globalUndo.record(.fileEvent(.init(
            items: [.init(trashedURL: url, originalURL: newURL)], kind: .restoration,
            containedOpenFile: !isLegacyVideo, at: Date())))
        updateUndoRedoButtons()
        ActivityHighlightStore.shared.mark([newURL])
        // Switch back to Recent so the user sees the restored file in
        // its new context, then open it in the editor.
        self.state?.bottomTab = .recent
        self.currentTab = .recent
        metaRow?.setActiveTab(.recent)
        mountStrip(for: currentTab)
        // The hidden Deleted strip lost this file — refresh it now rather
        // than waiting for the FSEvents debounce. (mountStrip above already
        // refreshed the Recent strip.)
        deletedStrip?.refresh()
        if !isLegacyVideo { onRecentClickStored(newURL) }   // legacy recordings open as playback, not in the editor
    }

    /// Commit any pending crop on the canvas. Shared between the sidebar
    /// "Confirm crop" button and the existing Return-key handler in
    /// EditorCanvasView (if any).
    func commitCrop() {
        guard let state = state else { return }
        // Only run the animated cross-fade when there's a real crop to apply;
        // otherwise just clear any zero/empty pending rect. The scroll view
        // resizes + re-centers synchronously and fades a snapshot of the old
        // view out so the crop isn't a hard cut.
        guard let scroll = canvasScroll,
              let pending = state.pendingCrop,
              pending.width > 0, pending.height > 0 else {
            state.commitCrop()
            return
        }
        _ = pending
        scroll.commitCropSmoothly({ state.commitCrop() }, chrome: chromeOverlay)
    }

    // MARK: - Document resize (Resize popover)

    /// Controller-owned so the popover (and the user's unit/lock choices)
    /// SURVIVES Apply: applying swaps the editor state, which rebuilds the
    /// meta row — the popover re-anchors to the fresh button afterwards.
    /// `.transient` behavior dismisses it on any click outside the popover.
    private var resizePopover: NSPopover?
    private var resizePopoverModel: ResizePopoverModel?
    private var liveResizeWorkItem: DispatchWorkItem?
    /// The image the open Resize popover belongs to. A pending live/commit
    /// resize must only ever resample THIS state — never a different image the
    /// user switched to while a resize was in flight (the transient popover's
    /// commit-on-dismiss can otherwise fire against the newly-selected image).
    /// Weak: `state` owns the lifetime; updated across the resize's own swap.
    private weak var resizeOwnerState: EditorState?
    /// Set when the USER dismisses the Resize popover (click-outside / Esc), via
    /// `popoverShouldClose` — which AppKit calls ONLY for user-initiated closes,
    /// NOT when the meta-row rebuild removes the anchor mid-resize. Gates the
    /// re-anchor so a dismissed popover isn't re-opened by the commit-on-dismiss
    /// resize it triggers.
    private var resizePopoverUserDismissed = false

    /// Debounced live resize: coalesces stepper hold-repeats and rapid typing
    /// into one resample + state swap, then reflects the applied size back
    /// into the popover model.
    private func scheduleLiveResize(to target: CGSize) {
        liveResizeWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Only resample the image whose Resize popover is open. If the user
            // switched images while this resize was pending (incl. the transient
            // popover's commit-on-dismiss firing as they click another strip
            // tile), the current state is a DIFFERENT image — do nothing, or it
            // would resize the newly-selected image too.
            guard self.state === self.resizeOwnerState else { return }
            self.applyDocumentResize(to: target)
            if let applied = self.state?.visibleImageSize {
                self.resizePopoverModel?.current = applied
            }
        }
        liveResizeWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    func toggleResizePopover(anchor: NSButton) {
        if let pop = resizePopover, pop.isShown {
            pop.performClose(nil)
            resizePopover = nil
            resizePopoverModel = nil
            return
        }
        guard let state, !state.isReadOnly else { return }
        resizeOwnerState = state   // this popover resizes THIS image only
        resizePopoverUserDismissed = false   // fresh popover; not yet dismissed
        let model = ResizePopoverModel(original: state.pristineVisibleSize,
                                       current: state.visibleImageSize)
        // LIVE apply — no Apply button. Debounced so a stepper hold-repeat
        // coalesces into one resample instead of a state swap per tick.
        model.onTargetChanged = { [weak self] target in
            self?.scheduleLiveResize(to: target)
        }
        let pop = NSPopover()
        pop.behavior = .transient
        pop.delegate = self   // commit an in-edit field on dismissal
        let host = NSHostingController(rootView: ResizePopoverView(model: model))
        // Size the popover BEFORE showing: hosted SwiftUI reports its size a
        // beat late, and NSPopover grows to it with the TOP edge pinned —
        // sliding the body up by exactly its own height (the observed
        // constant ~181pt misplacement, height 165 + arrow 16).
        host.view.layoutSubtreeIfNeeded()
        pop.contentViewController = host
        pop.contentSize = host.view.fittingSize
        showResizePopover(pop, anchoredTo: anchor)
        resizePopover = pop
        resizePopoverModel = model
    }

    /// Anchor the popover via an explicitly converted rect on the window's
    /// CONTENT VIEW. Anchoring to the button directly placed the popover a
    /// constant ~185pt (≈ the bottom dock's height) too high — a flipped/
    /// unflipped conversion mismatch somewhere in the dock's stack hierarchy;
    /// converting to the content view ourselves sidesteps it.
    private func showResizePopover(_ pop: NSPopover, anchoredTo anchor: NSButton) {
        anchor.window?.layoutIfNeeded()
        guard let content = anchor.window?.contentView, let win = anchor.window else {
            pop.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
            return
        }
        _ = win
        let rect = content.convert(anchor.bounds, from: anchor)
        pop.show(relativeTo: rect, of: content,
                 preferredEdge: content.isFlipped ? .minY : .maxY)
    }

    /// Apply the Resize popover's target: resample the document to `requested`
    /// visible-size pixels and scale annotations/crop/focus along. Rebuilds
    /// the EditorState (`sourceImage` is immutable) and swaps it in. Not
    /// ⌘Z-undoable (the Enhance precedent for base-mutating ops) — the
    /// popover's Reset to original is the escape hatch, backed by the
    /// Grow the visible canvas to fit any annotation dropped past its edge, by
    /// enlarging the viewport (`croppedRect`) — possibly past the source edge,
    /// where it renders transparent (the doc's background fill on export). The
    /// `sourceImage` is never touched, so the original is always recoverable
    /// (Revert to Original / clearing the crop). One-way; and because this is a
    /// plain `croppedRect`+annotations edit, the move's own pre-move checkpoint
    /// reverts BOTH the move and the grow in one ⌘Z (⇧⌘Z re-grows) with no
    /// special undo machinery. Works for cropped and uncropped documents alike.
    func expandCanvasToFitAnnotations() {
        guard let state, !state.isReadOnly else { return }
        guard let box = boundingBox(of: state.annotations) else { return }
        let current = state.croppedRect ?? CGRect(
            origin: .zero, size: CGSize(width: state.sourceImage.width, height: state.sourceImage.height))
        guard let (viewport, shift) = CanvasExpander.expandedViewport(
            current: current, annotationBounds: box) else { return }
        os_log("grow: viewport %{public}@ → %{public}@ (shift %.0f,%.0f)", log: growLog, type: .info,
               String(describing: current), String(describing: viewport), shift.dx, shift.dy)
        // Capture the scroll position BEFORE the grow so the settle can keep the
        // content visually stable (see animateGrowSettle) instead of snapping.
        let prevScrollOrigin = canvasScroll?.contentView.bounds.origin
        state.annotations = state.annotations.map {
            Annotation(id: $0.id, geometry: translatedGeometry($0.geometry, by: shift),
                       style: $0.style, transform: $0.transform)
        }
        // Only touch focusRect when one is actually set. Assigning nil→nil still
        // fires the @Observable focus observer, which re-fits the (now larger)
        // canvas to the window and changes the zoom — a visible flash after a
        // move-triggered grow. A real focus is offset with the annotations.
        if let focus = state.focusRect {
            state.focusRect = focus.offsetBy(dx: shift.dx, dy: shift.dy)
        }
        // Lock the content region (source coords) on the FIRST grow so the grown
        // margin stays transparent instead of revealing cropped-away source; keep
        // it on later grows. nil for an uncropped doc that only overhangs the
        // source edge (nothing to clip → transparent past the edge already).
        state.contentClip = state.contentClip ?? state.croppedRect
        state.croppedRect = viewport
        state.markDirty()
        canvas?.needsDisplay = true
        if let prev = prevScrollOrigin {
            canvasScroll?.animateGrowSettle(shift: shift, previousOrigin: prev)
        }
        scheduleAutosave()
    }

    func applyDocumentResize(to requested: CGSize) {
        guard let state, !state.isReadOnly else { return }
        let pristine = state.pristineSource ?? state.sourceImage
        let pristineVisible = state.pristineVisibleSize
        let target = ResizeMath.clamped(requested, original: pristineVisible)
        let current = state.visibleImageSize
        guard target != current else { return }

        // Factors: doc-space (current geometry → new) and pristine→new (base
        // resample + persisted-crop mapping).
        let fDoc = ResizeMath.scaleFactors(from: current, to: target)
        let fNew = ResizeMath.scaleFactors(from: pristineVisible, to: target)
        let atNative = Int(target.width.rounded()) == Int(pristineVisible.width.rounded())
            && Int(target.height.rounded()) == Int(pristineVisible.height.rounded())

        let newBase: CGImage
        if atNative {
            newBase = pristine
        } else {
            let full = CGSize(width: CGFloat(pristine.width) * fNew.x,
                              height: CGFloat(pristine.height) * fNew.y)
            guard let resampled = DocumentResampler.resample(pristine, to: full) else { return }
            newBase = resampled
        }
        // Cross-size checkpoint: snapshots carry sourceImageSize, so this
        // step restores via restoreAcrossResize (the rebuild path).
        state.recordUndoCheckpoint(
            action: "Resize to \(Int(target.width)) \u{00D7} \(Int(target.height))")
        let pristineCrop = state.persistedCroppedRect
        let newState = EditorState(
            sourceImage: newBase,
            sourceURL: state.sourceURL,
            // Enhanced base is 2×-of-source; a resample breaks the invariant —
            // dropped here and in the package (regenerated on demand).
            enhancedImage: atNative ? state.enhancedImage : nil,
            showingEnhanced: atNative ? state.showingEnhanced : false,
            pristineSource: atNative ? nil : pristine
        )
        newState.annotations = AnnotationScaleMath.scaledAnnotations(
            state.annotations, fx: fDoc.x, fy: fDoc.y)
        newState.croppedRect = pristineCrop.map {
            atNative ? $0 : CGRect(x: $0.minX * fNew.x, y: $0.minY * fNew.y,
                                   width: $0.width * fNew.x, height: $0.height * fNew.y)
        }
        newState.focusRect = state.focusRect.map {
            CGRect(x: $0.minX * fDoc.x, y: $0.minY * fDoc.y,
                   width: $0.width * fDoc.x, height: $0.height * fDoc.y)
        }
        newState.enhanceParams = state.enhanceParams
        newState.enhanceDraft = state.enhanceDraft
        newState.imageAssets = state.imageAssets
        newState.isReadOnly = state.isReadOnly
        // The cutout was computed at the OLD document size — invalidate
        // (recompute on demand at the new size).
        newState.cutoutImage = nil
        newState.showingCutout = false
        newState.backgroundFill = state.backgroundFill
        newState.markDirty()
        // Undo history lives on the app-global timeline (`globalUndo`), not the
        // per-state stacks — nothing to carry across the rebuilt state.
        let title = window?.title ?? state.sourceURL?.lastPathComponent ?? "Untitled"
        // Keep the user's zoom across the resize (fitFresh would refit): the
        // swap honors the per-image remembered zoom, so store the CURRENT one
        // first — live stepper adjustments must not bounce the magnification.
        ImageZoomMemory.store(state.zoom, for: state.sourceURL)
        swap(toState: newState, title: title, fitFresh: false)
        // The resize replaced the state with a fresh instance; keep the owner
        // pointing at it so chained live-resize steps still match (an unrelated
        // image switch swaps in a state this never updates → the guard bails).
        resizeOwnerState = newState
        scheduleAutosave()
        // The swap rebuilt the meta row (closing the popover with it). If the
        // user dismissed the popover, tear it down for good — otherwise this is
        // a live stepper edit and the popover must stay open, so re-anchor it to
        // the fresh button.
        if resizePopoverUserDismissed {
            resizePopover?.performClose(nil)
            resizePopover = nil
            resizePopoverModel = nil
        } else if let pop = resizePopover, let btn = metaRow?.resizeAnchorButton {
            showResizePopover(pop, anchoredTo: btn)
        }
    }

    /// Restore a history snapshot that lives in a DIFFERENT document size
    /// (⌘Z across a Resize): resample the document from the pristine source
    /// to the snapshot's size, then apply the snapshot VERBATIM — its
    /// annotations/crop/focus are already in that size's coordinate space.
    /// Size-specific alternate bases (cutout/enhanced bitmaps) cannot cross;
    /// they land off and regenerate on demand.
    private func restoreAcrossResize(_ snapshot: EditorSnapshot) {
        UndoDiag.note("restoreAcrossResize '\(snapshot.action ?? "-")' — rebuild swap "
            + "(global u:\(globalUndo.undoStack.count) r:\(globalUndo.redoStack.count))")
        guard let state, let targetFull = snapshot.sourceImageSize else { return }
        let pristine = state.pristineSource ?? state.sourceImage
        let atNative = Int(targetFull.width) == pristine.width
            && Int(targetFull.height) == pristine.height
        let newBase: CGImage
        if atNative {
            newBase = pristine
        } else {
            guard let resampled = DocumentResampler.resample(pristine, to: targetFull) else { return }
            newBase = resampled
        }
        // Rename undo across the rebuild: applyHistory's file-move contract.
        let diskURL = state.sourceURL
        let newState = EditorState(
            sourceImage: newBase,
            sourceURL: snapshot.sourceURL ?? state.sourceURL,
            pristineSource: atNative ? nil : pristine
        )
        newState.annotations = snapshot.annotations
        newState.croppedRect = snapshot.croppedRect
        newState.focusRect = snapshot.focusRect
        newState.backgroundFill = snapshot.backgroundFill
        newState.enhanceParams = state.enhanceParams
        newState.enhanceDraft = state.enhanceDraft
        newState.imageAssets = state.imageAssets
        newState.isReadOnly = state.isReadOnly
        newState.markDirty()
        if let from = diskURL, let to = newState.sourceURL, from != to {
            moveCaptureFile(from: from, to: to)
        }
        ImageZoomMemory.store(snapshot.zoom ?? state.zoom, for: state.sourceURL)
        let title = window?.title ?? newState.sourceURL?.lastPathComponent ?? "Untitled"
        swap(toState: newState, title: title, fitFresh: false)
        // Defensive: metadata steps share the size of the step above them in
        // pop order, so a cross-size snapshot shouldn't carry a patch — but if
        // one ever does, honor it (performEditStep parked it via
        // parkRestoredMetadata on the OLD state, which is gone after the swap).
        if let patch = state.consumePendingRestoredMetadata(),
           let url = self.state?.sourceURL {
            writeRestoredMetadata(patch, at: url)
        }
        scheduleAutosave()
    }

    // MARK: - Background removal (transparent cutout)

    /// ONE-SHOT operation (not a toggle): every click computes a fresh
    /// cutout from the current base via the on-device subject mask (Vision)
    /// and shows it — click again after the content changes to re-run. ⌘Z
    /// is the way back (the toggle-off button was dropped by request); the
    /// cutout persists in the package (`cutout.png`) across reopens.
    private var cutoutComputeInFlight = false

    func removeBackground() {
        guard let state, !state.isReadOnly, !cutoutComputeInFlight else { return }
        cutoutComputeInFlight = true
        let base = state.sourceImage
        // A focus area constrains the subject search to itself: the mask runs
        // on those pixels only and everything outside becomes background.
        // focusRect is visible-space — map through the crop into source space.
        let focusInSource: CGRect? = state.focusRect.map { _ in
            EditorState.aiOCRRect(
                sourceSize: CGSize(width: base.width, height: base.height),
                croppedRect: state.croppedRect,
                focusRect: state.focusRect)
        }
        let hadFocus = focusInSource != nil
        Task { @MainActor [weak self] in
            let outcome = await BackgroundRemover.removeBackground(
                from: base, focusInSource: focusInSource)
            guard let self else { return }
            self.cutoutComputeInFlight = false
            // The document may have been swapped (file switch, resize) while
            // computing — apply only if the base still matches.
            guard let state = self.state, state.sourceImage === base else { return }
            switch outcome {
            case .cutout(let image):
                state.recordUndoCheckpoint(action: "Remove Background")
                state.cutoutImage = image
                state.setShowingCutout(true)
                self.scheduleAutosave()
            case .noSubject:
                if let host = self.canvasHost {
                    EditorToastView.show(
                        hadFocus ? "No subject found in the focus area" : "No subject found",
                        in: host)
                }
            case .failed:
                if let host = self.canvasHost { EditorToastView.show("Background removal failed", in: host) }
            }
        }
    }

    // MARK: - Enhancing overlay

    func showEnhancingOverlay(progress: EnhanceProgress, onCancel: @escaping () -> Void = {}) {
        guard enhancingOverlay == nil, let host = canvasHost else { return }
        let overlay = NSHostingView(rootView: EnhancingOverlayView(progress: progress, onCancel: onCancel))
        overlay.translatesAutoresizingMaskIntoConstraints = false
        // Edge-pinned overlay — keep SwiftUI from updating window size extrema
        // (reentrant-layout crash on macOS 26; see Library host in selectTab).
        overlay.sizingOptions = []
        // The hosting view's intrinsic size collapses to the small "Enhancing…"
        // card. canvasHost lives in a .centerX vertical stack where width is
        // content-driven, so that intrinsic width would shrink the whole canvas
        // column to the card's width. Drop hugging/compression resistance to a
        // minimum (like the no-intrinsic-size backdrop/scroll) so the edge pins
        // size the overlay to the full canvasHost instead.
        for axis in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            overlay.setContentHuggingPriority(.init(1), for: axis)
            overlay.setContentCompressionResistancePriority(.init(1), for: axis)
        }
        host.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: host.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        enhancingOverlay = overlay
        // Stop the canvas's hover tracking from drawing the crosshair under the
        // overlay (notably over the Cancel button).
        canvas?.suppressHoverCursor = true
        os_log("blocking overlay: enhance shown", log: log, type: .info)
        updateBlockingUIState()
    }

    func hideEnhancingOverlay() {
        // Idempotent: several cancel/finish paths call this, and calling it
        // when nothing is up is a no-op rather than an unbalanced release —
        // the gate reads the overlays, not a call count.
        guard enhancingOverlay != nil else { return }
        enhancingOverlay?.removeFromSuperview()
        enhancingOverlay = nil
        canvas?.suppressHoverCursor = false
        os_log("blocking overlay: enhance hidden", log: log, type: .info)
        updateBlockingUIState()
    }

    // MARK: - Lock overlay

    private func refreshLockOverlay() {
        let locked = EncryptionSession.shared.isEnabled && !EncryptionSession.shared.isUnlocked
        // Hide the tab switcher (window toolbar) while locked.
        window?.toolbar?.isVisible = !locked
        // Hide the editor content column outright while locked. Its header holds
        // the Capture tool bar, which sits at the top of the content view above
        // where the overlay's safe-area-inset background reaches — so even with
        // the overlay on top, that control's edge pokes through. Hiding the whole
        // column removes it. Restored per the active tab on unlock.
        if locked {
            editorContentView?.isHidden = true
            // Decrypted (sealed-capture) thumbnails must not survive a relock.
            ThumbnailStore.shared.clear()
            showLockOverlay()
        } else {
            editorContentView?.isHidden = (currentTabSelection != .editor)
            lockOverlayHost?.removeFromSuperview()
            lockOverlayHost = nil
            // The toolbar was hidden for the duration of the lock; re-derive
            // the tab/toolbar block as it comes back rather than trusting
            // whatever state it carried into the lock.
            updateBlockingUIState()
            // The notice explained why the user was sent to the lock screen;
            // once unlocked it is stale, and must not reappear on a later lock.
            lockNotice = nil
            // Tiles/cards built while locked decoded to nil; now that the
            // session can decrypt sealed thumbnails, re-drive their loads.
            if EncryptionSession.shared.isEnabled {
                recentStrip.reloadThumbnails()
                libraryViewModel?.reload()
            }
        }
    }

    /// Put the window in front showing the lock screen, with `text` explaining
    /// what the user just tried to do. Used when an action is refused *because*
    /// the app is locked — a blocked capture would otherwise be a silent no-op
    /// with no way to learn why. Rebuilds the overlay so a notice arriving
    /// while it is already up still lands.
    func presentLockNotice(_ text: String) {
        lockNotice = text
        lockOverlayHost?.removeFromSuperview()
        lockOverlayHost = nil
        refreshLockOverlay()
        window?.makeKeyAndOrderFront(nil)
    }

    private func showLockOverlay() {
        guard lockOverlayHost == nil, let container = shellContainer else { return }
        let view = LockScreenView(
            // Drive unlock / recovery / turn-off from the consistency check, so a
            // diverged state offers the guaranteed escape instead of dead-ending.
            mode: EncryptionSession.shared.consistencyStatus(saveFolder: config.saveFolder).lockScreenMode,
            notice: lockNotice,
            onUnlock: {
                // unlock() prompts Touch ID (async); on success the lock-state
                // notification observer calls refreshLockOverlay and tears
                // this overlay down.
                Task { @MainActor in _ = try? await EncryptionSession.shared.unlock() }
            },
            onRecover: { [weak self] in self?.presentRecoverySheet() },
            onTurnOff: { [weak self] in self?.presentTurnOffEncryption() }
        )
        let host = NSHostingView(rootView: view)
        host.translatesAutoresizingMaskIntoConstraints = false
        // Edge-pinned overlay — keep SwiftUI from updating window size extrema
        // (reentrant-layout crash on macOS 26; see Library host in selectTab).
        host.sizingOptions = []
        // Mirror the EnhancingOverlay hugging/compression resistance so the
        // edge-pin constraints, not the intrinsic size, dictate the frame.
        for axis in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            host.setContentHuggingPriority(.init(1), for: axis)
            host.setContentCompressionResistancePriority(.init(1), for: axis)
        }
        // Added above every existing subview. `positioned:relativeTo:` rather
        // than a bare addSubview: "added last" only holds for views that exist
        // NOW, and tab placeholders are created lazily on first visit — which
        // can happen while the overlay is already up.
        container.addSubview(host, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: container.topAnchor),
            host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        lockOverlayHost = host
    }

    /// Re-assert the lock overlay as the topmost subview. Views added to
    /// `shellContainer` after the overlay was mounted — a tab placeholder
    /// created on its first visit — otherwise sit above it and render over
    /// the lock screen. Cheap and idempotent; no-op when nothing is locked.
    private func raiseLockOverlay() {
        guard let host = lockOverlayHost, let container = shellContainer else { return }
        container.addSubview(host, positioned: .above, relativeTo: nil)
    }

    /// The always-can-disable escape from the lock screen: authenticate (device
    /// owner, not the encryption key — works even when the key is gone), turn
    /// encryption off (decrypting what's possible, quarantining the rest), then
    /// tear the lock overlay down. Surfaces a note if anything was quarantined.
    private func presentTurnOffEncryption() {
        Task { @MainActor in
            guard await LocalAuthGate().authenticate(
                reason: "Authenticate to turn off encryption") else { return }
            let summary = await EncryptionProvisioner.disable(
                saveFolder: config.saveFolder, session: .shared,
                identityStore: KeychainIdentityStore()) { _, _ in }
            refreshLockOverlay()   // isEnabled is now false → overlay tears down
            recentStrip.reloadThumbnails()
            libraryViewModel?.reload()
            if summary.quarantined > 0 {
                let n = summary.quarantined
                let alert = NSAlert()
                alert.messageText = "Encryption turned off"
                alert.informativeText = "\(n) capture\(n == 1 ? "" : "s") couldn’t be decrypted (the key wasn’t on this Mac) and \(n == 1 ? "was" : "were") moved to a “\(Quarantine.folderName)” folder in your save location."
                alert.runModal()
            }
        }
    }

    /// Present the recovery-key entry as a modal sheet on the editor window.
    /// Uses NSHostingController + window.beginSheet to match the BulkProgressSheet
    /// pattern (AppKit-native sheet, SwiftUI content inside).
    private func presentRecoverySheet() {
        guard recoverySheetWindow == nil, let window else { return }

        let hosting = NSHostingController(rootView: RecoveryEntryView(
            saveFolder: config.saveFolder,
            onRecovered: { [weak self] in
                self?.dismissRecoverySheet()
                // The .encryptionLockStateDidChange notification posted by
                // session.unlock() inside RecoveryEntryModel already triggers
                // refreshLockOverlay() → the lock overlay tears itself down.
                // Typing a working recovery code here IS proof of possession —
                // stamp the same verification the periodic nudge checks.
                RecoveryVerifyNudgeController.stampVerifiedNow()
            },
            onCancel: { [weak self] in
                self?.dismissRecoverySheet()
            },
            onLockedOut: { [weak self] in
                // Escalate from "enter your code" to the guided reset: close
                // this sheet first (the explainer is a sibling sheet on the
                // same window and the nudge/explainer guards expect one at a
                // time), then present the explainer.
                self?.dismissRecoverySheet()
                self?.presentLockoutExplainerSheet()
            }
        ))

        let sheetWindow = NSWindow(contentViewController: hosting)
        sheetWindow.styleMask = [.titled]
        sheetWindow.isReleasedWhenClosed = false
        recoverySheetWindow = sheetWindow

        window.beginSheet(sheetWindow, completionHandler: nil)
    }

    /// Present the "I can't unlock…" guided-reset explainer as a modal sheet,
    /// same idiom as `presentRecoverySheet`.
    private func presentLockoutExplainerSheet() {
        guard lockoutExplainerSheetWindow == nil, let window else { return }

        let lockedCount = LockoutExplainerView.countLockedPackages(in: config.saveFolder)
        let hosting = NSHostingController(rootView: LockoutExplainerView(
            saveFolder: config.saveFolder,
            lockedCount: lockedCount,
            onReset: { [weak self] summary in
                self?.dismissLockoutExplainerSheet()
                self?.didCompleteLockoutReset(summary)
            },
            onCancel: { [weak self] in
                self?.dismissLockoutExplainerSheet()
            }
        ))

        let sheetWindow = NSWindow(contentViewController: hosting)
        sheetWindow.styleMask = [.titled]
        sheetWindow.isReleasedWhenClosed = false
        lockoutExplainerSheetWindow = sheetWindow

        window.beginSheet(sheetWindow, completionHandler: nil)
    }

    private func dismissLockoutExplainerSheet() {
        guard let sheetWindow = lockoutExplainerSheetWindow else { return }
        lockoutExplainerSheetWindow = nil
        window?.endSheet(sheetWindow)
        sheetWindow.orderOut(nil)
    }

    /// Present the Locked Archive recovery-code restore flow as a modal
    /// sheet, same idiom as `presentRecoverySheet`. Entry point: the Library
    /// Locked Archive banner (the Settings row presents the same SwiftUI form
    /// via its own native `.sheet`).
    private func presentArchiveRestoreSheet() {
        guard archiveRestoreSheetWindow == nil, let window else { return }

        let hosting = NSHostingController(rootView: LockedArchiveRestoreView(
            saveFolder: config.saveFolder,
            onDone: { [weak self] summary in
                self?.dismissArchiveRestoreSheet()
                if let summary { self?.didCompleteArchiveRestore(summary) }
            }
        ))

        let sheetWindow = NSWindow(contentViewController: hosting)
        sheetWindow.styleMask = [.titled]
        sheetWindow.isReleasedWhenClosed = false
        archiveRestoreSheetWindow = sheetWindow

        window.beginSheet(sheetWindow, completionHandler: nil)
    }

    private func dismissArchiveRestoreSheet() {
        guard let sheetWindow = archiveRestoreSheetWindow else { return }
        archiveRestoreSheetWindow = nil
        window?.endSheet(sheetWindow)
        sheetWindow.orderOut(nil)
    }

    /// Wraps up a completed Locked Archive restore: the engine's settled
    /// lock-state notification already tears down the overlay and reloads the
    /// strip + Library (see the `.encryptionLockStateDidChange` observer),
    /// but refresh explicitly too — same belt-and-braces as
    /// `didCompleteLockoutReset`. No toast here: unlike `LockoutExplainerView`
    /// (which reports nothing itself, so its own `didCompleteLockoutReset`
    /// toast is the only place the outcome is shown), `LockedArchiveRestoreView`
    /// already shows the full result summary inline in its own `.done` phase
    /// before the sheet dismisses — a toast on top of that would just
    /// double-message the same outcome. The Library's Locked Archive section
    /// falls back to All Files automatically when the archive empties
    /// (`LibraryViewModel.reload`).
    private func didCompleteArchiveRestore(_: LockedArchiveRestore.Summary) {
        refreshLockOverlay()
        recentStrip.reloadThumbnails()
        libraryViewModel?.reload()
    }

    /// Wraps up a completed `LockoutReset`: tear the lock overlay down (its
    /// own state — `isEnabled`/`isUnlocked` — is already false/false, so
    /// `refreshLockOverlay` unlocks the editor UI), refresh the thumbnail
    /// surfaces the same way the unlock path does, and report the outcome.
    private func didCompleteLockoutReset(_ summary: LockoutReset.Summary) {
        refreshLockOverlay()
        recentStrip.reloadThumbnails()
        libraryViewModel?.reload()
        guard let host = canvasHost ?? window?.contentView else { return }
        var message = "Moved \(summary.archivedPackages) item\(summary.archivedPackages == 1 ? "" : "s") to Locked Archive"
        if !summary.failed.isEmpty {
            let n = summary.failed.count
            message += " — \(n) item\(n == 1 ? "" : "s") couldn't be moved and stay\(n == 1 ? "s" : "") in place"
        }
        EditorToastView.show(message, in: host)
    }

    /// The periodic "verify your recovery code" nudge (see
    /// `RecoveryVerifyNudge`). Presented only from this just-unlocked branch,
    /// so it can never fire while locked (the caller already checked
    /// `isUnlocked`). Ceremony avoidance: `EncryptionToggleModel.Phase` itself
    /// lives as `@State` inside the Privacy Settings card — not cheaply
    /// reachable from this window controller — but enable/disable/regenerate/
    /// rotate all call `session.adopt(_:)` mid-ceremony (e.g. `enable()`
    /// adopts the freshly generated identity to unlock the session for the
    /// migration pass, well before the recovery code is ever shown), which
    /// posts this SAME `.encryptionLockStateDidChange` notification. So
    /// presenting from "just unlocked" alone does NOT avoid ceremonies — it
    /// would fire mid-migration, on top of the "Encrypting your library…"
    /// progress screen. `EncryptionToggleModel` mirrors its working/showing-
    /// code phases onto `EncryptionSession.shared.operationInProgress`
    /// (already used a few lines above by `updateTabSwitcherEnabled()` to
    /// lock the tab switcher for the same window), so checking that flag here
    /// is the cheap, reliable substitute for reaching the model's phase
    /// directly, and it stays true until the ceremony's sheet is dismissed.
    private func maybePresentRecoveryVerifyNudge() {
        guard !EncryptionSession.shared.operationInProgress else { return }
        guard RecoveryUnlock.isAvailable(saveFolder: config.saveFolder) else { return }
        guard recoveryNudgeController.shouldPresent() else { return }
        // Also require no SIBLING recovery/archive-restore/lockout-explainer
        // sheet: today RecoveryEntryModel's recover() dismisses its sheet
        // before the deferred lock-state notification lands, but that's an
        // ordering accident — guard it explicitly so a future await inside
        // any of those flows can't stack sheets on top of this one.
        guard recoveryNudgeSheetWindow == nil, recoverySheetWindow == nil,
              archiveRestoreSheetWindow == nil, lockoutExplainerSheetWindow == nil,
              let window else { return }

        // Arm the once-per-session guard before presenting, not after — a
        // sheet dismissed by a window close (no explicit action) must still
        // count as "shown" this session.
        recoveryNudgeController.markShown()

        let hosting = NSHostingController(rootView: RecoveryVerifyNudgeView(
            saveFolder: config.saveFolder,
            onVerified: { [weak self] in
                self?.recoveryNudgeController.recordVerified()
                self?.dismissRecoveryNudgeSheet()
            },
            onSnooze: { [weak self] in
                self?.recoveryNudgeController.recordSnoozed()
                self?.dismissRecoveryNudgeSheet()
            },
            onGenerateNew: { [weak self] in
                self?.dismissRecoveryNudgeSheet()
                // Land directly on Privacy & Security via the established
                // settings deep-link — dual mechanism (queued pendingSection
                // + notification) mirrors the License tab's, so this works
                // whether Settings is already mounted or not (final-review
                // fix: posting only pendingSection silently dropped the
                // deep-link when Settings was already open, since a mounted
                // SettingsView's .onAppear never re-fires). The sheet's copy
                // names the row ("Recovery code ▸ Generate New…").
                SettingsDeepLink.pendingSection = .privacy
                NotificationCenter.default.post(name: .openPrivacySettings, object: nil)
                self?.selectTab(.settings)
            }
        ))

        let sheetWindow = NSWindow(contentViewController: hosting)
        sheetWindow.styleMask = [.titled]
        sheetWindow.isReleasedWhenClosed = false
        recoveryNudgeSheetWindow = sheetWindow

        window.beginSheet(sheetWindow, completionHandler: nil)
    }

    private func dismissRecoveryNudgeSheet() {
        guard let sheetWindow = recoveryNudgeSheetWindow else { return }
        recoveryNudgeSheetWindow = nil
        window?.endSheet(sheetWindow)
        sheetWindow.orderOut(nil)
    }

    // MARK: - In-canvas video player

    /// Transient overlay hosting the recording player, edge-pinned over
    /// `canvasHost` (same pattern as the enhancing/lock overlays). Removed when
    /// playback ends, a file is opened (`swap`), or the window closes.
    private var videoOverlay: NSView?
    /// Typed handle to the in-canvas player view (same object as `videoOverlay`)
    /// for teardown and key routing.
    private weak var canvasVideoView: CanvasVideoPlayerView?
    private var canvasVideoPlayer: AVPlayer?
    /// In-flight "Summarize video" work.
    private var videoSummaryTask: Task<Void, Never>?
    /// Shared cancellable progress overlay (video summarize + redaction scan).
    private var canvasProgressOverlay: NSView?
    /// Retains the decrypting resource-loader delegate for an encrypted player.
    private var sealedCanvasVideoPlayer: SealedRecordingPlayer?
    /// Resource loader for a plaintext payload inside a container (weakly held
    /// by AVFoundation — the canvas owns it while the video is open).
    private var canvasVideoPayloadLoader: AnyObject?
    /// The recording currently playing in the canvas (names a saved frame).
    private var playingVideoURL: URL?

    /// Play a video `.seal` package inline in the canvas (replacing the floating
    /// sheet). Fired by the strip and the Library for video items. Resolves the
    /// in-package payload URL + per-package CEK via `VideoSealPackageIO.read`;
    /// encrypted packages stream-decrypt via `SealedRecordingPlayer`, plaintext
    /// packages play via `AVPlayer` directly.
    /// Kick off the open recording's summary + tags generation via the shared
    /// `VideoMetadataCoordinator` (serial, version-gated). Progress is reflected
    /// in the Info panel by observing the coordinator's start/progress/finish
    /// notifications (see `setupObservers`).
    private func startVideoMetadataGenIfNeeded(url: URL) {
        VideoMetadataCoordinator.shared.ensure(for: url)
    }

    func playVideoInCanvas(url: URL, autoPlay: Bool = false) {
        guard let host = canvasHost else { return }
        // Capture identity BEFORE dismissCanvasVideo() clears playingVideoURL —
        // switching from video A to video B must record `from: A`, not the
        // underlying image dismissCanvasVideo() falls back to.
        let navFrom = currentDisplayedItemURL
        dismissCanvasVideo()
        selectTab(.editor)   // ensure the canvas is visible (Library → editor)
        playingVideoURL = url
        state?.playingVideoURL = url
        // A scratch recording has no tile in the strip — leaving the previous
        // selection painted would point at a different capture than the one now
        // playing. (Images clear this in presentFile; video takes this path
        // instead, since it plays in an overlay rather than opening a document.)
        if ScratchCapture.isScratch(url) { clearStripSelection() }
        // Remember the video as the last-selected capture for the next launch.
        if url.deletingLastPathComponent().lastPathComponent != SealDeleter.deletedSubfolderName {
            LastSelectedCapturePreference.store(url)
        }

        let player: AVPlayer?
        var openFailureMessage = "Can't play this video"
        // A recording saved without the package wrapper (Settings ▸ Recording)
        // is an ordinary movie file — AVPlayer opens it directly, extension and
        // all. It must be handled BEFORE VideoSealPackageIO.read, which has no
        // package to read here and would throw into the legacy "re-import it to
        // convert" branch below, leaving a perfectly good recording unplayable.
        if plainMovieExtensions.contains(url.pathExtension.lowercased()) {
            player = AVPlayer(playerItem: AVPlayerItem(url: url))
        } else {
            do {
                let contents = try VideoSealPackageIO.read(at: url, crypto: SealPackageCryptoContext.current())
                if let key = contents.key {
                    // Encrypted: stream-decrypt the in-package chunk payload (no plaintext on disk).
                    let wrapper = try SealedRecordingPlayer(payload: contents.payload, key: key)
                    sealedCanvasVideoPlayer = wrapper
                    player = wrapper.player
                } else {
                    // Plaintext: the payload is a real movie but extension-less,
                    // so the asset needs the sniffed-container MIME hint — and,
                    // inside a container, a range-serving loader.
                    let built = contents.plaintextPlaybackAsset()
                    canvasVideoPayloadLoader = built.retain
                    player = AVPlayer(playerItem: AVPlayerItem(asset: built.asset))
                }
            } catch {
                os_log("playVideoInCanvas: cannot open video .seal: %{public}@", log: log, type: .error, String(describing: error))
                if case VideoSealPackageIOError.packageLocked = error {
                    openFailureMessage = "Unlock to play this video"
                } else if url.pathExtension != "seal" {
                    // Legacy .sealrec from an old import — nothing in the app can
                    // open these anymore; say so instead of silence. (A plain
                    // .mov/.mp4 never reaches here: it took the branch above.)
                    openFailureMessage = "Can't play this file — re-import it to convert"
                }
                player = nil
            }
        }

        guard let player else {
            os_log("playVideoInCanvas: no player (locked or unreadable)", log: log, type: .error)
            playingVideoURL = nil
            state?.playingVideoURL = nil
            EditorToastView.show(openFailureMessage, in: host)
            return
        }

        // The switch succeeded — record it as a navigable step (skipped for
        // undo/redo-driven reopens; see `navigationRecordingSuppressed`).
        if !navigationRecordingSuppressed {
            globalUndo.record(.navigation(from: navFrom, to: url))
            updateUndoRedoButtons()
        }

        // The video is now the open item — move the strip's open-highlight to it
        // (mirrors swap() for images). Without this, a previously-selected image
        // kept its highlight while the video also showed selected.
        recentStrip.selectedURL = url
        // Show the video's name/favorite in the title bar (currentItemURL now
        // resolves to the video). Disable inline rename while a video plays —
        // the rename path targets the image's representedURL, not the video.
        titleLabel?.isEditable = false
        updateTitleRow()

        let videoView = CanvasVideoPlayerView(
            player: player,
            onClose: { [weak self] in self?.dismissCanvasVideo() },
            onCaptureFrame: { [weak self] in self?.captureCanvasVideoFrame() },
            // Frame-grab lives in the right sidebar; only fall back to the
            // in-canvas corner button when there's no sidebar (empty editor).
            showsCornerCamera: sidebar == nil)
        // Sealshot's own menu for a playing recording — the same actions the
        // canvas offers for the open capture, so right-clicking a video and
        // right-clicking a screenshot behave alike.
        videoView.contextMenuProvider = { [weak self] in self?.canvas?.captureMenu() }
        videoView.translatesAutoresizingMaskIntoConstraints = false

        host.addSubview(videoView)
        NSLayoutConstraint.activate([
            videoView.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            videoView.topAnchor.constraint(equalTo: host.topAnchor),
            videoView.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        videoOverlay = videoView
        canvasVideoView = videoView
        // Mirror the video's zoom in the meta row (its observation path reads
        // the hidden IMAGE state — nil in video-only sessions). The initial
        // fit lands via onZoomChanged as soon as the track's naturalSize loads.
        videoView.onZoomChanged = { [weak self] z in
            self?.metaRow?.setZoomDisplayOverride(z)
        }
        metaRow?.setZoomDisplayOverride(videoView.zoom)
        canvasVideoPlayer = player
        canvas?.suppressHoverCursor = true
        toolbarBuilder.setVideoMode(true)   // hide image-only tools
        // Move the frame-grab into the right sidebar (the panel for video).
        sidebar?.onCaptureFrame = { [weak self] in self?.captureCanvasVideoFrame() }
        sidebar?.setVideoMode(true)
        // Generate this recording's summary now (with a determinate panel bar) if
        // the background pass hasn't reached it yet.
        startVideoMetadataGenIfNeeded(url: url)
        // Focus the player so Space / ← / → reach its key handling.
        window?.makeFirstResponder(videoView)
        // Default: open paused on the first frame with a big center play button —
        // the user presses it (or clicks/Space) to start playback. A deliberate
        // play affordance (the strip's play badge) passes autoPlay to start now.
        if autoPlay { videoView.play() }
    }

    /// Grab the current playback frame and write it as a new `.seal` capture in
    /// the save folder — it lands in the recent strip like any other capture.
    @objc private func captureCanvasVideoFrame() {
        guard let item = canvasVideoPlayer?.currentItem,
              let current = canvasVideoPlayer?.currentTime() else { return }
        let asset = item.asset
        // When the video has played to the very end, currentTime == duration and
        // a zero-tolerance request at/after the last frame fails — pull the
        // request a hair before the end so the final frame is still grabbable.
        var time = current
        let dur = item.duration
        if dur.isValid && dur.isNumeric {
            let maxFrame = max(0, dur.seconds - 0.04)
            if current.seconds >= maxFrame {
                time = CMTime(seconds: maxFrame, preferredTimescale: 600)
            }
        }
        let subject = playingVideoURL.map { "\($0.deletingPathExtension().lastPathComponent) frame" }
            ?? "Recording frame"
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        Task { @MainActor in
            do {
                let result = try await generator.image(at: time)
                let saved = try ImageImporter.importImage(
                    result.image, subject: subject,
                    saveFolder: config.saveFolder, filenameFormat: config.filenameFormat,
                    includeTitle: FilenameIncludesTitlePreference().enabled)
                MetadataCoordinator.shared.start(for: saved, sourceApp: nil, windowTitle: subject)
                ActivityHighlightStore.shared.mark([saved])
                recentStrip.refresh()
            } catch {
                os_log("frame capture failed: %{public}@", log: log, type: .error,
                       String(describing: error))
            }
        }
    }

    /// Summarize the whole video: sample frames across the clip (uniform ~3s,
    /// capped at 30, spread end to end), OCR each, dedup, then hand the
    /// timestamped text to the on-device model. Shows a determinate progress
    /// overlay with Cancel; all work is cooperatively cancellable.
    func summarizeCanvasVideo() {
        guard AIAvailability.isFoundationModelAvailable, AIFeaturePreference().enabled,
              videoSummaryTask == nil, let item = canvasVideoPlayer?.currentItem else { return }
        let asset = item.asset
        let times = VideoSummary.sampleTimes(durationSeconds: item.duration.seconds)
        guard !times.isEmpty else { return }
        canvasVideoPlayer?.pause()
        canvas?.suppressHoverCursor = true

        let progress = CanvasProgress()
        progress.label = "Reading frames…"
        showCanvasProgressOverlay(progress: progress) { [weak self] in self?.videoSummaryTask?.cancel() }

        videoSummaryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.videoSummaryTask = nil
                self.hideCanvasProgressOverlay()
                self.canvas?.suppressHoverCursor = false
            }
            let recognizer = TextRecognizer()
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            // Downscale before OCR — Vision on full-res frames is the bottleneck;
            // text stays legible at this size. Loose tolerance: exact frames
            // don't matter for sampling and are faster.
            generator.maximumSize = CGSize(width: 1280, height: 1280)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.75, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.75, preferredTimescale: 600)

            var frames: [VideoSummary.FrameText] = []
            for (i, t) in times.enumerated() {
                if Task.isCancelled { return }
                let cm = CMTime(seconds: t, preferredTimescale: 600)
                if let cg = try? await generator.image(at: cm).image,
                   let layout = try? await recognizer.recognize(cg) {
                    frames.append(.init(timeSeconds: t,
                                        text: layout.lines.map(\.text).joined(separator: "\n")))
                }
                progress.fraction = Double(i + 1) / Double(times.count)
            }
            if Task.isCancelled { return }

            let deduped = VideoSummary.dedupe(frames)
            guard !deduped.isEmpty else {
                self.presentAIError("This video has no readable text.")
                return
            }
            let ocrText = VideoSummary.aggregate(deduped)
            progress.label = "Summarizing…"
            progress.fraction = 1

            var result: String?
            if #available(macOS 26, *) {
                if case let .text(t) = await FoundationTextActions().summarize(ocrText: ocrText) {
                    result = t
                }
            }
            if Task.isCancelled { return }
            guard let text = result, !text.isEmpty else {
                self.presentAIError("Apple Intelligence couldn't produce a result. Try again.")
                return
            }
            self.presentAIResult(title: "Video Summary", body: text)
        }
    }

    private var progressActionTask: Task<Void, Never>?

    /// Standard staged-progress + cancel for any long action. Shows the on-canvas
    /// overlay, runs `work` (which updates the passed `CanvasProgress`); Cancel →
    /// `task.cancel()`; the overlay hides on finish/cancel. `onResult` runs only on
    /// a non-nil result (nil = nothing to show, e.g. empty/cancelled).
    @MainActor
    func runWithCanvasProgress<T>(label: String,
                                  work: @escaping (CanvasProgress) async -> T?,
                                  onResult: @escaping (T) -> Void) {
        guard progressActionTask == nil, canvasHost != nil else { return }
        let progress = CanvasProgress()
        progress.label = label
        canvas?.suppressHoverCursor = true
        // Tool blocking is owned by showCanvasProgressOverlay/hideCanvasProgressOverlay
        // now that every user of the shared overlay gets it.
        showCanvasProgressOverlay(progress: progress) { [weak self] in self?.progressActionTask?.cancel() }

        // "Taking a moment…" secondary line after 7s, matching Smart Redaction.
        let watchdog = Task { @MainActor [weak progress] in
            try? await Task.sleep(nanoseconds: 7_000_000_000)
            if !Task.isCancelled { progress?.note = "This is taking a moment…" }
        }

        progressActionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                watchdog.cancel()
                self.progressActionTask = nil
                self.hideCanvasProgressOverlay()   // also releases the tool block
                self.canvas?.suppressHoverCursor = false
            }
            let result = await work(progress)
            guard !Task.isCancelled, let result else { return }
            onResult(result)
        }
    }

    /// Live Text progress on the shared canvas overlay — the same one Smart
    /// Redaction and Extract Data use, so the card, type and Cancel button are
    /// inherited rather than re-created. `label` nil tears it down.
    ///
    /// Indeterminate: recognition reports no fraction, and a determinate bar
    /// pinned at 0% reads as stuck.
    private var liveTextProgress: CanvasProgress?

    func showLiveTextProgress(_ label: String?) {
        guard let label else {
            // Only tear down an overlay Live Text still OWNS. A cancelled read's
            // task `defer` reports "finished" asynchronously, after the cancel
            // already dismissed the card — and by then another feature may hold
            // the shared overlay. Without this guard that late signal dismissed
            // a redaction scan's overlay the moment it appeared.
            guard liveTextProgress != nil else { return }
            liveTextProgress = nil
            hideCanvasProgressOverlay()
            return
        }
        // Already showing (recognize → enhance → recognize re-labels mid-run):
        // update in place rather than tearing the card down and back up.
        if let liveTextProgress {
            liveTextProgress.label = label
            return
        }
        let progress = CanvasProgress()
        progress.label = label
        progress.isIndeterminate = true
        liveTextProgress = progress
        showCanvasProgressOverlay(progress: progress) { [weak self] in
            guard let self else { return }
            // Cancel the read, then restore the base and leave the tool — a
            // text tool with no layout is dead, and staying in it would let the
            // next state change restart the very read just cancelled.
            self.canvas?.cancelLiveTextRecognition()
            if self.state?.cancelLiveTextRead() == true { self.onEnhanceCancel?() }
        }
    }

    func showCanvasProgressOverlay(progress: CanvasProgress,
                                   onCancel: @escaping () -> Void) {
        guard canvasProgressOverlay == nil, let host = canvasHost else { return }
        // Disable the tools for the duration, matching Extract Data
        // (`runWithCanvasProgress`) and Enhance (`showEnhancingOverlay`), which
        // both already did this. Redaction — and now Live Text — went through
        // here and left every tool live under a blocking overlay.
        let overlay = NSHostingView(rootView: CanvasProgressOverlayView(progress: progress, onCancel: onCancel))
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.sizingOptions = []   // edge-pinned; avoid window-size-extrema reentrancy
        for axis in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            overlay.setContentHuggingPriority(.init(1), for: axis)
            overlay.setContentCompressionResistancePriority(.init(1), for: axis)
        }
        host.addSubview(overlay)   // added last → sits on top of canvas/video
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: host.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        canvasProgressOverlay = overlay
        os_log("blocking overlay: canvas progress shown", log: log, type: .info)
        updateBlockingUIState()
    }

    /// Idempotent: several cancel/finish paths call this, and a hide with
    /// nothing up is a no-op — same rule as `hideEnhancingOverlay`.
    func hideCanvasProgressOverlay() {
        guard canvasProgressOverlay != nil else { return }
        canvasProgressOverlay?.removeFromSuperview()
        canvasProgressOverlay = nil
        os_log("blocking overlay: canvas progress hidden", log: log, type: .info)
        updateBlockingUIState()
    }

    /// Test hook: whether the shared canvas-progress overlay is currently up.
    var debugCanvasProgressOverlayVisible: Bool { canvasProgressOverlay != nil }

    /// Tear down the in-canvas player and reveal the canvas underneath.
    func dismissCanvasVideo() {
        guard videoOverlay != nil else { return }
        videoSummaryTask?.cancel()
        // Background metadata generation is owned by VideoMetadataCoordinator and
        // intentionally keeps running after the user navigates away, so the work
        // isn't wasted.
        hideCanvasProgressOverlay()
        canvasVideoPlayer?.pause()
        canvasVideoView?.teardown()
        canvasVideoView = nil
        metaRow?.setZoomDisplayOverride(nil)   // meta row back to the image zoom
        canvasVideoPlayer = nil
        sealedCanvasVideoPlayer = nil
        canvasVideoPayloadLoader = nil
        playingVideoURL = nil
        state?.playingVideoURL = nil
        videoOverlay?.removeFromSuperview()
        videoOverlay = nil
        canvas?.suppressHoverCursor = false
        toolbarBuilder.setVideoMode(false)   // restore image-only tools
        sidebar?.setVideoMode(false)         // restore tool properties panel
        // Back to the underlying image: restore the title bar (name/favorite)
        // and re-enable inline rename.
        titleLabel?.isEditable = true
        updateTitleRow()
    }

    private func dismissRecoverySheet() {
        guard let sheetWindow = recoverySheetWindow else { return }
        // Clear the reference first so a re-open is never blocked even if the
        // window is gone underneath us.
        recoverySheetWindow = nil
        window?.endSheet(sheetWindow)
        sheetWindow.orderOut(nil)
    }
}

extension EditorWindowController {
    /// Rename requested from the Info panel's editable Name field. Targets
    /// what the title bar represents: the playing video when there is one,
    /// else the open capture. Same guards the old title-field edit had.
    func handleInfoPanelRename(to entered: String) {
        guard let url = playingVideoURL ?? window?.representedURL,
              url.pathExtension == "seal",
              state?.isReadOnly != true else { updateTitleRow(); return }
        let trimmed = entered.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { updateTitleRow(); return }
        renameCapture(at: url, to: trimmed)
    }

    // MARK: - Undo / redo (with rename reconciliation)

    /// ⌘Z pops the next entry off the app-global timeline (`GlobalUndoStore`),
    /// whatever kind it is, in push order.
    // MARK: - Zoom routing (video-aware)
    // Every zoom entry point (menu, meta row, window bar) routes to the
    // in-canvas video player while a video session is active, else to the
    // image canvas scroll view. Fit-width/height/focus have no video variant —
    // they map to plain fit.

    private func routedZoomIn() {
        if let v = canvasVideoView { v.zoomIn() } else { canvasScroll?.zoomIn() }
    }
    private func routedZoomOut() {
        if let v = canvasVideoView { v.zoomOut() } else { canvasScroll?.zoomOut() }
    }
    private func routedSetZoom(_ z: CGFloat) {
        if let v = canvasVideoView { v.setZoom(z) } else { canvasScroll?.setZoom(z) }
    }
    private func routedFitWindow() {
        state?.checkpointZoomIfNeeded()
        if let v = canvasVideoView { v.fitToWindow() } else { canvasScroll?.fitToWindow() }
    }
    private func routedActualSize() {
        if let v = canvasVideoView { v.actualSize() } else { canvasScroll?.actualSize() }
    }
    private func routedFitWidth() {
        state?.checkpointZoomIfNeeded()
        if let v = canvasVideoView { v.fitToWindow() } else { canvasScroll?.fitToWidth() }
    }
    private func routedFitHeight() {
        state?.checkpointZoomIfNeeded()
        if let v = canvasVideoView { v.fitToWindow() } else { canvasScroll?.fitToHeight() }
    }
    private func routedFocus() {
        state?.checkpointZoomIfNeeded()
        if let v = canvasVideoView { v.fitToWindow() } else { canvasScroll?.fitFocusOrWindow() }
    }

    // MARK: - Menu (View) actions

    func zoomIn() { routedZoomIn() }
    func zoomOut() { routedZoomOut() }
    /// Runs `body` only when the canvas of a KEY editor window has focus and
    /// the document is editable. Menu-bar items and key equivalents both land
    /// here: AppKit offers key equivalents to the main menu BEFORE the window,
    /// and a window keeps its first responder while not key — so without the
    /// key-window check ⌘D would mutate the document behind a sheet (e.g. the
    /// Send Feedback composer) or a panel (Sparkle update, NSColorPanel, the
    /// Extract window) that's key on top of it. Mouse-driven paths (the
    /// context menu) are unaffected — menu tracking does not resign key.
    private func withFocusedCanvas(_ body: (EditorState, EditorCanvasView) -> Void) {
        guard let state, let canvas,
              window?.isKeyWindow == true, window?.firstResponder === canvas,
              !state.isReadOnly else { return }
        body(state, canvas)
    }
    /// Menu-bar Edit▸Duplicate and the ⌘D key equivalent both land here.
    func duplicateSelection() {
        withFocusedCanvas { state, canvas in
            state.duplicateSelected()
            canvas.needsDisplay = true
        }
    }
    /// Menu-bar Edit▸Arrange and the ⌘]/⌘[ key equivalents both land here.
    func reorderSelection(_ op: ZOrderOperation) {
        withFocusedCanvas { state, canvas in
            state.reorderSelected(op)
            canvas.needsDisplay = true
        }
    }
    /// Menu-bar Edit▸Flip.
    func flipSelection(horizontal: Bool) {
        withFocusedCanvas { state, canvas in
            state.flipSelected(horizontal: horizontal)
            canvas.needsDisplay = true
        }
    }
    func zoomActualSize() { routedActualSize() }
    func fitWindow() { routedFitWindow() }
    func fitWidth() { routedFitWidth() }
    func fitHeight() { routedFitHeight() }
    func toggleInfoPanel() {
        // Info and Smart Redact are mutually exclusive — opening Info cancels an
        // active redaction (mirrors the toolbar 'i' pill).
        cancelRedactionIfActive()
        if state?.showsImageTextSearchPanel == true {
            state?.userSelectedTool(.select)
        }
        state?.toggleInfoPanel()
    }
    func toggleRecentStrip() { toggleStripHidden() }
    /// Extensions treated as video for "Export to Image" (first-frame export).
    private static let exportVideoExtensions: Set<String> = ["mov", "mp4", "m4v", "sealrec"]

    func exportCurrent() {
        // A video playing in the canvas exports the VIDEO itself (decrypt the
        // .seal out to a plaintext .mov/.mp4), not a first-frame image.
        if let videoURL = playingVideoURL {
            let source = SharePackageSource(url: videoURL,
                                           displayName: CaptureDisplayName.resolve(for: videoURL),
                                           isVideo: true)
            VideoExportCoordinator.present(sources: [source], host: window)
            return
        }
        guard let state, let url = state.sourceURL else { return }
        let isVideo = Self.exportVideoExtensions.contains(url.pathExtension.lowercased())
        let source = SharePackageSource(url: url,
                                       displayName: CaptureDisplayName.resolve(for: url),
                                       isVideo: isVideo)
        ExportImageCoordinator.present(sources: [source], host: window)
    }

    /// "Export to Video…" — decrypt the open recording out to a plaintext
    /// movie. Unlike `exportCurrent()`, which only takes the video path while a
    /// video is actually playing, this is an explicit request for the video, so
    /// it works whether or not playback has started.
    func exportCurrentAsVideo() {
        guard let url = playingVideoURL ?? state?.sourceURL else { return }
        let source = SharePackageSource(url: url,
                                        displayName: CaptureDisplayName.resolve(for: url),
                                        isVideo: true)
        VideoExportCoordinator.present(sources: [source], host: window)
    }

    func exportAsPackage() {
        guard let state, let sourceURL = state.sourceURL else { return }
        let name = sourceURL.deletingPathExtension().lastPathComponent
        let source = SharePackageSource(url: sourceURL, displayName: name, isVideo: false)
        ExportPackageCoordinator.present(sources: [source], host: window)
    }

    func handleUndo() { performTimelineStep(redo: false) }
    func handleRedo() { performTimelineStep(redo: true) }

    /// Perform ONE ⌘Z (or ⌘⇧Z) step off the app-global timeline: prune dead
    /// tops, pop the next live entry, and dispatch on its kind. All five kinds
    /// push their counterpart onto the opposite stack so the round trip works.
    private func performTimelineStep(redo: Bool) {
        // The undo/redo timeline is app-global, so ⌘Z/⌘⇧Z work from any strip
        // tab. In particular, undoing a capture/import (or redoing a delete)
        // moves the item to Deleted and switches to that tab via
        // `showStripTab(.deleted)` — the step must NOT be gated on the tab, or
        // that switch would trap the user (redo silently no-ops on Deleted). The
        // step handlers navigate to the item they act on, keeping the view
        // coherent.
        pruneTimeline(redo: redo)
        UndoDiag.mark("\(redo ? "⌘⇧Z" : "⌘Z") on \(UndoDiag.name(state?.sourceURL)) "
            + "→ \(String(describing: (redo ? globalUndo.topRedo : globalUndo.topUndo)?.kind)) "
            + "(u:\(globalUndo.undoStack.count) r:\(globalUndo.redoStack.count))")
        guard let entry = redo ? globalUndo.popRedo() : globalUndo.popUndo() else {
            presentActionHint(verb: redo ? "Nothing to redo" : "Nothing to undo", action: nil)
            updateUndoRedoButtons()
            return
        }
        isPerformingUndoRedo = true
        defer { isPerformingUndoRedo = false; updateUndoRedoButtons() }
        let verb = redo ? "Redo" : "Undo"
        switch entry.kind {
        case .edit(let capture, let snapshot):
            performEditStep(entry: entry, capture: capture, snapshot: snapshot, redo: redo, verb: verb)
        case .fileEvent(let event):
            presentActionHint(verb: verb, action: Self.fileEventLabel(event.kind),
                              itemName: event.items.count == 1
                                  ? event.items[0].originalURL.lastPathComponent : nil)
            performFileEvent(event, redo: redo)
        case .navigation(let from, let to):
            performNavigationStep(entry: entry, from: from, to: to, redo: redo, verb: verb)
        case .videoMetadata(let item, let before, let after):
            performVideoMetadataStep(entry: entry, item: item, before: before, after: after,
                                     redo: redo, verb: verb)
        case .revert(let capture):
            performRevertStep(capture: capture, redo: redo, verb: verb)
        }
    }

    /// Drop fully-dead entries from the top of the chosen stack before a step,
    /// so a dead entry never eats a ⌘Z press or shows a toast for an action
    /// that can no longer happen.
    private func pruneTimeline(redo: Bool) {
        globalUndo.pruneDeadTop(
            redo: redo,
            fileExists: { FileManager.default.fileExists(atPath: $0.path) },
            revertAvailable: { [weak self] url in
                guard let self else { return false }
                return (redo ? self.revertHistory.canRedo : self.revertHistory.canUndo)
                    && self.state?.sourceURL == url
            },
            scratchAlive: state?.sourceURL == nil && state != nil)
    }

    /// Apply an annotation/canvas `.edit` snapshot. The entry may belong to a
    /// different item than the one displayed (a pruned navigation entry, or
    /// history from before a crash) — open it first so `applySnapshot` lands on
    /// the right document. Size-aware: a snapshot in a different base size takes
    /// the rebuild path (`restoreAcrossResize`).
    private func performEditStep(entry: GlobalUndoEntry, capture: URL?, snapshot: EditorSnapshot,
                                 redo: Bool, verb: String) {
        // Capture "is this a cross-item jump" against the item on screen
        // BEFORE opening — `onRecentClickStored` below updates
        // `window.representedURL`/`state.sourceURL` to `capture`, so comparing
        // AFTER the open would always read as same-item and the toast would
        // never name the target.
        let crossItemName: String? = (capture != nil && capture != state?.sourceURL)
            ? capture?.lastPathComponent : nil
        if let capture, capture != state?.sourceURL {
            onRecentClickStored(capture)   // isPerformingUndoRedo is set
            // N1: the cross-item open can FAIL with the file still on disk
            // (corrupt package, AnnotationCodecError.unsupportedVersion from a
            // newer build, locked package) — `presentFile` early-returns via
            // `presentOpenFailure`, leaving the OLD document in place. Because
            // the file still exists, `pruneDeadTop`'s fileExists check kept the
            // entry, so we got here. Applying `snapshot` now would overwrite the
            // OLD doc's annotations/crop, repoint its sourceURL, and rename its
            // file — corrupting two documents on one ⌘Z. Guard that the open
            // actually landed on `capture`; if not, push the popped entry back
            // onto the stack it came from (pushes never clear redo, so this is
            // loss-free, and the ORIGINAL entry preserves `at` for ordering) and
            // bail without minting a counterpart or applying anything.
            // `presentOpenFailure` has already shown the real error sheet, so
            // the toast here is minimal.
            guard state?.sourceURL == capture else {
                if redo { globalUndo.pushRedo(entry) } else { globalUndo.pushUndo(entry) }
                updateUndoRedoButtons()
                presentActionHint(verb: "\(verb) failed", action: nil, itemName: crossItemName)
                return
            }
        }
        guard let state else { return }
        let counterpart = GlobalUndoEntry(at: Date(),
            kind: .edit(capture: state.sourceURL, snapshot: state.counterpartSnapshot(for: snapshot)))
        if redo { globalUndo.pushUndo(counterpart) } else { globalUndo.pushRedo(counterpart) }
        if state.snapshotRequiresRebuild(snapshot) {
            // The rebuild path swaps in a fresh state; park the trio on the OLD
            // state so restoreAcrossResize can write it after the file move.
            state.parkRestoredMetadata(from: snapshot)
            restoreAcrossResize(snapshot)
        } else {
            // In-place: apply, then reconcile a rename-undo's file move and any
            // parked metadata trio (mirrors the retired `applyHistory`).
            let diskURL = state.sourceURL
            state.applySnapshot(snapshot)
            if let from = diskURL, let to = state.sourceURL, from != to {
                moveCaptureFile(from: from, to: to)
            }
            applyRestoredMetadataIfAny(state)
        }
        presentActionHint(verb: verb, action: snapshot.action, itemName: crossItemName)
        scheduleAutosave()
    }

    /// Undo/redo a navigation step: show `from` on undo, `to` on redo. The
    /// entry is its own counterpart — push it unchanged onto the opposite
    /// stack (the store's `.navigation` coalescing already merged consecutive
    /// clicks and dropped round trips before this was ever popped).
    private func performNavigationStep(entry: GlobalUndoEntry, from: URL?, to: URL?,
                                       redo: Bool, verb: String) {
        if redo { globalUndo.pushUndo(entry) } else { globalUndo.pushRedo(entry) }
        let target = redo ? to : from
        if let target {
            openItem(target)
            presentActionHint(verb: verb,
                              action: isVideoPackage(target) ? "Switch Video" : "Switch Image",
                              itemName: target.lastPathComponent)
        }
        // target == nil is the scratch-canvas endpoint of the entry: pruned
        // upstream when the scratch session is dead; if it's still alive it
        // IS the current state, so there's nothing to switch to.
    }

    /// Open an item by URL the same way a strip click does. `onRecentClickStored`
    /// (→ `EditorController.presentFile`) handles both images and video `.seal`
    /// packages — the latter delegates to `presentRecording` → `playVideoInCanvas`
    /// internally — so one call covers both media types.
    private func openItem(_ url: URL) { onRecentClickStored(url) }

    /// Undo/redo a metadata-only edit (title/summary/tags) to a video
    /// capture. `writeRestoredMetadata` only rewrites manifest fields — it
    /// never moves the file — so there's no rename-file-move race to
    /// reconcile here: `item` stays valid across the write. (A file move
    /// from an UNRELATED later rename is repointed generically by
    /// `renameCapture`, independent of push order.)
    private func performVideoMetadataStep(entry: GlobalUndoEntry, item: URL,
                                          before: MetadataUndoPatch, after: MetadataUndoPatch,
                                          redo: Bool, verb: String) {
        if redo { globalUndo.pushUndo(entry) } else { globalUndo.pushRedo(entry) }
        writeRestoredMetadata(redo ? after : before, at: item)
        let action = before.tags != after.tags ? "Edit Tags"
            : before.userSummary != after.userSummary ? "Edit Summary" : "Rename"
        presentActionHint(verb: verb, action: action, itemName: item.lastPathComponent)
    }

    /// Discard all edits and return to the pristine original. Undoable for the
    /// session: the revert payload lives on `revertHistory` (whole states), and
    /// a `.revert` marker lands on the global timeline to keep ⌘Z ordering.
    func revertToOriginal() {
        guard let state, !state.isReadOnly, state.hasEdits else { return }
        let reverted = state.revertedToOriginal()
        revertHistory.record(previous: state, reverted: reverted)
        // A scratch canvas has no on-disk pristine to revert to, so this guard
        // implies a real sourceURL; record the marker only when one exists.
        if let url = state.sourceURL { globalUndo.record(.revert(capture: url)) }
        let title = window?.title ?? state.sourceURL?.lastPathComponent ?? "Untitled"
        ImageZoomMemory.store(state.zoom, for: state.sourceURL)
        swap(toState: reverted, title: title, fitFresh: false)
        updateUndoRedoButtons()
        scheduleAutosave()
    }

    /// Undo/redo a "Revert to Original": the whole-state payload lives on
    /// `revertHistory`; the global timeline only carries the `.revert` marker
    /// and its counterpart, keeping ⌘Z ordering across the other kinds.
    private func performRevertStep(capture: URL, redo: Bool, verb: String) {
        let entry = redo ? revertHistory.popRedo() : revertHistory.popUndo()
        guard let entry else { updateUndoRedoButtons(); return }   // pruned upstream; belt-and-braces
        if redo { revertHistory.pushUndo(entry) } else { revertHistory.pushRedo(entry) }
        globalUndo.pushCounterpart(.revert(capture: capture), redo: redo)
        let target = redo ? entry.reverted : entry.previous
        let title = window?.title ?? target.sourceURL?.lastPathComponent ?? "Untitled"
        ImageZoomMemory.store(state?.zoom ?? target.zoom, for: target.sourceURL)
        swap(toState: target, title: title, fitFresh: false)
        // After the swap so the toast lands atop the new canvas.
        presentActionHint(verb: verb, action: "Revert to Original")
        scheduleAutosave()
    }

    /// Show a transient "Undo: <action>" / "Redo: <action>" hint over the
    /// canvas (just the verb when there's no labelled action). An optional
    /// `itemName` names the item when the step acted on a non-displayed capture.
    private func presentActionHint(verb: String, action: String?, itemName: String? = nil) {
        guard let host = canvasHost ?? window?.contentView else { return }
        EditorToastView.show(Self.actionHintMessage(verb: verb, action: action, itemName: itemName),
                             in: host)
    }

    /// Pure copy formatter behind `presentActionHint` — split out so the toast
    /// copy style ("Undo: Add Arrow — shot-42", "Nothing to undo") is unit
    /// testable without a window (`presentActionHint`'s canvas-host lookup
    /// isn't). `action == nil` renders the bare verb (used for the empty-stack
    /// "Nothing to undo"/"Nothing to redo" hint and `.revert`'s label-less path).
    static func actionHintMessage(verb: String, action: String?, itemName: String? = nil) -> String {
        var message = action.map { "\(verb): \($0)" } ?? verb
        if let itemName { message += " — \(itemName)" }
        return message
    }

    /// Perform ONE capture file-event step (delete / restore / import /
    /// capture) off the global timeline: the same 4-kind restore/delete matrix
    /// as before, but the counterpart lands on `globalUndo` instead of a
    /// per-domain stack. Items already gone (manually restored, purged) are
    /// skipped; a fully-gone event falls away leaving no counterpart.
    private func performFileEvent(_ event: DeletionUndoHistory.Event, redo: Bool) {
        UndoDiag.note("\(redo ? "redo" : "undo") file-event \(event.kind.rawValue) "
            + "(\(event.items.count) items, openFile:\(event.containedOpenFile))")
        let pushCounterpart: (DeletionUndoHistory.Event) -> Void = { [weak self] counterpart in
            guard let self else { return }
            let entry = GlobalUndoEntry(at: Date(), kind: .fileEvent(counterpart))
            if redo { self.globalUndo.pushUndo(entry) } else { self.globalUndo.pushRedo(entry) }
        }
        switch (event.kind, redo) {
        case (.deletion, false), (.restoration, true), (.importation, true), (.capture, true):
            restoreBatch(event) { restored in
                pushCounterpart(.init(items: restored, kind: event.kind,
                                      containedOpenFile: event.containedOpenFile, at: Date()))
            }
        case (.deletion, true), (.restoration, false), (.importation, false), (.capture, false):
            deleteBatch(event) { result in
                pushCounterpart(.init(items: result.items, kind: event.kind,
                                      containedOpenFile: result.containedOpenFile, at: Date()))
            }
        }
    }

    /// Undo/redo hint label for a file-level event. Internal (not `private`)
    /// so the toast copy audit can unit test it directly — see
    /// `actionHintMessage` just above for why the presentation itself isn't.
    static func fileEventLabel(_ kind: DeletionUndoHistory.Kind) -> String {
        switch kind {
        case .deletion: return "Delete capture"
        case .restoration: return "Restore capture"
        case .importation: return "Import"
        case .capture: return "Capture"
        }
    }

    /// Restore an event's items from Deleted/, reopen the file if the event
    /// carried the then-open one, refresh the strip/Library, and hand the
    /// post-restore items to `pushCounterpart` (the redo/undo side). Items
    /// already gone (manually restored, purged) are skipped; a fully-gone
    /// event falls away leaving no counterpart. Fully SYNCHRONOUS — the
    /// `onRecentClickStored(reopen)` reopen below runs before
    /// `performTimelineStep`'s `defer` resets `isPerformingUndoRedo`, so it
    /// needs no extra suppression (contrast `deleteBatch`, which is async).
    private func restoreBatch(_ event: DeletionUndoHistory.Event,
                              pushCounterpart: ([DeletionUndoHistory.Item]) -> Void) {
        var restored: [DeletionUndoHistory.Item] = []
        for item in event.items {
            do {
                // Restore to the file's original directory so videos land back
                // in Recordings/ (not the captures save folder); images and
                // recordings share one Deleted/ trash but separate homes.
                let back = try SealDeleter.restore(
                    url: item.trashedURL,
                    toFolder: item.originalURL.deletingLastPathComponent())
                restored.append(.init(trashedURL: item.trashedURL, originalURL: back))
            } catch {
                os_log("restore failed for %{public}@: %{public}@",
                       log: log, type: .error, item.trashedURL.path, String(describing: error))
            }
        }
        guard !restored.isEmpty else { refreshRecentStrip(); updateUndoRedoButtons(); return }
        pushCounterpart(restored)
        if event.containedOpenFile, let reopen = restored.first?.originalURL {
            onRecentClickStored(reopen)
        }
        libraryViewModel?.reload()
        updateUndoRedoButtons()
        ActivityHighlightStore.shared.mark(restored.map(\.originalURL))
        // Restored items land in Recent — show that tab so the highlight is
        // visible (also refreshes the strip).
        showStripTab(.recent)
    }

    /// Re-delete an event's items through the shared core (open-file neighbor
    /// switch included), then hand the fresh Deleted/ locations to
    /// `pushCounterpart`. ASYNC — `performBulkDelete`'s open-file neighbor
    /// switch (`recentStrip.handlePlainClick` → `onRecentClickStored` →
    /// `presentFile`) can run after this method returns, i.e. after
    /// `performTimelineStep`'s `defer` has already reset `isPerformingUndoRedo`.
    /// `navigationSuppressionCount` bridges that gap so the reopen isn't
    /// mistaken for a user click and doesn't mint its own `.navigation` entry.
    /// Increment/decrement (not set/clear) — a second overlapping call (rapid
    /// ⌘Z ⌘Z across two file events) increments again on top of a still-
    /// pending first Task, taking the count to 2; suppression only lifts once
    /// BOTH Tasks' `defer`s have run and the count is back to 0.
    private func deleteBatch(_ event: DeletionUndoHistory.Event,
                             pushCounterpart: @escaping ((items: [DeletionUndoHistory.Item], containedOpenFile: Bool)) -> Void) {
        navigationSuppressionCount += 1
        Task { @MainActor in
            defer {
                if navigationSuppressionCount > 0 {
                    navigationSuppressionCount -= 1
                } else {
                    assertionFailure("navigationSuppressionCount underflow: deleteBatch's Task defer ran with count already at 0")
                }
            }
            let result = await performBulkDelete(event.items.map(\.originalURL))
            guard !result.items.isEmpty else { refreshRecentStrip(); updateUndoRedoButtons(); return }
            pushCounterpart(result)
            libraryViewModel?.reload()
            updateUndoRedoButtons()
            ActivityHighlightStore.shared.mark(result.items.map(\.trashedURL))
            // Re-deleted items land in Deleted — show that tab so the user
            // sees where they went, highlighted (also refreshes the strip).
            showStripTab(.deleted)
        }
    }

    /// Switch the bottom strip to `tab`, mount it, and refresh both strips so
    /// the just-moved item appears (highlighted) in its destination.
    private func showStripTab(_ tab: BottomTab) {
        state?.bottomTab = tab
        currentTab = tab
        metaRow?.setActiveTab(tab)
        mountStrip(for: tab)
        switch tab {
        case .recent: deletedStrip?.refresh()
        case .deleted: recentStrip.refresh()
        }
    }

    /// A popped metadata step (rename/summary/tags) parks its pre-edit trio
    /// on the state; write it back to the manifest AFTER any file move (a
    /// rename undo relocates the `.seal` first — the write must target where
    /// the file actually is). Suppressed from re-minting its own checkpoint.
    private func applyRestoredMetadataIfAny(_ state: EditorState) {
        guard let patch = state.consumePendingRestoredMetadata(),
              let url = state.sourceURL else { return }
        writeRestoredMetadata(patch, at: url)
    }

    private func writeRestoredMetadata(_ patch: MetadataUndoPatch, at url: URL) {
        suppressMetadataCheckpoints = true
        defer { suppressMetadataCheckpoints = false }
        try? SealMetadataStore.update(at: url, createIfMissing: true) { m in
            m.userTitle = patch.userTitle
            m.userSummary = patch.userSummary
            m.tags = patch.tags
        }
        NotificationCenter.default.post(name: .captureMetadataDidChange, object: url)
        updateTitleRow()
    }

    /// Move the open `.seal` from `from` to `to` (undo/redo of a rename) and
    /// re-point every reference. De-collides if the target name was reused.
    private func moveCaptureFile(from: URL, to: URL) {
        let folder = to.deletingLastPathComponent()
        var dest = to
        if FileManager.default.fileExists(atPath: dest.path) {
            let unique = CaptureConfig.uniqueName(
                base: to.deletingPathExtension().lastPathComponent, ext: to.pathExtension,
                exists: { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) })
            dest = folder.appendingPathComponent(unique)
            state?.sourceURL = dest   // keep the model in sync with the de-collided name
        }
        autosaveWorkItem?.cancel()
        do {
            try FileManager.default.moveItem(at: from, to: dest)
            globalUndo.renameCapture(from: from, to: dest)
            setRepresentedCapture(dest, on: window)
            recentStrip.selectedURL = dest
            setWindowTitle(dest.deletingPathExtension().lastPathComponent)
            NotificationCenter.default.post(name: .captureMetadataDidChange, object: dest)
        } catch {
            os_log("undo/redo rename move failed %{public}@ → %{public}@: %{public}@", log: log,
                   type: .error, from.lastPathComponent, dest.lastPathComponent, String(describing: error))
            state?.sourceURL = from   // model must point at the file's real location
            updateTitleRow()
        }
    }

    /// Set the window's represented capture URL and keep `OpenCaptureRegistry`
    /// in sync, so background work (the metadata-pipeline auto-rename) can tell
    /// which capture is currently open in the editor and skip renaming it.
    private func setRepresentedCapture(_ url: URL?, on win: NSWindow?) {
        if let old = win?.representedURL { OpenCaptureRegistry.shared.remove(old) }
        win?.representedURL = url
        if let url { OpenCaptureRegistry.shared.add(url) }
    }

    /// Rename the open capture to a metadata-pipeline-supplied base name (which
    /// already carries the timestamp), de-collided against the folder. Mirrors
    /// `renameCapture`'s reference-repointing but is automatic, so it records no
    /// undo checkpoint. A base that resolves to the current name is a no-op.
    private func autoRenameRepresentedCapture(toBase base: String) {
        guard let url = window?.representedURL, url.pathExtension == "seal" else { return }
        let folder = url.deletingLastPathComponent()
        let newName = CaptureConfig.uniqueName(base: base, ext: "seal") {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
        let newURL = folder.appendingPathComponent(newName, isDirectory: false)
        guard newURL != url else { return }   // already named correctly
        autosaveWorkItem?.cancel()            // the pending autosave targeted the old URL
        do {
            try FileManager.default.moveItem(at: url, to: newURL)
            globalUndo.renameCapture(from: url, to: newURL)
            state?.sourceURL = newURL
            setRepresentedCapture(newURL, on: window)
            recentStrip.selectedURL = newURL
            setWindowTitle(newURL.deletingPathExtension().lastPathComponent)
            NotificationCenter.default.post(name: .captureMetadataDidChange, object: newURL)
        } catch {
            os_log("auto title-rename failed %{public}@ → %{public}@: %{public}@", log: log,
                   type: .error, url.lastPathComponent, newName, String(describing: error))
        }
    }

    /// Editing the title renames the `.seal` on disk to exactly the typed title
    /// (sanitized, de-collided — no timestamp), and re-points every reference
    /// (state, represented URL, recent strip, window title, Library). A title
    /// equal to the current name is a no-op, so repeated commits don't compound.
    private func renameCapture(at url: URL, to title: String) {
        let folder = url.deletingLastPathComponent()
        guard let newName = CaptureConfig.renameTargetName(
            currentName: url.lastPathComponent, title: title, ext: "seal",
            exists: { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) })
        else { updateTitleRow(); return }  // unchanged
        let newURL = folder.appendingPathComponent(newName)

        autosaveWorkItem?.cancel()  // the pending autosave targeted the old URL
        do {
            try FileManager.default.moveItem(at: url, to: newURL)
            // Read the pre-edit trio BEFORE writing the title, so the rename's
            // checkpoint can restore the manifest (display names prefer
            // `userTitle`, so undoing only the file move would look like a
            // no-op). The write is suppressed from the metadata-undo hook —
            // this one checkpoint covers both the move and the title.
            let preTrio = MetadataUndoPatch(
                from: (try? SealMetadataStore.readManifest(at: newURL))?.metadata)
            // The display name prefers metadata `userTitle` over the filename
            // (Library renames set only the title) — record the entered name
            // there too, or a capture with an earlier title would keep showing
            // it and this rename would appear to revert.
            suppressMetadataCheckpoints = true
            try? SealMetadataStore.update(at: newURL, createIfMissing: true) {
                $0.userTitle = title
            }
            suppressMetadataCheckpoints = false
            // Repoint any existing timeline entries for the old path, then
            // record the rename step so it's undoable via ⌘Z in the same
            // timeline as edits. The snapshot captures the PRE-rename document
            // (sourceURL still the old path, so undo moves the file back), but
            // the entry is keyed to where the file now lives (newURL) so
            // pruneDeadTop doesn't treat it as gone. Built directly rather than
            // via recordUndoCheckpoint, whose onCheckpoint would key it to the
            // old (now-missing) path and immediately prune it.
            globalUndo.renameCapture(from: url, to: newURL)
            if let state {
                let snapshot = state.makeSnapshot(action: "Rename", metadata: preTrio)
                state.markDirty()
                globalUndo.record(.edit(capture: newURL, snapshot: snapshot))
            }
            state?.sourceURL = newURL
            setRepresentedCapture(newURL, on: window)
            recentStrip.selectedURL = newURL
            setWindowTitle(newURL.deletingPathExtension().lastPathComponent)
            updateUndoRedoButtons()
            NotificationCenter.default.post(name: .captureMetadataDidChange, object: newURL)
        } catch {
            os_log("rename failed %{public}@ → %{public}@: %{public}@", log: log, type: .error,
                   url.lastPathComponent, newName, String(describing: error))
            updateTitleRow()  // revert the field to the current name
        }
    }
}

// MARK: - Tabs toolbar (centered switcher on the traffic-light line)

extension EditorWindowController: NSPopoverDelegate {
    /// A field mid-edit when the Resize popover dismisses (outside click)
    /// still commits — same contract as Enter or in-popover focus loss.
    /// Called ONLY for user-initiated closes (click-outside on a transient
    /// popover, Esc) — NOT when the popover closes because the meta-row rebuild
    /// removed its anchor. So this reliably marks a genuine user dismissal.
    func popoverShouldClose(_ popover: NSPopover) -> Bool {
        if popover === resizePopover { resizePopoverUserDismissed = true }
        return true
    }

    func popoverWillClose(_ notification: Notification) {
        guard (notification.object as? NSPopover) === resizePopover else { return }
        resizePopoverModel?.commitFields()
    }
}

extension EditorWindowController: NSWindowDelegate {
    /// Fold the tool bar for the size the window is ABOUT to become.
    ///
    /// The host's layout pass (`ToolbarFitHostView`) reacts one step late: it
    /// can only report the width the window already has, and while the bar is
    /// still wide that width is the very thing the bar is clamping. Resizing
    /// then converges over several passes — a drag to the minimum visibly
    /// crawls (measured 894 → 768 → 736 → 560), and a one-shot resize (window
    /// restore, a tiling manager) stops early and simply looks stuck.
    ///
    /// This hook runs BEFORE the new size is applied, so the bar is already
    /// folded — and the constraints already relaxed — by the time AppKit works
    /// out how small the window may be. The layout path stays as the backstop
    /// for width changes that never resize the window, such as dragging the
    /// sidebar wider.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let proposedContent = sender.contentRect(
            forFrameRect: NSRect(origin: .zero, size: frameSize))
        pendingResizeContentWidth = proposedContent.width
        applyToolbarFit(availableWidth: proposedContent.width, allowUnfold: true)
        // Flush the rebuild into the constraint system NOW. AppKit works out
        // how small this resize may go from the constraints as they stand when
        // this method returns; leaving the new, narrower bar unlaid out means
        // it sizes against the OLD one and stops the drag short (measured: a
        // drag to 560 landing at 849).
        sender.contentView?.layoutSubtreeIfNeeded()
        return frameSize
    }

    /// The resize has landed. Re-fit against the NARROWER of what the user
    /// asked for and what they got.
    ///
    /// Fitting against the achieved width alone ratchets the window back open:
    /// a drag to 560 that AppKit clamps at 657 would re-fit for 657, un-fold a
    /// cluster, and so raise the minimum — which clamps the next event wider
    /// still (measured: 560 → 657 → 725, stuck). The request is the honest
    /// signal of intent; the clamp is just this frame's consequence of the
    /// fold, and folding back for it would undo the very thing that let the
    /// window shrink.
    func windowDidResize(_ notification: Notification) {
        let requested = pendingResizeContentWidth
        pendingResizeContentWidth = nil
        guard let actual = toolsHost?.bounds.width else { return }
        applyToolbarFit(availableWidth: min(actual, requested ?? actual))
    }
}

extension EditorWindowController: NSSplitViewDelegate {
    /// Remove the divider's draggable hit area so it never competes with the
    /// `SidebarResizeHandle` for boundary clicks. Resizing is done entirely by
    /// the handle (the divider would not resize reliably under autolayout-width
    /// panes anyway). The thin divider line is still drawn — only its grab area
    /// is zeroed.
    func splitView(_ splitView: NSSplitView,
                   effectiveRect proposedEffectiveRect: NSRect,
                   forDrawnRect drawnRect: NSRect,
                   ofDividerAt dividerIndex: Int) -> NSRect {
        .zero
    }
}

extension EditorWindowController: NSToolbarDelegate {
    /// The switcher is centred via `centeredItemIdentifier`, so it needs no
    /// flanking spaces — the single flexible space just pins the
    /// floating-window toggle to the trailing edge. Exposed as a stored list so
    /// the tests assert against the real thing rather than a copy of it.
    nonisolated static let toolbarDefaultIDs: [NSToolbarItem.Identifier] =
        [tabsItemID, .flexibleSpace, floatingItemID]

    nonisolated static let toolbarAllowedIDs: [NSToolbarItem.Identifier] =
        [.flexibleSpace, tabsItemID, floatingItemID]

    nonisolated func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.toolbarDefaultIDs
    }

    nonisolated func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.toolbarAllowedIDs
    }

    nonisolated func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        MainActor.assumeIsolated {
            if itemIdentifier == Self.floatingItemID {
                return makeFloatingWindowToolbarItem()
            }
            guard itemIdentifier == Self.tabsItemID else { return nil }
            // Rebuild the control if it was torn down, so the tabs can never be
            // permanently lost when the toolbar is hidden (relock) and reshown.
            let seg = tabSwitcher ?? makeTabSwitcher()
            let item = NSToolbarItem(itemIdentifier: Self.tabsItemID)
            item.view = seg
            item.label = "View"
            return item
        }
    }
}

// MARK: - Resizable right sidebar

extension EditorWindowController {

    /// Give the right sidebar a fixed (but mutable) width constraint and a
    /// leading-edge drag handle. The handle drives the constraint directly
    /// rather than the `NSSplitView` divider, which does not resize reliably
    /// under autolayout. Width is clamped to `SidebarWidthPreference` and
    /// persisted on mouse-up. Called for every (re)built sidebar.
    func installSidebarWidth(_ sidebar: EditorSidebarView, width: CGFloat) {
        let clamped = SidebarWidthPreference.clamp(width)
        sidebarWidth = clamped
        let constraint = sidebar.widthAnchor.constraint(equalToConstant: clamped)
        constraint.isActive = true
        sidebarWidthConstraint = constraint

        let handle = SidebarResizeHandle()
        sidebar.addSubview(handle)
        NSLayoutConstraint.activate([
            handle.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            handle.topAnchor.constraint(equalTo: sidebar.topAnchor),
            handle.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
        ])
        handle.currentWidth = { [weak self] in
            self?.sidebarWidthConstraint?.constant ?? SidebarWidthPreference.defaultWidth
        }
        handle.onDrag = { [weak self] proposed in self?.applySidebarWidth(proposed) }
        handle.onCommit = { [weak self] in
            guard let self else { return }
            SidebarWidthPreference.store(self.sidebarWidth)
        }
    }

    /// Clamp `width` and drive the sidebar constraint. Used live during a drag
    /// (persisted on mouse-up).
    private func applySidebarWidth(_ width: CGFloat) {
        let clamped = SidebarWidthPreference.clamp(width)
        sidebarWidth = clamped
        sidebarWidthConstraint?.constant = clamped
    }

    // MARK: - Insert Image overlay

    /// Overlay-insert types: raster formats only (no PDF — overlays draw a
    /// single CGImage; and no camera RAW — too heavy for an inline overlay).
    /// `overlayRasterExtensions` is the same whitelist for drag-drop's extension
    /// check — keep the two in lockstep.
    static let overlayImageTypes: [UTType] =
        [.png, .jpeg, .heic, .heif, .tiff, .gif, .bmp, .webP, .ico]
        + [UTType("public.avif")].compactMap { $0 }
    static let overlayRasterExtensions: Set<String> =
        ["png", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "gif", "bmp", "webp", "avif", "ico"]

    /// Menu-bar entry point ("File ▸ Insert Image on Canvas…"). Presents the
    /// image picker and inserts onto the current canvas. A no-op in empty mode
    /// (the `guard let state` below), which is why the menu item can stay
    /// always-enabled. Shares the toolbar `+` menu's Insert Image path.
    func insertImageOnCanvas() {
        presentInsertImagePanel()
    }

    private func presentInsertImagePanel() {
        guard let state = state else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = Self.overlayImageTypes
        panel.message = "Choose an image to place on the canvas"
        panel.prompt = "Insert"
        guard panel.runModal() == .OK, let url = panel.urls.first,
              let image = Self.loadOverlayImage(from: url) else { return }
        state.insertImageAnnotation(image, at: nil)
        canvas?.needsDisplay = true
    }

    static func loadOverlayImage(from url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}
