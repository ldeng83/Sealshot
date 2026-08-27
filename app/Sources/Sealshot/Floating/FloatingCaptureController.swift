import AppKit

/// Owns the floating capture panel and renders `FloatingCaptureModel`. Holds no
/// capture logic: every button ends up calling an existing `CaptureCoordinator`
/// trigger, so the panel inherits the busy gate, the lock gate and the licence
/// gate without restating any of them. Adding a second gate here would create a
/// second place for the two to disagree.
///
/// An `NSResponder` because it owns the content view's tracking area — the
/// fade-at-rest effect is driven by mouse hover, never by focus, since
/// `FloatingCapturePanel` can never become key.
@MainActor
final class FloatingCaptureController: NSResponder {

    /// Opacity when the pointer is elsewhere. High enough to stay legible at a
    /// glance — a panel you have to hunt for costs more than the screen space
    /// it saves — but distinctly recessed so it doesn't compete with the work
    /// behind it. It floors here rather than going fully transparent: a faded
    /// panel still takes clicks, and an invisible click target reads as broken.
    static let restingOpacity: CGFloat = 0.92

    /// How long the panel takes to slide — following the pointer to another
    /// display, and tucking itself into its docked line. One constant so the
    /// two motions read as the same gesture.
    static let slideDuration: TimeInterval = 0.24

    // MARK: Injected actions

    /// Start a capture. Injected rather than holding a `CaptureCoordinator`, so
    /// the controller is testable without one — the same shape
    /// `CaptureCoordinator.isRecordingActive` already uses.
    var perform: (FloatingCaptureKind) -> Void = { _ in }
    /// Bring the editor back.
    var openEditor: () -> Void = {}
    /// The library's latest captures, newest first — the SAME query the editor
    /// strip renders. The panel's strip is a pure projection of this: it never
    /// keeps its own list, so it can never disagree with the library about
    /// what exists. Deletes, restores, renames and imports all reach the panel
    /// as "something changed → re-ask this".
    var recentProvider: (() async -> [StripItem])?
    /// The save folder being projected — scopes index-change notifications and
    /// arms the file watcher. A closure so a Settings folder switch is picked
    /// up on the next refresh without any wiring here.
    var saveFolderProvider: (() -> URL?)?
    var togglePauseRecording: () -> Void = {}
    var stopRecording: () -> Void = {}

    /// Whether the app is locked. Injected rather than reading
    /// `EncryptionSession` directly, so the panel stays testable without a
    /// keychain — the same shape as its other dependencies.
    var isLocked: () -> Bool = { false }

    /// The editor window right now, or nil when there is none. Injected for the
    /// same reason as everything else here: the panel must work — and be
    /// testable — with no editor in existence at all.
    var editorWindow: () -> NSWindow? = { nil }

    // MARK: State

    /// The panel's minimum content width — 50% wider than the original
    /// natural width, so more strip tiles fit and the controls breathe.
    static let panelMinWidth: CGFloat = 240
    /// Strip-consistent tile: the editor strip's 4:3 aspect and 8pt corner.
    static let tileSize = NSSize(width: 64, height: 48)
    /// The strip's leftmost three items, exactly — a fixed window onto the
    /// library's newest captures, not "as many as fit".
    static let shownTileCount = 3

    private let panel = FloatingCapturePanel()
    private var model = FloatingCaptureModel()
    /// Every persisted bit of panel state reads and writes through this.
    /// Injectable so tests get their own suite: they share the app's container,
    /// and a dock persisted by one test otherwise leaks into the next — which
    /// is exactly how several of them started restoring docks they never made.
    private let defaults: UserDefaults
    private var positions: FloatingCapturePositionStore
    private var recording: (active: Bool, paused: Bool) = (false, false)
    private var wasVisibleBeforeCapture = false
    /// Whether this panel hid ITSELF for the capture now in flight.
    private var hiddenForCapture = false

    /// The controls are the editor toolbar's own pill buttons, not bare
    /// `NSButton`s: same 28pt pill, same glyph weights, same accent-tinted
    /// active state, same instant tooltips. A second button style for one small
    /// panel would read as a different app.
    /// Kinds promoted OUT of the overflow onto their own always-visible pills.
    /// The face button stays the adaptive last-used slot beside them.
    static let quickKinds: [FloatingCaptureKind] = [.fullScreen, .scrolling, .record]

    private(set) var faceButton: ActiveToolPillView!
    private(set) var quickButtons: [ActiveToolPillView] = []
    private(set) var countLabel = NSTextField(labelWithString: "0")
    private var overflowButton: ActiveToolPillView!
    private var restoreButton: ActiveToolPillView!
    private(set) var pinButton: FloatingChromeButton!
    private(set) var closeButton: FloatingChromeButton!
    /// The chrome row's container, faded as one rather than per button.
    private let chromeRow = NSView()
    private let thumbnailRow = NSStackView()
    private let overflowMenu = NSMenu()
    private var content: FloatingCaptureContentView!

    /// Closing from the panel must land in the same place as the editor's
    /// toolbar toggle and the View menu, or the button state drifts.
    var onCloseRequested: (() -> Void)?

    /// Pinned above everything, or riding the editor. Persisted.
    lazy var pinState: FloatingPinState = FloatingPinPreference(defaults: defaults).state {
        didSet {
            guard pinState != oldValue else { return }
            FloatingPinPreference(defaults: defaults).state = pinState
            pinButton?.setSymbol(pinState.symbolName)
            pinButton?.setTooltip(pinState.tooltip)
            applyPinState()
            // Unpinning drops the panel to `.normal` UNDER an editor that may
            // already be key and overlapping it — and clicking the pin button
            // changes no key state, since the panel never becomes key. Without
            // this the panel simply disappears with no way back: `didBecomeKey`
            // does not re-fire for a window that is already key. Re-assert the
            // ride here, against whichever editor window exists now.
            if let window = editorWindow() { followEditorIfUnpinned(window) }
        }
    }
    /// The current projection: the library's newest captures, first three
    /// shown. Written ONLY by `refreshStrip()` — nothing appends to it.
    private var stripItems: [StripItem] = []
    /// Sees deletes, restores, renames and Finder-side changes the moment they
    /// hit the disk — the same signal the editor strip trusts. FSEvents is
    /// recursive, so the Recordings/ and Deleted/ subfolders ride along.
    private let folderWatcher = FolderWatcher()
    /// Stands in for the thumbnails before the first capture of a run, so the
    /// strip is never a blank gap the user has to interpret.
    private let emptyStripLabel = NSTextField(labelWithString: "No captures yet")

    var size: FloatingPanelSize = .strip {
        didSet { applySize() }
    }

    var isVisible: Bool { panel.isVisible }

    // MARK: Test hooks

    var panelFrameForTesting: NSRect { panel.frame }
    var panelScreenFrameForTesting: NSRect? { panel.screen?.frame }
    var panelAlphaForTesting: CGFloat { panel.alphaValue }
    var chromeAlphaForTesting: CGFloat { chromeRow.alphaValue }
    var overflowMenuForTesting: NSMenu { overflowMenu }
    var restoreButtonForTesting: ActiveToolPillView { restoreButton }
    var stripURLsForTesting: [URL] { stripItems.map(\.url) }
    var thumbnailCountForTesting: Int {
        thumbnailRow.arrangedSubviews.filter { $0 is NSImageView }.count
    }
    var isCorneredForTesting: Bool { snappedCorner != nil }
    var stripPlaceholderVisibleForTesting: Bool {
        thumbnailRow.arrangedSubviews.contains(emptyStripLabel) && !thumbnailRow.isHidden
    }
    func setFrameForTesting(_ frame: NSRect) { panel.setFrame(frame, display: false) }
    func selectKindForTesting(_ kind: FloatingCaptureKind) { choose(kind) }

    // MARK: Lifecycle

    private var captureFeedObserver: NSObjectProtocol?
    private var indexChangeObserver: NSObjectProtocol?
    private var screenChangeObserver: NSObjectProtocol?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.positions = FloatingCapturePositionStore(defaults: defaults)
        super.init()
        buildViews()
        applySize()
        renderModel()
        // The strip refreshes on the SAME signals the editor strip trusts,
        // funnelled into one operation — refetch the library's top three:
        //  1. `.captureFilesImported` — every route that lands a capture posts
        //     it (editor window, hotkeys, menu bar, recordings, imports), so a
        //     new tile appears without waiting for the FSEvents debounce.
        //  2. `.libraryIndexDidChange` — a background reconcile changed what
        //     the index holds (scoped to the watched folder).
        //  3. The folder watcher below — deletes, restores, renames and
        //     Finder-side changes, which post neither notification.
        captureFeedObserver = NotificationCenter.default.addObserver(
            forName: .captureFilesImported, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshStrip() }
        }
        // Unplugging a display strands every window that was on it at
        // coordinates that no longer exist. The panel is a `.nonactivating`
        // panel with no title bar, so macOS's own window-relocation pass does
        // not save it and the user has nothing to grab: it is simply gone.
        // This is the ONLY signal that the desk changed — the pointer poll
        // that also calls `recoverIfStranded` is armed only in some states,
        // and a stranded panel usually isn't in one of them.
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenSetupChanged() }
        }
        indexChangeObserver = NotificationCenter.default.addObserver(
            forName: .libraryIndexDidChange, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Same folder scoping as the editor strip: a reconcile of some
                // other folder (the Deleted trash, an old save location) must
                // not churn this strip. Unknown scope refreshes — stale is the
                // worse failure.
                if let folder = self.saveFolderProvider?(),
                   !stripShouldRefresh(forIndexChangeIn: note.object as? URL,
                                       watching: folder) { return }
                self.refreshStrip()
            }
        }
        folderWatcher.onChange = { [weak self] in
            MainActor.assumeIsolated { self?.refreshStrip() }
        }
    }



    required init?(coder: NSCoder) { nil }

    /// Whether the panel was showing when the app locked, so unlocking can put
    /// it back rather than leaving the user to hunt for the toolbar button.
    private(set) var wasVisibleBeforeLock = false

    func show() {
        // The single choke point for every route that can display the panel —
        // toolbar button, View menu, launch restore, unlock. While locked every
        // one of its buttons would refuse anyway, so a panel of dead controls
        // sitting over the lock screen is worse than no panel at all.
        guard !isLocked() else { return }
        if dockedEdge != nil {
            // A docked line just comes back as the line; restoring the panel
            // frame would blow it up to full size at the remembered spot.
            panel.orderFrontRegardless()
            // ...but "the same place" has to still exist. Showing is a user
            // asking to SEE the panel, so it is the last moment to catch a line
            // left on a display that has since gone away.
            recoverIfStranded()
            updatePointerFollowMonitor()
            return
        }
        restoreFrame()
        // A panel that was docked when the app quit comes back docked, on the
        // same edge and in the same place. `restoreFrame` first, so the panel
        // is on the right screen before we ask that screen for its dock.
        if let screen = panel.screen ?? NSScreen.main, restorePersistedDock(on: screen) {
            panel.orderFrontRegardless()
            currentDisplayID = Self.displayID(for: screen)
            updatePointerFollowMonitor()
            applyPinState()
            refreshStrip()
            return
        }
        panel.orderFrontRegardless()
        currentDisplayID = (panel.screen ?? NSScreen.main).flatMap(Self.displayID(for:))
        recoverIfStranded()
        updatePointerFollowMonitor()
        applyPinState()
        refreshStrip()
    }

    /// The strip's ONLY write path: re-ask the library for its newest captures
    /// and show the first three. Coalesced — a burst of signals (FSEvents +
    /// notification for the same capture) resolves to one fetch — and cheap to
    /// call from anywhere, so callers never reason about WHAT changed.
    private var stripRefreshTask: Task<Void, Never>?
    func refreshStrip() {
        // Re-arm the watcher against the CURRENT folder each refresh: after a
        // Settings folder switch the next signal self-heals the watch.
        // `watch()` is a no-op for an unchanged folder.
        if let folder = saveFolderProvider?() { folderWatcher.watch(folder) }
        stripRefreshTask?.cancel()
        guard let provider = recentProvider else { return }
        stripRefreshTask = Task { [weak self] in
            let items = await provider()
            guard let self, !Task.isCancelled else { return }
            let shown = Array(items.prefix(Self.shownTileCount))
            guard shown != self.stripItems else { return }
            self.stripItems = shown
            self.renderThumbnails()
        }
    }

    /// Test hook: run one refresh and wait for it to render.
    func refreshStripForTesting() async {
        refreshStrip()
        await stripRefreshTask?.value
    }

    func hide() {
        panel.orderOut(nil)
        snapGuides.hide()
        updatePointerFollowMonitor()
    }

    /// Ask for the panel to appear as soon as the app unlocks. Used when a
    /// launch lands in a locked session: `show()` refuses, and without this the
    /// panel would stay gone until the user found the toolbar button.
    func markPendingUnlockRestore() {
        wasVisibleBeforeLock = true
    }

    /// The app locked: take the panel down, remembering whether it was there.
    func hideForLock() {
        wasVisibleBeforeLock = panel.isVisible
        hide()
    }

    /// The app unlocked: put the panel back, but only if the lock is what took
    /// it away — unlocking must not summon a panel the user had closed.
    func restoreAfterUnlock() {
        guard wasVisibleBeforeLock else { return }
        wasVisibleBeforeLock = false
        show()
    }

    /// Order the panel out for the duration of a capture. Not a correctness
    /// measure — `SelfExcludingContentFilter` already keeps every Sealshot
    /// window out of captured pixels — but a panel sitting on top of the region
    /// you are dragging out is intolerable to aim around.
    func hideForCapture() {
        wasVisibleBeforeCapture = panel.isVisible
        hiddenForCapture = true
        panel.orderOut(nil)
        // Belt and braces: a guide left on screen would be captured.
        snapGuides.hide()
        updatePointerFollowMonitor()
    }

    /// Put it back only if WE hid it, and only if it was there to begin with.
    /// Recordings never hide the panel, so without the first condition a
    /// finished recording would consult a flag left over from the last still
    /// capture — and could re-show a panel the user had since closed.
    func restoreAfterCapture() {
        guard hiddenForCapture else { return }
        hiddenForCapture = false
        guard wasVisibleBeforeCapture else { return }
        panel.orderFrontRegardless()
        // Catch up at once rather than waiting for the next tick — the pointer
        // has usually moved during the capture — and re-arm the poll, which
        // hiding for the capture had switched off.
        updatePointerFollowMonitor()
        followPointerIfNeeded()
    }

    // MARK: Views

    private func buildViews() {
        let content = FloatingCaptureContentView()
        self.content = content
        // `.hudWindow` over a clear panel gives the dark vibrancy this sits on;
        // the border and top highlight come from the content view's `draw`.
        content.material = .hudWindow
        content.blendingMode = .behindWindow
        content.state = .active
        content.wantsLayer = true
        content.layer?.cornerRadius = 12
        content.layer?.masksToBounds = true
        content.onHoverChanged = { [weak self] hovering in
            guard let self else { return }
            self.applyRestingOpacity(hovering: hovering)
            if hovering {
                self.pointerHasEnteredSinceRestore = true
                self.cancelAutoDock()
            } else {
                self.autoDockIfPointerLeft()
            }
        }
        content.onDragMoved = { [weak self] in self?.updateSnapGuides() }
        content.onDragEnded = { [weak self] in self?.settleAfterDrag() }
        // A CLICK (no movement) on the docked line restores the panel; on the
        // normal panel background it does nothing, same as before.
        content.onClick = { [weak self] in
            guard let self, self.dockedEdge != nil else { return }
            self.restoreFromDock(animated: true)
        }

        faceButton = ActiveToolPillView(symbolName: model.faceKind.symbolName,
                                        accessibilityLabel: model.faceKind.title,
                                        symbolPointSize: 15) { [weak self] in
            self?.faceClicked()
        }
        overflowButton = ActiveToolPillView(symbolName: "ellipsis",
                                            accessibilityLabel: "More capture kinds",
                                            symbolPointSize: 15) { [weak self] in
            self?.overflowClicked()
        }
        restoreButton = ActiveToolPillView(symbolName: "arrow.up.left.and.arrow.down.right",
                                           accessibilityLabel: "Open the editor",
                                           symbolPointSize: 15) { [weak self] in
            self?.restoreClicked()
        }

        // Always-visible pills for the everyday kinds, straight from the
        // overflow — performing without promoting, so the adaptive face slot
        // stays whatever the user last chose there.
        quickButtons = Self.quickKinds.map { kind in
            let pill = ActiveToolPillView(symbolName: kind.symbolName,
                                          accessibilityLabel: kind.title,
                                          symbolPointSize: 15) { [weak self] in
                self?.perform(kind)
            }
            pill.tooltipText = kind.title
            return pill
        }

        // The panel never activates Sealshot, so its controls must track the
        // pointer regardless of which app is active or their tooltips are dead.
        for control in [faceButton, overflowButton, restoreButton] + quickButtons {
            control?.tracksWhileAppInactive = true
        }

        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        countLabel.textColor = .secondaryLabelColor
        countLabel.alignment = .center
        countLabel.toolTip = "Captures since you last opened the editor"
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        // The digits sat flush against the panel's right edge; give them their
        // own breathing room rather than padding the whole row.
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 16).isActive = true
        countLabel.isHidden = true   // hidden for now; see renderModel

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.heightAnchor.constraint(equalToConstant: 16).isActive = true

        let grip = FloatingCaptureGripView()
        grip.translatesAutoresizingMaskIntoConstraints = false
        // No tooltip: the grip's `hitTest` returns nil on purpose (the drag
        // belongs to the content view underneath), and a view that takes no
        // hits shows no tooltip. One set here would only look like coverage.

        pinButton = FloatingChromeButton(symbolName: pinState.symbolName,
                                         tooltip: pinState.tooltip) { [weak self] in
            guard let self else { return }
            self.pinState = self.pinState.toggled
        }
        closeButton = FloatingChromeButton(symbolName: "xmark",
                                           tooltip: "Close this panel") { [weak self] in
            self?.onCloseRequested?()
        }

        // Hidden at rest and revealed on hover, riding the fade the panel
        // already has. The row keeps its height either way, so nothing shifts
        // under the pointer as the glyphs arrive.
        chromeRow.translatesAutoresizingMaskIntoConstraints = false
        chromeRow.alphaValue = 0
        for view in [pinButton, grip, closeButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            chromeRow.addSubview(view)
        }
        NSLayoutConstraint.activate([
            chromeRow.heightAnchor.constraint(equalToConstant: FloatingChromeButton.side),
            pinButton.leadingAnchor.constraint(equalTo: chromeRow.leadingAnchor),
            pinButton.centerYAnchor.constraint(equalTo: chromeRow.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: chromeRow.trailingAnchor),
            closeButton.centerYAnchor.constraint(equalTo: chromeRow.centerYAnchor),
            grip.centerXAnchor.constraint(equalTo: chromeRow.centerXAnchor),
            grip.centerYAnchor.constraint(equalTo: chromeRow.centerYAnchor),
            grip.widthAnchor.constraint(equalToConstant: 44),
            grip.heightAnchor.constraint(equalToConstant: 9),
        ])

        let buttonRow = NSStackView(views: [faceButton, separator] + quickButtons
                                          + [overflowButton, restoreButton, countLabel])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 1
        buttonRow.setCustomSpacing(5, after: restoreButton)
        buttonRow.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 5)

        thumbnailRow.orientation = .horizontal
        thumbnailRow.spacing = 4
        thumbnailRow.alignment = .centerY

        emptyStripLabel.font = .systemFont(ofSize: 10, weight: .regular)
        emptyStripLabel.textColor = .tertiaryLabelColor
        emptyStripLabel.alignment = .center

        let column = NSStackView(views: [chromeRow, buttonRow, thumbnailRow])
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 3
        column.edgeInsets = NSEdgeInsets(top: 3, left: 6, bottom: 6, right: 6)
        column.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(column)
        // Kept as a handle: a HIDDEN view's constraints still participate in
        // Auto Layout, so the docked line (8pt wide) could never exist while
        // the column's minimum width pinned the window at panel size. Docking
        // deactivates these; restoring reactivates them.
        columnConstraints = [
            column.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.panelMinWidth),
            column.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            column.topAnchor.constraint(equalTo: content.topAnchor),
            column.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ]
        NSLayoutConstraint.activate(columnConstraints + [
            chromeRow.leadingAnchor.constraint(equalTo: column.leadingAnchor,
                                               constant: column.edgeInsets.left),
            chromeRow.trailingAnchor.constraint(equalTo: column.trailingAnchor,
                                                constant: -column.edgeInsets.right),
        ])
        panel.contentView = content
        rebuildOverflowMenu()
        renderThumbnails()
    }

    // MARK: Recent-capture strip

    private func renderThumbnails() {
        for view in thumbnailRow.arrangedSubviews {
            thumbnailRow.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        thumbnailRow.isHidden = !size.showsThumbnails
        // Compact builds nothing: a hidden row full of tiles would still cost
        // the thumbnail decodes and still count as content.
        guard size.showsThumbnails else {
            resizeToFit()
            return
        }
        // Library's empty — say so rather than leaving a gap.
        if stripItems.isEmpty {
            thumbnailRow.addArrangedSubview(emptyStripLabel)
            resizeToFit()
            return
        }

        for item in stripItems {
            let tile = FloatingCaptureThumbnailView()
            tile.imageScaling = .scaleProportionallyUpOrDown
            tile.wantsLayer = true
            // The editor strip's tile look: 4:3, 8pt corners.
            tile.layer?.cornerRadius = 8
            tile.layer?.masksToBounds = true
            tile.layer?.borderWidth = 1
            tile.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
            tile.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.25).cgColor
            tile.url = item.url
            tile.displayName = item.displayName
            // From the index's captureKind, not the file extension — a video
            // `.seal` looks identical to an image `.seal` on disk.
            tile.isVideo = item.isVideo
            tile.toolTip = tileTooltipsSuppressed ? nil : item.displayName
            // The tile outlives neither a landed capture nor an editor open;
            // its in-flight promise must outlive both, so the controller holds
            // the lifeline. See `retainDragLifeline`.
            tile.retainDragLifeline = { [weak self] object in
                self?.retainDragLifeline(object)
            }
            tile.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                tile.widthAnchor.constraint(equalToConstant: Self.tileSize.width),
                tile.heightAnchor.constraint(equalToConstant: Self.tileSize.height),
            ])
            thumbnailRow.addArrangedSubview(tile)

            // Decrypts and downsamples off-main, cached — the same store the
            // Library's cards use, so a capture already shown there is free.
            Task { [weak tile] in
                let image = await ThumbnailStore.shared.thumbnail(for: item.url)
                tile?.image = image
            }
        }
        resizeToFit()
    }

    // MARK: Actions

    private func faceClicked() {
        if recording.active { stopRecording() } else { choose(model.faceKind) }
    }

    private func overflowClicked() {
        // `popUp` blocks until the menu closes, so the flag brackets exactly
        // the window in which the pointer is over the MENU rather than the
        // panel — auto-dock must not yank the panel out from under it.
        isShowingOverflowMenu = true
        overflowMenu.popUp(positioning: nil,
                           at: NSPoint(x: 0, y: overflowButton.bounds.height + 4),
                           in: overflowButton)
        isShowingOverflowMenu = false
    }

    private func restoreClicked() {
        openEditor()
    }

    @objc private func overflowItemClicked(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String,
              let kind = FloatingCaptureKind(rawValue: raw) else { return }
        choose(kind)
    }

    @objc private func pauseClicked() { togglePauseRecording() }
    @objc private func stopClicked() { stopRecording() }

    /// Perform a kind AND promote it onto the face button, so a run of the same
    /// kind is one click each thereafter.
    private func choose(_ kind: FloatingCaptureKind) {
        model.perform(kind)
        renderModel()
        perform(kind)
    }

    /// A capture actually completed — bump the visible tally. With the editor
    /// suppressed this and the thumbnails are the only proof anything happened.
    func captureLanded() {
        model.captureLanded()
        renderModel()
    }

    /// The editor became visible by any route. The run is over: the count and
    /// the thumbnails both start clean, because both answer the same question —
    /// "what have I taken since I last looked?" — and leaving stale tiles beside
    /// a zeroed count would make them disagree.
    func editorWasOpened() {
        model.editorWasOpened()
        // The strip PERSISTS across editor opens now: it mirrors the library's
        // latest captures (like the editor strip), not captures-since-you-
        // looked. Only the count resets — and it is hidden anyway.
        renderModel()
    }

    /// Mirror the status item: while recording, the face button becomes Stop
    /// and the overflow collapses to the recording controls — the same swap the
    /// menu bar makes, so the two surfaces never disagree.
    func setRecording(_ isRecording: Bool, paused: Bool) {
        recording = (isRecording, paused)
        rebuildOverflowMenu()
        renderModel()
    }

    private func rebuildOverflowMenu() {
        overflowMenu.removeAllItems()
        if recording.active {
            let pause = NSMenuItem(
                title: recording.paused ? "Resume Recording" : "Pause Recording",
                action: #selector(pauseClicked), keyEquivalent: "")
            pause.target = self
            overflowMenu.addItem(pause)
            let stop = NSMenuItem(title: "Stop Recording",
                                  action: #selector(stopClicked), keyEquivalent: "")
            stop.target = self
            overflowMenu.addItem(stop)
            return
        }
        // Every kind EXCEPT the quick pills' — those moved onto the panel face
        // and would be duplicates here. The face button's kind stays listed:
        // the face is a shortcut to the last choice, not a slot removed from
        // the menu.
        for kind in FloatingCaptureKind.allCases where !Self.quickKinds.contains(kind) {
            let item = NSMenuItem(title: kind.title,
                                  action: #selector(overflowItemClicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = kind.rawValue
            item.image = NSImage(systemSymbolName: kind.symbolName,
                                 accessibilityDescription: kind.title)
            overflowMenu.addItem(item)
        }
        overflowMenu.addItem(.separator())
        let autoDock = NSMenuItem(title: "Hide to Edge Automatically",
                                  action: #selector(toggleAutoDock), keyEquivalent: "")
        autoDock.target = self
        autoDock.state = autoDockEnabled ? .on : .off
        autoDock.toolTip = "Tuck the panel against the nearest edge whenever the "
            + "pointer leaves it. Click the arrow on the edge to bring it back."
        overflowMenu.addItem(autoDock)
    }

    /// Undock, forget the docks, and put the panel in the MIDDLE of the screen
    /// the pointer is on — whatever state it had got into.
    ///
    /// Lives in the View menu, not this panel's own ⋯ menu: the state it exists
    /// to undo is one where the panel cannot be seen or clicked, so an escape
    /// hatch on the panel is no escape at all. The menu bar is always reachable.
    ///
    /// Centre, not the default corner: a corner is a plausible place for a
    /// panel to be hiding — behind the Dock, under a notch, half off a display
    /// whose edges the user is unsure of. The middle of the screen is the one
    /// place that is unambiguously visible, which is the entire point.
    func resetPosition() {
        cancelAutoDock()
        cancelAutoReveal()
        if dockedEdge != nil {
            dockedEdge = nil
            clearDockChrome()
            panel.setContentSize(dockedSavedSize)
        }
        lastParkedLine = nil
        // Forget every display's dock, not just this one's: the whole point is
        // that the user is standing in front of a panel they cannot reach, and
        // a dock remembered for a display they are not looking at is exactly
        // what would bring it back the next time they launch.
        positions.clearAllDockStates()
        let screen = NSScreen.screens.first(where: {
            $0.frame.contains(NSEvent.mouseLocation)
        }) ?? NSScreen.main
        guard let screen else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2,
                                     y: visible.midY - size.height / 2))
        currentDisplayID = Self.displayID(for: screen)
        rememberPosition(displayID: currentDisplayID)
        refreshSnappedCorner(on: screen)
        panel.orderFrontRegardless()
        pointerHasEnteredSinceRestore = false
        updatePointerFollowMonitor()
    }

    @objc private func toggleAutoDock() {
        autoDockEnabled.toggle()
        updateClickAwayMonitors()
        // Turning it ON with the pointer already elsewhere should take effect
        // without waiting for the next hover — through the same countdown, so
        // it doesn't snap away under a pointer that is still on the panel.
        if autoDockEnabled { autoDockIfPointerLeft() } else { cancelAutoDock(); cancelAutoReveal() }
        updatePointerFollowMonitor()
    }

    // MARK: Rendering

    private func applySize() {
        renderThumbnails()
    }

    /// Grow/shrink the panel to whatever the stack actually needs, keeping the
    /// TOP-LEFT corner fixed. Resizing from the bottom-left (AppKit's default,
    /// since y grows upward) would make the panel appear to jump whenever a
    /// thumbnail row appeared.
    private func resizeToFit() {
        // A capture can land while docked; the hidden content re-renders but
        // must not resize the LINE window to content size.
        guard dockedEdge == nil else { return }
        guard let content = panel.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let fitting = content.fittingSize
        guard fitting.width > 0, fitting.height > 0 else { return }
        let top = panel.frame.maxY
        panel.setContentSize(fitting)
        panel.setFrameOrigin(NSPoint(x: panel.frame.minX, y: top - panel.frame.height))
    }

    /// Push the model onto the views. The face button's glyph changes as the
    /// user's last-used kind changes, so its accessibility label moves with it —
    /// a button whose meaning shifts must say what it currently means.
    private func renderModel() {
        let symbol = recording.active ? "stop.fill" : model.faceKind.symbolName
        let label = recording.active ? "Stop Recording" : model.faceKind.title
        faceButton.setBaseSymbol(symbol)
        faceButton.tooltipText = label
        faceButton.setAccessibilityLabel(label)
        // Accent-tinted while recording, the same treatment an active tool gets
        // in the editor toolbar — this panel can start a recording, so it has
        // to be able to show one is running.
        faceButton.isActive = recording.active
        // While recording the face IS the stop button; parallel capture
        // starts are refused by the busy gate anyway, so the quick pills
        // grey out rather than pretending.
        for pill in quickButtons { pill.isEnabled = !recording.active }
        countLabel.stringValue = "\(model.count)"
        // Hidden for now — the count may return later, so the model keeps
        // ticking and the label keeps rendering, it just never shows.
        countLabel.isHidden = true
    }

    // MARK: Fade at rest

    /// Hover-driven, never focus-driven — see `FloatingCapturePanel.canBecomeKey`.
    /// Driven by the content view's tracking area, which it rebuilds on resize.
    ///
    /// `animated` mirrors `FloatingCaptureContentView.setSolidBackground`'s own
    /// parameter: with it off, the chrome row's alpha is set directly instead
    /// of through `animator()`, whose value a non-layer-backed `NSView`
    /// otherwise interpolates over the animation's duration rather than
    /// committing immediately — which left nothing synchronous for a test to
    /// observe.
    func applyRestingOpacity(hovering: Bool, animated: Bool = true) {
        // The docked line stays fully visible — an edge indicator that faded
        // would be invisible, and invisible means unfindable.
        if dockedEdge != nil { panel.alphaValue = 1; return }
        panel.alphaValue = hovering ? 1 : Self.restingOpacity
        // Alpha alone still let the desktop show through the vibrancy; under
        // the pointer the panel goes properly opaque.
        content.setSolidBackground(hovering, animated: animated)
        guard animated else {
            chromeRow.alphaValue = hovering ? 1 : 0
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            chromeRow.animator().alphaValue = hovering ? 1 : 0
        }
    }

    /// Drives the hover path directly — the tracking area needs a real pointer,
    /// which a unit test has no way to provide. Unanimated, so the chrome
    /// row's alpha is observable immediately after the call.
    func setHoveringForTesting(_ hovering: Bool) {
        applyRestingOpacity(hovering: hovering, animated: false)
        if hovering {
            pointerHasEnteredSinceRestore = true
            cancelAutoDock()
        } else {
            autoDockIfPointerLeft()
        }
    }

    // MARK: Auto-dock

    /// Whether the panel tucks itself away when the pointer leaves it.
    var autoDockEnabled: Bool {
        get { FloatingAutoDockPreference(defaults: defaults).enabled }
        set {
            FloatingAutoDockPreference(defaults: defaults).enabled = newValue
            rebuildOverflowMenu()
        }
    }

    /// Set when the panel is brought back from the dock and cleared the first
    /// time the pointer is over it. Restoring grows the panel out from under
    /// the cursor, so without this it would re-dock in the same breath and the
    /// user could never reach its controls.
    private var pointerHasEnteredSinceRestore = true

    /// How long the pointer must stay away before the panel tucks itself in.
    /// Docking the instant the pointer crossed the edge was too eager: it fired
    /// while passing OVER the panel on the way somewhere else, and on the
    /// overshoot of reaching for one of its own buttons. Same reason the Dock's
    /// auto-hide waits.
    static let autoDockDelay: TimeInterval = 0.7

    /// How long the pointer must rest on the docked line before it opens.
    /// Shorter than `autoDockDelay` — reaching for the line is deliberate —
    /// but not instant: the line hugs a screen edge, which is exactly where a
    /// pointer passes on its way to a menu or another window. An unwanted
    /// reveal pops a panel over the user's work, so it stays a little
    /// reluctant.
    static let autoRevealDelay: TimeInterval = 0.4

    /// Slack around the line for that hover test. The line is 18pt thin; the
    /// screen edge makes it easy to hit across its thickness (the pointer
    /// stops there) but fussy along its length.
    static let autoRevealMargin: CGFloat = 8

    private var autoRevealTimer: Timer?

    /// …and it must be this far clear of the panel. The delay alone doesn't
    /// help someone working right beside the panel: sitting two points outside
    /// it still docks, just later. Measured from the panel's edge, so it is a
    /// margin around the window rather than a distance from its centre.
    static let autoDockDistance: CGFloat = 40

    private var autoDockTimer: Timer?

    /// The pointer left the panel: start the countdown, rather than docking on
    /// the spot. Re-entering cancels it (see `onHoverChanged`), and when the
    /// timer fires the pointer must ALSO be clear of the panel by
    /// `autoDockDistance` — otherwise it re-arms and checks again.
    private func autoDockIfPointerLeft() {
        guard autoDockEnabled, dockedEdge == nil, panel.isVisible,
              !content.isDraggingPanel, !isShowingOverflowMenu
        else { return }
        scheduleAutoDock()
    }

    private func scheduleAutoDock() {
        cancelAutoDock()
        let timer = Timer(timeInterval: Self.autoDockDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.autoDockTimerFired() }
        }
        // .common so the countdown keeps running while a menu tracks or a
        // window is being dragged — the pointer is most likely to be away from
        // the panel during exactly those.
        RunLoop.main.add(timer, forMode: .common)
        autoDockTimer = timer
    }

    private func cancelAutoDock() {
        autoDockTimer?.invalidate()
        autoDockTimer = nil
    }

    /// Carry the docked line to `target`, keeping its edge and its relative
    /// position along that edge.
    ///
    /// It slides in from just outside the edge on the NEW display — the same
    /// idea as the undocked panel arriving from its own corner: a window
    /// crossing the bezel gap reads as a glitch, arriving from its edge reads
    /// as the panel following you.
    private func followPointerWhileDocked(to target: NSScreen, animated: Bool) {
        guard let edge = dockedEdge else { return }
        // Compare against the screen the LINE IS ON, not the tracked
        // `currentDisplayID`. The tracked value is for the undocked panel,
        // which is deliberately parked off-screen mid-slide and so has no
        // screen to ask; a docked line is always flush against a real edge,
        // and trusting the tracked id instead moved the line whenever that id
        // was merely stale rather than actually different.
        guard let lineScreen = panel.screen else { return }
        let targetID = Self.displayID(for: target)
        guard targetID != Self.displayID(for: lineScreen) else { return }
        let from = lineScreen.visibleFrame
        currentDisplayID = targetID

        let visible = target.visibleFrame
        let line = FloatingCaptureGeometry.dockedLine(panel.frame, movedFrom: from,
                                                      to: visible, edge: edge)
        // Auto-dock aims here now rather than at the spot on the screen just
        // left. The PERSISTED dock is deliberately untouched: that records
        // where the user chose to dock it, and tagging along after the pointer
        // is not that choice — a restart should still bring the panel back
        // where they put it.
        lastParkedLine = (edge, line)
        guard animated else {
            panel.setFrame(line, display: true, animate: false)
            return
        }
        var start = line
        switch edge {
        case .left:   start.origin.x = visible.minX - line.width
        case .right:  start.origin.x = visible.maxX
        case .bottom: start.origin.y = visible.minY - line.height
        case .top:    start.origin.y = visible.maxY
        }
        panel.setFrame(start, display: false, animate: false)
        slideToDockedLine(line)
    }

    /// `pointer` is injectable for the same reason `followPointerIfNeeded`'s
    /// is: a test has no way to place the real cursor, and reading it would
    /// make the outcome depend on where the developer left their mouse.
    func autoDockTimerFired(pointer: NSPoint = NSEvent.mouseLocation) {
        // Invalidate, don't just forget: dropping the reference leaves the
        // scheduled timer live, so the countdown fires a SECOND time later and
        // docks a panel the user has since brought back.
        cancelAutoDock()
        // Still hovering, or back inside the margin? Wait for the next exit
        // rather than docking out from under a pointer that is right there.
        guard !panel.frame.insetBy(dx: -Self.autoDockDistance,
                                   dy: -Self.autoDockDistance).contains(pointer)
        else { return }
        performAutoDock()
    }

    /// Test hook: the countdown elapsing with the pointer at `pointer`.
    var autoDockIsPendingForTesting: Bool { autoDockTimer != nil }
    var autoRevealIsPendingForTesting: Bool { autoRevealTimer != nil }
    var isSlidingForTesting: Bool { isSliding }

    // MARK: Auto-reveal

    /// Resting the pointer on the docked line opens the panel, so auto-hide
    /// isn't a one-way trip that needs a click to undo.
    ///
    /// Driven by the pointer POLL rather than the line's own tracking area,
    /// because the hot zone deliberately extends past the window: a tracking
    /// area cannot see outside its view, and widening the window to gain the
    /// margin would mean the docked line no longer IS its frame — which the
    /// persistence, the drag re-park and the cross-display follow all rely on.
    ///
    /// Part of the same toggle as auto-hide: hide-without-reveal is the odd
    /// half, and someone who dragged the panel to an edge with auto-hide off
    /// asked for it to stay put.
    func updateAutoReveal(pointer: NSPoint = NSEvent.mouseLocation) {
        guard autoDockEnabled, dockedEdge != nil, panel.isVisible, !isSliding else {
            cancelAutoReveal()
            return
        }
        let hot = panel.frame.insetBy(dx: -Self.autoRevealMargin, dy: -Self.autoRevealMargin)
        guard hot.contains(pointer) else {
            cancelAutoReveal()
            return
        }
        guard autoRevealTimer == nil else { return }   // already counting down
        let timer = Timer(timeInterval: Self.autoRevealDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.autoRevealTimerFired() }
        }
        RunLoop.main.add(timer, forMode: .common)
        autoRevealTimer = timer
    }

    func autoRevealTimerFired(pointer: NSPoint = NSEvent.mouseLocation) {
        cancelAutoReveal()
        guard dockedEdge != nil else { return }
        // Still resting on the line? A pointer that passed through on its way
        // somewhere else has already moved on.
        let hot = panel.frame.insetBy(dx: -Self.autoRevealMargin, dy: -Self.autoRevealMargin)
        guard hot.contains(pointer) else { return }
        restoreFromDock(animated: true)
    }

    private func cancelAutoReveal() {
        autoRevealTimer?.invalidate()
        autoRevealTimer = nil
    }

    /// Tuck the panel away now, if that's what the user asked for and nothing
    /// else is going on.
    private func performAutoDock() {
        guard autoDockEnabled, dockedEdge == nil, panel.isVisible,
              !isSliding, !isShowingOverflowMenu,
              // Dragging the panel moves it under the pointer, which fires
              // `mouseExited` — docking then would make the panel impossible
              // to move at all while auto-dock is on.
              !content.isDraggingPanel,
              // A restore hasn't been "used" yet — see the flag.
              pointerHasEnteredSinceRestore,
              let screen = nearestScreen()
        else { return }
        // Go back exactly where the line last sat, rather than deriving a
        // fresh spot: having slid the line somewhere they like, the user
        // expects peeking at the panel and letting go to put it back THERE.
        // The memory is dropped the moment they drag the panel itself, so
        // moving it across the screen still tucks it away nearby.
        //
        // Not the persisted dock state, which is cleared on undock so a
        // restart can't re-tuck a panel the user deliberately brought back —
        // auto-dock wants the opposite for the rest of the session.
        //
        // Nearest-edge arithmetic can't stand in for this: a restored panel
        // sits in a CORNER, where the nearest edge is often not the one it
        // came from, and the line would jump to a different edge on every peek.
        if let remembered = lastParkedLine {
            dock(to: remembered.edge, on: screen, line: remembered.line, animated: true)
            return
        }
        dock(to: FloatingCaptureGeometry.nearestEdge(for: panel.frame,
                                                     in: screen.visibleFrame).edge,
             on: screen, animated: true)
    }

    /// True while the ⋯ menu is up. Opening it moves the pointer off the panel,
    /// which would otherwise dock the panel out from under its own open menu.
    private var isShowingOverflowMenu = false

    // MARK: Tooltips after a restore

    /// A tile's tooltip is its file name, and it is worth having — but only
    /// when the pointer is deliberately ON a tile.
    ///
    /// AppKit measures the tooltip delay from the last pointer MOVEMENT, not
    /// from when a view arrived under the pointer. Resting on the docked line
    /// to open the panel therefore spends the whole delay before any tile
    /// exists, and the tile that lands under the pointer inherits an expired
    /// timer: panel and tooltip appear in the same instant, naming a file the
    /// user never pointed at. Suppress tile tooltips across a restore and put
    /// them back as soon as the pointer moves — which is also when AppKit
    /// restarts its own timer, so the next tooltip is one the user asked for.
    private var tileTooltipsSuppressed = false
    private var tooltipWakeMonitors: [Any] = []
    private var tooltipSuppressOrigin: NSPoint?
    /// Enough movement to mean "I am pointing at this", not hand tremor.
    static let tooltipWakeDistance: CGFloat = 4

    /// Off in tests: the monitors below watch the REAL mouse, so a hand on the
    /// trackpad during a test woke suppression between the act and the assert.
    /// Tests drive movement through `pointerMovedForTesting` instead.
    var installsTooltipWakeMonitors = true

    private func suppressTileTooltipsUntilPointerMoves() {
        tileTooltipsSuppressed = true
        applyTileTooltips()
        tooltipSuppressOrigin = NSEvent.mouseLocation
        guard installsTooltipWakeMonitors, tooltipWakeMonitors.isEmpty else { return }
        // Both kinds, for the same reason as the click-away monitors: a global
        // monitor never sees our own process's events, and the pointer is over
        // OUR panel the moment this matters.
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.wakeTooltipsIfPointerMoved(NSEvent.mouseLocation) }
        })
        let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.wakeTooltipsIfPointerMoved(NSEvent.mouseLocation) }
            return event
        })
        tooltipWakeMonitors = [global, local].compactMap { $0 }
    }

    private func wakeTooltipsIfPointerMoved(_ location: NSPoint) {
        guard tileTooltipsSuppressed else { return }
        if let origin = tooltipSuppressOrigin {
            let moved = hypot(location.x - origin.x, location.y - origin.y)
            guard moved > Self.tooltipWakeDistance else { return }
        }
        tileTooltipsSuppressed = false
        tooltipSuppressOrigin = nil
        tooltipWakeMonitors.forEach(NSEvent.removeMonitor)
        tooltipWakeMonitors = []
        applyTileTooltips()
    }

    /// Push the current suppression state onto the tiles already on screen —
    /// `renderThumbnails` handles the ones built later.
    private func applyTileTooltips() {
        for case let tile as FloatingCaptureThumbnailView in thumbnailRow.arrangedSubviews {
            tile.toolTip = tileTooltipsSuppressed ? nil : tile.displayName
        }
    }

    /// Test hooks: the monitors' input, and what the tiles are showing.
    func pointerMovedForTesting(to location: NSPoint) { wakeTooltipsIfPointerMoved(location) }
    var tileTooltipsForTesting: [String?] {
        thumbnailRow.arrangedSubviews
            .compactMap { $0 as? FloatingCaptureThumbnailView }
            .map(\.toolTip)
    }
    var tileTooltipsSuppressedForTesting: Bool { tileTooltipsSuppressed }

    private var clickAwayMonitors: [Any] = []

    /// Tuck the panel away when the user clicks ANYWHERE else, not only when
    /// the pointer happens to cross its edge.
    ///
    /// A cancelled capture leaves the panel on screen with the pointer already
    /// somewhere else, so no exit event is coming and the panel would sit
    /// there until it was next hovered. A click elsewhere is the clearest
    /// statement that the user is done with it.
    ///
    /// Two monitors, because they see different things: the global one fires
    /// for clicks delivered to OTHER apps, the local one for clicks in ours
    /// (the editor window, the menu bar item) — a global monitor never sees
    /// its own process's events.
    private func updateClickAwayMonitors() {
        let wanted = autoDockEnabled && panel.isVisible
        guard wanted != !clickAwayMonitors.isEmpty else { return }
        guard wanted else {
            clickAwayMonitors.forEach(NSEvent.removeMonitor)
            clickAwayMonitors = []
            return
        }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.dockIfClickWasAway(NSEvent.mouseLocation) }
        })
        let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.dockIfClickWasAway(NSEvent.mouseLocation) }
            return event
        })
        clickAwayMonitors = [global, local].compactMap { $0 }
    }

    /// Test hook: a click at `location`, as the monitors would deliver it.
    func clickAwayForTesting(at location: NSPoint) { dockIfClickWasAway(location) }

    /// Test hook: drive the panel's drag state without a real mouse.
    func beginPanelDragForTesting(at pointer: NSPoint) {
        content.beginDragForTesting(pointer: pointer)
    }
    func dragPanelForTesting(to pointer: NSPoint) { content.dragForTesting(pointer: pointer) }
    func endPanelDragForTesting() { content.endDragForTesting() }

    private func dockIfClickWasAway(_ location: NSPoint) {
        guard autoDockEnabled, dockedEdge == nil, panel.isVisible,
              !content.isDraggingPanel, !isShowingOverflowMenu,
              !panel.frame.insetBy(dx: -2, dy: -2).contains(location)
        else { return }
        // A click elsewhere is explicit: no countdown, and it doesn't wait for
        // the panel to have been hovered the way a stray pointer-exit does.
        pointerHasEnteredSinceRestore = true
        cancelAutoDock()
        performAutoDock()
    }

    /// Where the docked line last sat, per edge. Auto-dock returns here rather
    /// than deriving a fresh position from the restored panel's frame.
    private var lastParkedLine: (edge: FloatingCaptureGeometry.DockEdge, line: CGRect)?

    /// Pinned floats above everything. Unpinned drops to the normal level and
    /// rides the editor instead — see `followEditorIfUnpinned`.
    private func applyPinState() {
        panel.level = pinState.isPinned ? .floating : .normal
    }

    /// The editor came forward. An unpinned panel goes with it — that ordering
    /// is the only way back for a panel buried behind other windows, since it
    /// never becomes key and so can never raise itself.
    ///
    /// One rule, no special cases: it does not matter whether the user raised
    /// the editor, the Dock did, or a finished capture presented it. What DOES
    /// matter is the editor's level at the moment we ask: `raiseAboveOtherApps`
    /// parks it at `.floating` for a quarter of a second, and an `order(.above:)`
    /// against a higher-level window is silently dropped. So the caller wires
    /// this to BOTH `didBecomeKey` (which fires inside that promotion) and
    /// `EditorController.editorWindowLevelDidSettleNotification` (which fires
    /// once it ends); the returned flag says whether this particular call could
    /// have done anything.
    @discardableResult
    func followEditorIfUnpinned(_ editorWindow: NSWindow) -> Bool {
        guard isVisible, FloatingPinPolicy.followsEditor(pinState) else { return false }
        followAttemptsForTesting += 1
        panel.order(.above, relativeTo: editorWindow.windowNumber)
        return FloatingPinPolicy.orderAboveTakesEffect(panelLevel: panel.level.rawValue,
                                                       editorLevel: editorWindow.level.rawValue)
    }

    var panelLevelForTesting: NSWindow.Level { panel.level }
    /// Counts the follows that got past the visible/unpinned gate — the only
    /// observable trace of an ordering call in a headless test.
    private(set) var followAttemptsForTesting = 0

    // MARK: Drag lifelines

    /// Promise-delegate lifelines for drags started from the thumbnail tiles.
    /// AppKit holds a promise provider's delegate WEAKLY, so something must
    /// keep it alive until the drop is fulfilled — and it cannot be the tile:
    /// `renderThumbnails()` destroys and recreates every tile on each landed
    /// capture AND on `editorWasOpened()`, either of which can happen while a
    /// drag to Finder is still unfulfilled. A tile-owned retainer dies with the
    /// tile and the drop silently produces nothing.
    private var dragRetainers: [AnyObject] = []
    /// Bounded so a long session cannot accumulate export state forever. NOT
    /// cleared when a new drag starts (which is all a per-tile retainer could
    /// do): an earlier drag's promise may still be waiting on its drop.
    private static let maxDragRetainers = 4

    /// Hold a promise delegate alive on the tile's behalf.
    func retainDragLifeline(_ object: AnyObject) {
        dragRetainers.append(object)
        if dragRetainers.count > Self.maxDragRetainers {
            dragRetainers.removeFirst(dragRetainers.count - Self.maxDragRetainers)
        }
    }

    var dragRetainerCountForTesting: Int { dragRetainers.count }
    var thumbnailTilesForTesting: [FloatingCaptureThumbnailView] {
        thumbnailRow.arrangedSubviews.compactMap { $0 as? FloatingCaptureThumbnailView }
    }

    // MARK: Drag and position

    /// Called when a drag ends: snap to the nearest edges, remember where we
    /// landed FOR THIS DISPLAY, and record which corner we're parked in so the
    /// panel can follow the pointer to another monitor.
    /// While dragging, show a line along each edge the panel would snap to if
    /// the user let go now — vertical for a side, horizontal for a top or
    /// bottom, both when it is heading into a corner. Same calculation the
    /// release itself uses, so the preview cannot promise a snap that then
    /// doesn't happen.
    func updateSnapGuides() {
        guard let screen = nearestScreen() else {
            snapGuides.hide()
            return
        }
        // Past the dock trigger, preview the DOCK: one line hard against the
        // edge the panel would collapse to.
        if let edge = FloatingCaptureGeometry.dockEdge(for: panel.frame,
                                                       in: screen.visibleFrame) {
            let v = screen.visibleFrame
            switch edge {
            case .left:   snapGuides.show(on: screen, verticalX: v.minX, horizontalY: nil)
            case .right:  snapGuides.show(on: screen, verticalX: v.maxX, horizontalY: nil)
            case .top:    snapGuides.show(on: screen, verticalX: nil, horizontalY: v.maxY)
            case .bottom: snapGuides.show(on: screen, verticalX: nil, horizontalY: v.minY)
            }
            return
        }
        let (settled, corner) = FloatingCaptureGeometry.snapped(panel.frame,
                                                                in: screen.visibleFrame)
        var verticalX: CGFloat?
        var horizontalY: CGFloat?
        switch corner.horizontal {
        case .left:  verticalX = settled.minX
        case .right: verticalX = settled.maxX
        case nil:    break
        }
        switch corner.vertical {
        case .bottom: horizontalY = settled.minY
        case .top:    horizontalY = settled.maxY
        case nil:     break
        }
        snapGuides.show(on: screen, verticalX: verticalX, horizontalY: horizontalY)
    }

    var snapGuidesForTesting: FloatingSnapGuideOverlay { snapGuides }

    /// `userInitiated` is false only for the internal settle that follows a
    /// restore-from-dock. A real drag of the PANEL means the user has chosen a
    /// new place for it, so auto-dock forgets where the line used to sit; the
    /// restore path must not, or peeking at the panel would lose the spot.
    func settleAfterDrag(userInitiated: Bool = true) {
        snapGuides.hide()
        guard let screen = nearestScreen() else { return }
        // Shoved PAST an edge → dock to a line there (or re-park a dragged
        // line). Small overshoots fall through to the ordinary snap-back.
        if let edge = FloatingCaptureGeometry.dockEdge(for: panel.frame,
                                                       in: screen.visibleFrame) {
            dock(to: edge, on: screen)
            return
        }
        if dockedEdge != nil {
            switch FloatingCaptureGeometry.lineRelease(for: panel.frame,
                                                       in: screen.visibleFrame) {
            case .repark(let edge):
                // Dropped near an edge: stay a line there. Restoring here made
                // every slide along the edges an accidental restore.
                dock(to: edge, on: screen)
                return
            case .undock:
                // Pulled clearly off the edge: the drag IS the restore — the
                // user has picked a new home for the panel.
                lastParkedLine = nil
                // The
                // panel comes back under the drop point and the ordinary
                // snap below settles it.
                let center = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
                clearDockChrome()
                panel.setFrame(NSRect(x: center.x - dockedSavedSize.width / 2,
                                      y: center.y - dockedSavedSize.height / 2,
                                      width: dockedSavedSize.width,
                                      height: dockedSavedSize.height),
                               display: true, animate: false)
            }
        }
        if userInitiated, dockedEdge == nil { lastParkedLine = nil }
        let (settled, corner) = FloatingCaptureGeometry.snapped(panel.frame,
                                                                in: screen.visibleFrame)
        panel.setFrame(settled, display: true, animate: false)
        snappedCorner = corner.isCorner ? corner : nil
        currentDisplayID = Self.displayID(for: screen)
        if let id = currentDisplayID {
            positions.setFrame(settled, forDisplay: id)
        }
        updatePointerFollowMonitor()
    }

    /// The screen the panel is on — or, when it has been dragged fully off
    /// every screen (which is exactly how docking is triggered), the screen
    /// whose visible frame is nearest to it. `panel.screen` alone is nil in
    /// that state, and `.main` may be a different display entirely.
    private func nearestScreen() -> NSScreen? {
        if let screen = panel.screen { return screen }
        let center = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        return NSScreen.screens.min(by: { a, b in
            func dist(_ r: CGRect) -> CGFloat {
                let dx = max(r.minX - center.x, 0, center.x - r.maxX)
                let dy = max(r.minY - center.y, 0, center.y - r.maxY)
                return dx * dx + dy * dy
            }
            return dist(a.frame) < dist(b.frame)
        }) ?? NSScreen.main
    }

    // MARK: Edge docking

    /// `line` overrides the computed position — used when re-entering a dock
    /// remembered from the last run, where the stored line IS the answer and
    /// deriving it from the panel's current frame would move it.
    /// `savedSize` overrides the size a click on the line restores to. Only the
    /// launch path passes it — there the panel's current size is whatever the
    /// remembered floating frame happened to be, while the persisted state
    /// knows what it actually was before docking.
    private func dock(to edge: FloatingCaptureGeometry.DockEdge, on screen: NSScreen,
                      line explicitLine: CGRect? = nil, animated: Bool = false,
                      savedSize: NSSize? = nil) {
        if let savedSize { dockedSavedSize = savedSize }
        else if dockedEdge == nil { dockedSavedSize = panel.frame.size }
        dockedEdge = edge
        let line = explicitLine ?? FloatingCaptureGeometry.dockedLineFrame(
            edge: edge, near: panel.frame, in: screen.visibleFrame)
        content.subviews.forEach { $0.isHidden = ($0 !== dockedLineView) }
        if dockedLineView.superview == nil {
            content.addSubview(dockedLineView)
            NSLayoutConstraint.activate([
                dockedLineView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                dockedLineView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                dockedLineView.topAnchor.constraint(equalTo: content.topAnchor),
                dockedLineView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
        }
        let chevron = FloatingCaptureGeometry.dockedChevronSymbol(for: edge)
        dockedChevron.image = NSImage(systemSymbolName: chevron,
                                      accessibilityDescription: chevron)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .bold))
        dockedLineView.isHidden = false
        panel.alphaValue = 1
        // The hidden column's constraints would keep the window at panel
        // width; release them so an 8pt line is a legal window size.
        NSLayoutConstraint.deactivate(columnConstraints)
        if animated {
            slideToDockedLine(line)
        } else {
            // No animation on the drag/launch paths: the frame must BE the
            // line the moment docking returns — an in-flight animation left
            // tests (and the next pointer poll) reading the old frame.
            panel.setFrame(line, display: true, animate: false)
        }
        snappedCorner = nil
        updatePointerFollowMonitor()
        // Where the line sits NOW, for auto-dock to return to. Survives an
        // undock (unlike the persisted state below), because sliding the line
        // somewhere and then peeking at the panel shouldn't lose the spot.
        lastParkedLine = (edge, line)
        // Remember it, so a restart brings the line back on the same edge in
        // the same place rather than a full panel at the pre-dock spot.
        if let id = Self.displayID(for: screen) {
            positions.setDockState(
                .init(edge: edge, line: line, panelSize: dockedSavedSize), forDisplay: id)
        }
    }

    /// Slide the panel into its docked line, the same motion the panel uses
    /// when it follows the pointer to another display: same 0.24s ease-out,
    /// same `animator().setFrame` (an `NSWindow` animator proxy only animates
    /// `frame` — `setFrameOrigin` falls through to the immediate setter and
    /// nothing moves), and the same explicit landing afterwards so an
    /// interrupted animation can't leave the panel mid-flight.
    private func slideToDockedLine(_ line: CGRect) {
        isSliding = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.slideDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(line, display: true)
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isSliding = false
                // Only land it if we're still docked: a click on the line
                // during the slide restores the panel, and forcing the line
                // frame afterwards would collapse it again.
                if self.dockedEdge != nil {
                    self.panel.setFrame(line, display: true, animate: false)
                }
            }
        }
    }

    /// Re-enter the dock persisted for `screen`, if there is one. The stored
    /// line is validated against the attached screens first — the same rule
    /// the free-floating frame gets, so a dock made on a monitor that is no
    /// longer here doesn't strand the panel off-screen.
    @discardableResult
    private func restorePersistedDock(on screen: NSScreen) -> Bool {
        guard dockedEdge == nil else { return false }
        let visibleFrames = NSScreen.screens.map(\.visibleFrame)
        // Prefer this screen's dock, then ANY attached display's. The state is
        // keyed per display, and at launch the panel starts wherever its
        // remembered floating frame put it — usually the main screen. Without
        // the fallback, a panel docked on a secondary monitor simply never
        // came back docked, which is most of the point on a multi-display desk.
        let candidate: (screen: NSScreen, state: FloatingCapturePositionStore.DockedState)?
        if let id = Self.displayID(for: screen),
           let saved = positions.dockState(forDisplay: id) {
            candidate = (screen, saved)
        } else {
            candidate = NSScreen.screens.lazy.compactMap { [positions] other in
                guard let id = Self.displayID(for: other),
                      let saved = positions.dockState(forDisplay: id) else { return nil }
                return (other, saved)
            }.first
        }
        guard let (dockScreen, saved) = candidate,
              FloatingCapturePositionStore.validated(saved.line, against: visibleFrames) != nil
        else { return false }
        let screen = dockScreen
        dock(to: saved.edge, on: screen, line: saved.line, savedSize: saved.panelSize)
        return true
    }

    /// Click on the line (or its chevron): bring the panel back beside its
    /// edge — deliberately NOT at wherever it lived before it was docked,
    /// which under auto-dock would fling it across the screen on every peek.
    /// `animated` slides the panel out from its edge, the mirror of the slide
    /// that tucked it in. Off by default: the frame must BE the restored one
    /// the moment this returns for the paths that immediately act on it.
    func restoreFromDock(animated: Bool = false) {
        guard let edge = dockedEdge, let screen = nearestScreen() else { return }
        let visible = screen.visibleFrame
        let frame = FloatingCaptureGeometry.restoredFrame(
            from: panel.frame, edge: edge, size: dockedSavedSize, in: visible)
        // The panel is about to grow out from under the pointer; hold off
        // auto-docking until it has actually been hovered.
        pointerHasEnteredSinceRestore = false
        // ...and hold off naming the tile it grows out from under.
        suppressTileTooltipsUntilPointerMoves()
        // The line's own frame, read BEFORE the chrome goes away: the panel
        // grows out of the line the user is looking at. Sliding in from off
        // the screen edge instead made the panel arrive from somewhere the
        // line wasn't — the line can sit anywhere ALONG its edge.
        let start = panel.frame
        clearDockChrome()
        guard animated else {
            panel.setFrame(frame, display: true, animate: false)
            settleAfterRestore()
            return
        }
        panel.setFrame(start, display: false, animate: false)
        isSliding = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.slideDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isSliding = false
                // Land it explicitly — an interrupted animation would leave the
                // panel part-way off the edge — unless the user has re-docked
                // it in the meantime, when forcing this frame would undo that.
                guard self.dockedEdge == nil else { return }
                self.panel.setFrame(frame, display: true, animate: false)
                // The panel is already at `frame`, so this only records state.
                self.settleAfterRestore()
            }
        }
    }

    /// Record where a panel restored from a dock has landed — WITHOUT the
    /// corner snap `settleAfterDrag` applies.
    ///
    /// The restored frame is already deliberate: beside the edge the line was
    /// on. Snapping it dragged the panel off into whichever corner it happened
    /// to be near, which on a line parked close to a corner meant peeking at
    /// the panel MOVED it. Snapping belongs to dragging, where the user is
    /// steering and the pull is a help rather than a surprise. The corner is
    /// still re-read, so a panel that genuinely lands in one is known to be
    /// cornered — that is what carries it between displays.
    private func settleAfterRestore() {
        guard let screen = nearestScreen() else { return }
        refreshSnappedCorner(on: screen)
        currentDisplayID = Self.displayID(for: screen)
        if let id = currentDisplayID { positions.setFrame(panel.frame, forDisplay: id) }
        updatePointerFollowMonitor()
    }

    private func clearDockChrome() {
        dockedEdge = nil
        dockedLineView.isHidden = true
        content.subviews.forEach { if $0 !== dockedLineView { $0.isHidden = false } }
        NSLayoutConstraint.activate(columnConstraints)
        // Undocking is as much a decision as docking was: forget it, or the
        // next launch would tuck the panel away again.
        if let screen = nearestScreen(), let id = Self.displayID(for: screen) {
            positions.clearDockState(forDisplay: id)
        }
    }

    /// Test hook: dock/restore without a mouse.
    var isDockedForTesting: Bool { dockedEdge != nil }

    // MARK: Following the pointer across displays

    /// The corner the panel is parked in, or nil when it was left free-floating.
    /// Only a fully-cornered panel follows the pointer: a panel the user placed
    /// somewhere specific should stay where they put it.
    private var snappedCorner: FloatingCaptureGeometry.Corner?
    private var pointerTimer: Timer?
    /// The display the panel has been PLACED on. The authority for "has it
    /// moved yet?", because `panel.screen` is nil whenever the panel sits
    /// outside every screen — which the slide does on purpose.
    private var currentDisplayID: String?
    /// Preview lines shown while dragging, marking the edges the panel will
    /// snap to if released now.
    private let snapGuides = FloatingSnapGuideOverlay()
    /// Docked-to-edge state: drag the panel PAST a screen edge and it collapses
    /// to a thin line there; click or drag the line to restore. While docked
    /// the content is hidden, fade/follow/snap are suspended, and the saved
    /// size is what the restore brings back.
    private(set) var dockedEdge: FloatingCaptureGeometry.DockEdge?
    private var dockedSavedSize: NSSize = .zero
    /// The column's layout, released while docked (see `buildViews`).
    private var columnConstraints: [NSLayoutConstraint] = []
    private let dockedChevron = NSImageView()
    private lazy var dockedLineView: NSView = {
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        line.layer?.cornerRadius = FloatingCaptureGeometry.dockedLineThickness / 2
        line.isHidden = true
        line.translatesAutoresizingMaskIntoConstraints = false
        // The restore affordance: an arrow pointing back into the screen.
        dockedChevron.translatesAutoresizingMaskIntoConstraints = false
        dockedChevron.contentTintColor = .white
        line.addSubview(dockedChevron)
        NSLayoutConstraint.activate([
            dockedChevron.centerXAnchor.constraint(equalTo: line.centerXAnchor),
            dockedChevron.centerYAnchor.constraint(equalTo: line.centerYAnchor),
        ])
        return line
    }()

    var dockedChevronSymbolForTesting: String? { dockedChevron.image?.accessibilityDescription }

    /// True for the length of a slide, so a poll mid-flight cannot restart it.
    private var isSliding = false

    /// Watch the pointer only while it can matter — parked in a corner, visible,
    /// and more than one display attached.
    ///
    /// A poll, not a global `.mouseMoved` monitor. The monitor version worked
    /// until a capture ran, then delivered nothing until the user clicked
    /// something: global monitors observe events delivered to OTHER apps, and
    /// after our own overlay tore down its event handling there was a window
    /// where nothing was being delivered to observe. Sampling the pointer
    /// sidesteps event delivery entirely — it is four comparisons a second and
    /// cannot be starved.
    private func updatePointerFollowMonitor() {
        updateClickAwayMonitors()
        // A docked line follows the pointer too, so it wants the poll as much
        // as a corner-parked panel does — and with auto-hide on it also drives
        // the hover-to-reveal dwell, which matters on a single display where
        // there is nothing to follow.
        let multiDisplay = NSScreen.screens.count > 1
        let docked = dockedEdge != nil
        let wanted = panel.isVisible
            && ((snappedCorner != nil && multiDisplay)
                || (docked && (multiDisplay || autoDockEnabled)))
        if wanted, pointerTimer == nil {
            let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.recoverIfStranded()
                    self?.followPointerIfNeeded()
                    self?.updateAutoReveal()
                }
            }
            // .common so it keeps sampling while a menu is tracking or a window
            // is being dragged — exactly when the pointer is most likely to
            // cross displays.
            RunLoop.main.add(timer, forMode: .common)
            pointerTimer = timer
        } else if !wanted {
            pointerTimer?.invalidate()
            pointerTimer = nil
        }
    }

    /// Move a corner-parked panel to the same corner of whichever display the
    /// pointer is on. Cheap: this runs on every mouse move, so it does nothing
    /// at all unless the pointer's screen differs from the panel's.
    func followPointerIfNeeded(pointer: NSPoint = NSEvent.mouseLocation,
                               animated: Bool = true) {
        // Never while the user is dragging the panel. Carrying it to another
        // display mid-drag fights the hand holding it: the poll slid the panel
        // to the new screen's corner, the next drag event snapped it back
        // under the cursor, and the panel appeared to jump to the edge and
        // return. A drag already says where the panel goes.
        guard panel.isVisible, !isSliding, !content.isDraggingPanel else { return }
        guard let target = NSScreen.screens.first(where: { $0.frame.contains(pointer) })
        else { return }
        // A docked line follows too: it is the panel, just tucked away, and
        // leaving it behind on another display makes it unreachable from where
        // the user is working.
        if dockedEdge != nil {
            followPointerWhileDocked(to: target, animated: animated)
            return
        }
        guard let corner = snappedCorner else { return }

        // Compare against the display we PUT the panel on, never against
        // `panel.screen`. During the slide the panel is deliberately parked
        // outside the target's bounds, where `panel.screen` is nil — so a
        // screen-derived check said "not there yet" on every poll and restarted
        // the slide from off-screen, which is how the panel vanished for good.
        let targetID = Self.displayID(for: target)
        guard targetID != currentDisplayID else { return }
        currentDisplayID = targetID

        let visible = target.visibleFrame
        let size = panel.frame.size
        let destination = FloatingCaptureGeometry.origin(for: corner, size: size, in: visible)

        guard animated else {
            panel.setFrameOrigin(destination)
            rememberPosition(displayID: targetID)
            return
        }

        // Slide IN from the edge it is parked against, rather than flying across
        // the desk from the old monitor: a window crossing a bezel gap looks
        // like a glitch, whereas arriving from its own corner reads as the
        // panel following you.
        var start = destination
        switch corner.horizontal {
        case .right: start.x = visible.maxX
        case .left:  start.x = visible.minX - size.width
        case nil:    start.y = corner.vertical == .top ? visible.maxY : visible.minY - size.height
        }
        panel.setFrameOrigin(start)
        isSliding = true

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.slideDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            // `setFrame(_:display:)`, not `setFrameOrigin` — an `NSWindow`
            // animator proxy only animates `frame`, so the origin-only call
            // fell through to the immediate setter and the panel simply
            // appeared at its destination with no motion at all.
            panel.animator().setFrame(NSRect(origin: destination, size: size), display: true)
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isSliding = false
                // Land it explicitly. An interrupted animation would otherwise
                // leave the panel wherever it stopped — which, since it starts
                // off-screen, could be nowhere the user can see or reach.
                self.panel.setFrameOrigin(destination)
                self.rememberPosition(displayID: targetID)
            }
        }
    }

    /// Last resort: a visible panel that lands outside every screen is
    /// unreachable — no pointer can hover it and no click can drag it back.
    /// Whatever stranded it (an interrupted slide, a display unplugged
    /// mid-animation), put it back on the pointer's screen.
    /// The desk changed: displays plugged, unplugged, or rearranged.
    ///
    /// Re-arm the pointer poll — its arming depends on the display COUNT, so
    /// the last evaluation is stale the moment this fires — and then rescue
    /// the panel if the screen it was living on has just gone away.
    func screenSetupChanged() {
        updatePointerFollowMonitor()
        recoverIfStranded()
    }

    func recoverIfStranded() {
        guard panel.isVisible, !isSliding, !content.isDraggingPanel else { return }
        // A docked line hugs the inside of a real edge, so it can only be
        // stranded by that edge's DISPLAY disappearing — and then it is
        // stranded with no chevron to click and no panel to drag. It used to
        // be excluded from recovery entirely, which made unplugging a monitor
        // with a docked panel unrecoverable short of relaunching.
        if let edge = dockedEdge { return recoverStrandedLine(edge: edge) }
        let frame = panel.frame
        guard !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) else { return }
        guard let screen = NSScreen.screens.first(where: {
            $0.frame.contains(NSEvent.mouseLocation)
        }) ?? NSScreen.main else { return }

        let corner = snappedCorner ?? FloatingCaptureGeometry.Corner(horizontal: .right,
                                                                     vertical: .top)
        panel.setFrameOrigin(FloatingCaptureGeometry.origin(for: corner, size: frame.size,
                                                            in: screen.visibleFrame))
        currentDisplayID = Self.displayID(for: screen)
        rememberPosition(displayID: currentDisplayID)
    }

    /// Carry a stranded docked line to a live screen, keeping its edge.
    ///
    /// The persisted dock is deliberately left alone, for the same reason
    /// following the pointer across displays leaves it alone: the user docked
    /// it on THAT display, and unplugging is not them changing their mind.
    /// Plug the display back in and their choice is still recorded.
    private func recoverStrandedLine(edge: FloatingCaptureGeometry.DockEdge) {
        guard panel.screen == nil else { return }
        guard let screen = NSScreen.screens.first(where: {
            $0.frame.contains(NSEvent.mouseLocation)
        }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        // The old position is in coordinates that no longer exist, so there is
        // no relative position to carry over — `dockedLineFrame` clamps it to
        // somewhere real on the same edge.
        let line = FloatingCaptureGeometry.dockedLineFrame(
            edge: edge, near: panel.frame, in: visible)
        panel.setFrame(line, display: true, animate: false)
        lastParkedLine = (edge, line)
        currentDisplayID = Self.displayID(for: screen)
    }

    private func rememberPosition(displayID: String?) {
        guard let displayID else { return }
        positions.setFrame(panel.frame, forDisplay: displayID)
    }

    deinit {
        autoRevealTimer?.invalidate()
        autoDockTimer?.invalidate()
        clickAwayMonitors.forEach(NSEvent.removeMonitor)
        tooltipWakeMonitors.forEach(NSEvent.removeMonitor)
        pointerTimer?.invalidate()
        stripRefreshTask?.cancel()
        for observer in [captureFeedObserver, indexChangeObserver, screenChangeObserver] {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }

    /// Restore the remembered frame for the screen we're about to appear on,
    /// discarding one that no longer lands on any attached screen.
    private func restoreFrame() {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let remembered = Self.displayID(for: screen).flatMap { positions.frame(forDisplay: $0) }
        let visibleFrames = NSScreen.screens.map(\.visibleFrame)
        if let frame = FloatingCapturePositionStore.validated(remembered, against: visibleFrames) {
            panel.setFrame(frame, display: false)
        } else {
            // Default: bottom-right, the corner least likely to sit over work.
            let visible = screen.visibleFrame
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(
                x: visible.maxX - size.width - FloatingCaptureGeometry.margin,
                y: visible.minY + FloatingCaptureGeometry.margin))
        }
        refreshSnappedCorner(on: screen)
    }

    /// Work out which corner the panel is sitting in right now.
    ///
    /// Only `settleAfterDrag` used to set this, so a panel that had never been
    /// dragged — every panel on its first appearance, including one restored
    /// into a corner it was dragged to in a previous session — counted as
    /// free-floating and refused to follow the pointer. Following was
    /// unreachable until you picked the panel up and put it down again.
    private func refreshSnappedCorner(on screen: NSScreen) {
        let (_, corner) = FloatingCaptureGeometry.snapped(panel.frame, in: screen.visibleFrame)
        snappedCorner = corner.isCorner ? corner : nil
    }

    /// Stable per-monitor identity. `NSScreen.frame` is not usable as a key —
    /// rearranging displays changes it while the monitor stays the same.
    nonisolated private static func displayID(for screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value) else {
            return "screen-\(number.uint32Value)"
        }
        return CFUUIDCreateString(nil, uuid.takeRetainedValue()) as String
    }
}

/// Follow the recording state the same way the status item does, so the panel
/// and the menu bar always show the same thing.
extension FloatingCaptureController: RecordingStateObserver {
    func recordingDidStart() { setRecording(true, paused: false) }
    func recordingDidStop() { setRecording(false, paused: false) }
    func recordingPausedChanged(_ paused: Bool) { setRecording(true, paused: paused) }
}
