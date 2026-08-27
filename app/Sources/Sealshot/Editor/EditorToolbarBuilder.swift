import AppKit
import KeyboardShortcuts
import os.log

private let log = OSLog(subsystem: "com.seal-shot.sealshot", category: "editor")

/// Builds the editor's tool bar as a plain `NSView` (a horizontal stack of
/// `ActiveToolPillView` buttons), hosted in a `.bottom` titlebar accessory
/// *below* the Editor/Library/Settings tab switcher. Holds weak refs to the
/// pills so tool selection, undo/redo enabling, and the copy-confirmation
/// flash can be driven after the bar is built.
@MainActor
final class EditorToolbarBuilder: NSObject {

    /// Callbacks for the toolbar's actions. Set by the owner before
    /// `makeToolbarView()` is called.
    var onSelectTool: ((EditorTool) -> Void)?
    var onCopyAll: (() -> Void)?
    var onExportPNG: (() -> Void)?
    var onCapture: (() -> Void)?
    var onCaptureWindow: (() -> Void)?
    var onCaptureUnified: (() -> Void)?
    var onCaptureDelayed: (() -> Void)?
    var onCaptureScroll: (() -> Void)?
    var onCaptureLive: (() -> Void)?
    var onCaptureFullscreen: (() -> Void)?
    var onRecordScreen: (() -> Void)?
    var onRecordSelection: (() -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onFindInImage: (() -> Void)?
    var onToggleInfo: (() -> Void)?
    /// Tapped to enhance (when not yet enhanced) or to flip original/enhanced.
    var onEnhanceTapped: (() -> Void)?
    var onRemoveBackgroundTapped: (() -> Void)?
    /// Tapped to scan for sensitive content (or cancel an in-flight scan).
    var onSmartRedact: (() -> Void)?
    /// On-device Foundation Model text actions, surfaced via the AI Summary pill.
    var onSummarize: (() -> Void)?
    /// Structured data extraction — available regardless of Apple Intelligence.
    var onExtractStructuredData: (() -> Void)?
    /// Selecting a drawing tool cancels any in-flight Smart Redact scan/proposals.
    var onSmartRedactCancel: (() -> Void)?
    /// Plus-pill dropdown actions — mirror the File menu's new/import items.
    var onNewCanvas: (() -> Void)?
    var onNewFromClipboard: (() -> Void)?
    var onImportToLibrary: (() -> Void)?
    /// Insert an image overlay onto the current canvas.
    var onInsertImage: (() -> Void)?
    /// Returns true when a canvas is loaded; used to gate the Insert Image item.
    var hasCanvasProvider: (() -> Bool)?

    private var toolPills: [ActiveToolPillView] = []
    // Grouped pills (Line/Arrow, Rectangle/Ellipse, …) keyed by group id, and
    // the sub-tool each currently fronts.
    private var groupPills: [String: GroupedToolPillView] = [:]
    private var groupCurrent: [String: EditorTool] = [:]
    /// Clusters folded away at the width the bar was last built for. Drives
    /// both which pills exist and `activeToolLayout`.
    private(set) var foldedClusters: Set<EditorToolbarFit.ClusterID> = []
    /// The drawing row as it stands right now. Selection and click routing go
    /// through this, never the static full-width layout, so a folded row
    /// highlights the pill that is actually on screen.
    private var activeToolLayout: [ToolSlot] = EditorToolbarBuilder.toolLayout
    private var toolPopover: NSPopover?
    private weak var undoPill: ActiveToolPillView?
    private weak var redoPill: ActiveToolPillView?
    private weak var copyPill: ActiveToolPillView?
    private weak var exportPill: ActiveToolPillView?
    private weak var imageTextSearchPill: ActiveToolPillView?
    private weak var infoPill: ActiveToolPillView?
    private weak var enhancePill: ActiveToolPillView?
    private weak var cutoutPill: ActiveToolPillView?
    private weak var smartRedactPill: ActiveToolPillView?
    private weak var extractStructuredPill: ActiveToolPillView?
    private weak var plusPill: ActiveToolPillView?
    private weak var delayedPill: DelayedCapturePill?
    // Narrow-width stand-ins; nil whenever their cluster is expanded.
    private weak var aiFoldedPill: ActiveToolPillView?
    private weak var trailingFoldedPill: ActiveToolPillView?
    // Latest desired Info-open state, applied when the pill is (re)created.
    private var infoActive = false
    private var imageTextSearchActive = false
    // Latest desired Enhance highlight (true = showing the enhanced base).
    private var enhanceActive = false
    // Latest desired Smart Redact highlight (true while a scan is running).
    private var smartRedactActive = false
    // Latest desired enabled state, applied when the pill is (re)created.
    private var undoEnabled = false
    private var redoEnabled = false
    // Read-only (a deleted/trashed capture): the editing pills stay greyed out.
    // Re-applied on every toolbar rebuild.
    private var readOnly = false

    // Blocking AI action (Extract Data / Smart Redact / summarize / Enhance
    // run): the whole bar is frozen via a transparent event-eater + dim,
    // WITHOUT touching per-pill isEnabled — so no truth restoration is
    // needed when the action ends (undo/redo, read-only, video-mode states
    // all keep themselves).
    private weak var barView: NSStackView?
    private weak var interactionBlocker: NSView?
    private var interactionEnabled = true

    /// Freeze/unfreeze every control in the bar while a blocking AI action
    /// runs. Idempotent; survives toolbar rebuilds (re-applied in
    /// `makeToolbarView`).
    func setInteractionEnabled(_ enabled: Bool) {
        interactionEnabled = enabled
        guard let bar = barView else { return }
        if enabled {
            interactionBlocker?.removeFromSuperview()
            interactionBlocker = nil
            bar.alphaValue = 1
        } else if interactionBlocker == nil {
            let blocker = ToolbarInteractionBlocker()
            blocker.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview(blocker)
            NSLayoutConstraint.activate([
                blocker.topAnchor.constraint(equalTo: bar.topAnchor),
                blocker.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
                blocker.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
                blocker.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            ])
            interactionBlocker = blocker
            bar.alphaValue = 0.45
        }
    }

    /// Enable/disable the Undo button (dims the glyph + ignores clicks).
    func setUndoEnabled(_ enabled: Bool) {
        undoEnabled = enabled
        undoPill?.isEnabled = enabled
    }

    /// Enable/disable the Redo button.
    func setRedoEnabled(_ enabled: Bool) {
        redoEnabled = enabled
        redoPill?.isEnabled = enabled
    }

    /// Read-only capture (deleted/trashed): grey out every pill that edits or
    /// acts on the open image — the drawing tools + Live Text, Smart Redact,
    /// Extract Data, Enhance, Remove Background, Info, Share, and Copy. Undo/Redo
    /// and the capture / `+` pills are left alone (capture makes a NEW image).
    /// Stored so a toolbar rebuild re-applies it; called on every state swap.
    func setReadOnly(_ readOnly: Bool) {
        self.readOnly = readOnly
        applyReadOnly()
    }

    private func applyReadOnly() {
        let enabled = !readOnly
        infoPill?.isEnabled = enabled
        imageTextSearchPill?.isEnabled = enabled
        enhancePill?.isEnabled = enabled
        cutoutPill?.isEnabled = enabled
        smartRedactPill?.isEnabled = enabled
        extractStructuredPill?.isEnabled = enabled
        exportPill?.isEnabled = enabled
        copyPill?.isEnabled = enabled
        // Folded, these stand in for pills this rule already greys out.
        aiFoldedPill?.isEnabled = enabled
        trailingFoldedPill?.isEnabled = enabled
        for pill in toolPills { pill.isEnabled = enabled }
    }

    /// Build the tool bar view. Same full layout in both states — Info + the
    /// `+` menu lead, the capture trio + Undo/Redo + tool group sit centered,
    /// and Export/Copy trail right. In empty mode (no open capture) the
    /// canvas-dependent pills are disabled, leaving only the `+` menu and the
    /// capture trio active.
    func makeToolbarView(empty: Bool = false,
                         folded: Set<EditorToolbarFit.ClusterID> = []) -> NSView {
        foldedClusters = folded
        let bar = NSStackView()
        bar.orientation = .horizontal
        bar.alignment = .centerY
        bar.distribution = .fill
        bar.spacing = 6
        bar.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        bar.translatesAutoresizingMaskIntoConstraints = false

        // Reset pill refs (a rebuild on state-swap replaces the bar wholesale).
        toolPills = []
        undoPill = nil
        redoPill = nil
        copyPill = nil
        exportPill = nil
        infoPill = nil
        imageTextSearchPill = nil
        enhancePill = nil
        cutoutPill = nil
        smartRedactPill = nil
        plusPill = nil
        delayedPill = nil
        aiFoldedPill = nil
        trailingFoldedPill = nil

        // Leading group: the New/Import (+) menu. (The Info toggle lives on the
        // trailing edge, next to Export — see below.)
        bar.addArrangedSubview(makePlusMenuPill())

        // Centered block: Capture, then undo/redo, then the tool group;
        // Export/Copy trail. Equal-width flex spacers on each side keep the
        // block centered in the bar (the side groups balance out).
        let leadSpacer = flexSpacer(), trailSpacer = flexSpacer()
        bar.addArrangedSubview(leadSpacer)

        // Capture: unified | full-screen, delayed, scrolling. Folded, the four
        // modes move into the Capture pill's own chevron menu — clicking it
        // still fires Smart Capture, so the primary action never moves.
        bar.addArrangedSubview(makeCaptureUnifiedPill(folded: folded.contains(.capture)))
        if !folded.contains(.capture) {
            bar.addArrangedSubview(divider())
            bar.addArrangedSubview(makeFullscreenCapturePill())
            bar.addArrangedSubview(makeDelayedCapturePill())
            bar.addArrangedSubview(makeScrollCapturePill())
            bar.addArrangedSubview(makeLiveCapturePill())
        }
        bar.addArrangedSubview(divider())

        // Record: full screen, selected area.
        if folded.contains(.record) {
            bar.addArrangedSubview(makeRecordFoldedPill())
        } else {
            bar.addArrangedSubview(makeRecordScreenPill())
            bar.addArrangedSubview(makeRecordSelectionPill())
        }
        bar.addArrangedSubview(divider())

        // Undo / Redo.
        bar.addArrangedSubview(makeUndoPill())
        bar.addArrangedSubview(makeRedoPill())
        bar.addArrangedSubview(divider())

        // Drawing tools (Select … Blur); Live Text trails after a divider as a
        // separate text-recognition mode, grouped with Enhance / Smart Redact.
        let toolPillViews = makeToolPills(folded: folded)
        for pill in toolPillViews.dropLast() { bar.addArrangedSubview(pill) }
        bar.addArrangedSubview(divider())
        if let liveText = toolPillViews.last { bar.addArrangedSubview(liveText) }
        if folded.contains(.ai) {
            bar.addArrangedSubview(makeAIFoldedPill())
        } else {
            bar.addArrangedSubview(makeSmartRedactPill())
            bar.addArrangedSubview(makeExtractStructuredPill())
            bar.addArrangedSubview(makeEnhancePill())
            bar.addArrangedSubview(makeCutoutPill())
        }

        bar.addArrangedSubview(trailSpacer)
        // Trailing group: Find in Image immediately before Info, then Export
        // (Share) and Copy All. Folded, everything but Export — the one that
        // gets something OUT of the app — moves into a ⋯ menu.
        if folded.contains(.trailing) {
            bar.addArrangedSubview(makeTrailingFoldedPill())
            bar.addArrangedSubview(makeExportPill())
        } else {
            bar.addArrangedSubview(makeImageTextSearchPill())
            bar.addArrangedSubview(makeInfoTogglePill())
            bar.addArrangedSubview(makeExportPill())
            bar.addArrangedSubview(makeCopyPill())
        }
        leadSpacer.widthAnchor.constraint(equalTo: trailSpacer.widthAnchor).isActive = true

        // Empty editor (no open capture): show the full toolbar, but disable
        // everything that needs a canvas — only the + menu and the capture trio
        // work without an image.
        if empty { disableCanvasDependentPills() }
        // Re-apply the read-only greying after a rebuild (e.g. empty→loaded).
        else if readOnly { applyReadOnly() }
        // A rebuild mid-action replaces the bar wholesale — re-freeze it.
        barView = bar
        interactionBlocker = nil
        setInteractionEnabled(interactionEnabled)
        return bar
    }

    /// Grey out the pills that operate on the open capture, leaving the + menu
    /// and capture trio active. Used in empty mode.
    private func disableCanvasDependentPills() {
        infoPill?.isEnabled = false
        imageTextSearchPill?.isEnabled = false
        undoPill?.isEnabled = false
        redoPill?.isEnabled = false
        enhancePill?.isEnabled = false
        cutoutPill?.isEnabled = false
        smartRedactPill?.isEnabled = false
        extractStructuredPill?.isEnabled = false
        exportPill?.isEnabled = false
        copyPill?.isEnabled = false
        // The folded stand-ins hold nothing BUT canvas-dependent actions, so
        // they follow the pills they replaced.
        aiFoldedPill?.isEnabled = false
        trailingFoldedPill?.isEnabled = false
        for pill in toolPills { pill.isEnabled = false }
    }

    /// Hide the image-only tools while a video plays in the canvas: the drawing
    /// tools, Live Text, Enhance, Smart Redact, and Copy — none of which apply to
    /// a video. Export STAYS visible (it exports the current video instead of an
    /// image). New/Import, the capture trio, the Info toggle, and Undo/Redo stay.
    /// Pass `false` to restore the image-only ones when playback ends.
    func setVideoMode(_ on: Bool) {
        enhancePill?.isHidden = on
        imageTextSearchPill?.isHidden = on
        smartRedactPill?.isHidden = on
        extractStructuredPill?.isHidden = on
        cutoutPill?.isHidden = on   // Remove Background — image-only, hide for video
        copyPill?.isHidden = on
        // Folded, the AI pill is image-only in its entirety and hides like the
        // four it replaced. The ⋯ pill stays: it still carries Info, which
        // applies to a video (Find in Image and Copy All read as no-ops there,
        // matching how the Info pill behaves at full width).
        aiFoldedPill?.isHidden = on
        for pill in toolPills { pill.isHidden = on }
    }

    /// Programmatically reflect the current tool in the bar's selection.
    /// Called by the controller when the user switches tools via a means
    /// other than clicking a button (e.g., a fresh session opening in
    /// select mode, or Esc returning to Select).
    func setSelectedTool(_ tool: EditorTool) {
        guard let index = slotIndex(for: tool) else { return }
        for (i, pill) in toolPills.enumerated() {
            pill.isActive = (i == index)
        }
        // When the active tool belongs to a group, mirror it on that grouped
        // pill so its icon/label reflect what is armed.
        if let group = group(containing: tool) { showGroupSubTool(tool, in: group) }
    }

    /// Reflect whether the left Info panel is open (highlights the 'i' button).
    func setInfoActive(_ active: Bool) {
        infoActive = active
        infoPill?.isActive = active
    }

    /// Reflect whether Find in Image owns the sidebar and toolbar highlight.
    func setImageTextSearchActive(_ active: Bool) {
        imageTextSearchActive = active
        imageTextSearchPill?.isActive = active
    }

    /// De-highlight every tool pill (including grouped slots). Used when Info is
    /// active: 'i' becomes the highlighted item and no tool is shown selected.
    func clearToolHighlight() {
        for pill in toolPills { pill.isActive = false }
        for pill in groupPills.values { pill.isActive = false }
    }

    /// Reflect enhance state on the toolbar pill: highlighted while the enhanced
    /// base is being shown.
    func setEnhanceActive(_ active: Bool) {
        enhanceActive = active
        enhancePill?.isActive = active
    }

    /// Flash a "Copied" confirmation on the copy button.
    func flashCopied() {
        copyPill?.flashConfirmation(symbolName: "checkmark", tint: .systemGreen, text: "Copied")
    }

    /// Highlight the Smart Redact pill while a scan is running.
    func setSmartRedactScanning(_ scanning: Bool) {
        smartRedactActive = scanning
        smartRedactPill?.isActive = scanning
    }

    /// Turn Smart Redact off and tell the owner to cancel any scan/proposals.
    /// Called when a drawing tool is selected — the two are mutually exclusive.
    private func deactivateSmartRedact() {
        guard smartRedactActive else { return }
        smartRedactActive = false
        smartRedactPill?.isActive = false
        onSmartRedactCancel?()
    }

    // MARK: - Spacers

    /// A zero-content view that expands to soak up extra width, centering
    /// the items between it and the next flexible spacer.
    private func flexSpacer() -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.setContentHuggingPriority(.init(1), for: .horizontal)
        v.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        return v
    }

    /// A thin vertical hairline separating toolbar groups.
    private func divider() -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.separatorColor.cgColor
        v.widthAnchor.constraint(equalToConstant: 1).isActive = true
        v.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return v
    }

    /// A fixed-width gap.
    private func fixedSpacer(_ width: CGFloat) -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: width).isActive = true
        return v
    }

    // MARK: - Pills

    private func makeInfoTogglePill() -> ActiveToolPillView {
        let pill = ActiveToolPillView(
            symbolName: "info.circle",
            accessibilityLabel: "Info",
            symbolPointSize: 16
        ) { [weak self] in
            self?.onToggleInfo?()
        }
        pill.tooltipText = "Info panel"
        pill.isActive = infoActive
        infoPill = pill
        return pill
    }

    private func makeImageTextSearchPill() -> ActiveToolPillView {
        let pill = ActiveToolPillView(
            symbolName: "magnifyingglass",
            accessibilityLabel: "Find in Image",
            symbolPointSize: 16
        ) { [weak self] in
            self?.onFindInImage?()
        }
        pill.tooltipText = "Find in Image (⌘F)"
        pill.isActive = imageTextSearchActive
        imageTextSearchPill = pill
        return pill
    }

    /// Plus pill: pops a dropdown mirroring File → New Canvas / New from
    /// Clipboard / Import to Library….
    private func makePlusMenuPill() -> ActiveToolPillView {
        let pill = ActiveToolPillView(
            symbolName: "plus.circle",
            accessibilityLabel: "New",
            symbolPointSize: 16
        ) { [weak self] in
            guard let self, let pill = self.plusPill else { return }
            self.showPlusMenu(from: pill)
        }
        pill.tooltipText = "New / Import"
        plusPill = pill
        return pill
    }

    /// The plus dropdown. Key equivalents are display-only (the real
    /// shortcuts live on the menu bar). `clipboardHasImage` defaults to a
    /// fresh pasteboard check so the disabled state is current each open;
    /// it's a parameter so tests can pin both states. `hasCanvas` overrides
    /// `hasCanvasProvider` (used by tests to pin both enabled states).
    func makePlusMenu(
        clipboardHasImage: Bool = NewCanvasFactory.clipboardHasImage(),
        hasCanvas: Bool? = nil
    ) -> NSMenu {
        let canvasAvailable = hasCanvas ?? hasCanvasProvider?() ?? false

        let menu = NSMenu()
        menu.autoenablesItems = false

        let newCanvas = NSMenuItem(title: "New Canvas",
                                   action: #selector(plusNewCanvas), keyEquivalent: "n")
        newCanvas.keyEquivalentModifierMask = [.command]
        newCanvas.target = self
        menu.addItem(newCanvas)

        let fromClipboard = NSMenuItem(title: "New from Clipboard",
                                       action: #selector(plusNewFromClipboard), keyEquivalent: "n")
        fromClipboard.keyEquivalentModifierMask = [.command, .shift]
        fromClipboard.target = self
        fromClipboard.isEnabled = clipboardHasImage
        menu.addItem(fromClipboard)

        menu.addItem(.separator())

        let importItem = NSMenuItem(title: "Import to Library…",
                                    action: #selector(plusImport), keyEquivalent: "o")
        importItem.keyEquivalentModifierMask = [.command]
        importItem.target = self
        menu.addItem(importItem)

        menu.addItem(.separator())
        // Edits the current canvas (unlike New/Import) — hence the separator
        // and the canvas-presence gate.
        let insertImage = NSMenuItem(title: "Insert Image on Canvas…",
                                     action: #selector(plusInsertImage), keyEquivalent: "")
        insertImage.target = self
        insertImage.isEnabled = canvasAvailable
        menu.addItem(insertImage)

        return menu
    }

    private func showPlusMenu(from pill: ActiveToolPillView) {
        let menu = makePlusMenu()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: pill.bounds.height + 4), in: pill)
    }

    @objc private func plusNewCanvas() { onNewCanvas?() }
    @objc private func plusNewFromClipboard() { onNewFromClipboard?() }
    @objc private func plusImport() { onImportToLibrary?() }
    @objc private func plusInsertImage() { onInsertImage?() }

    private func makeCutoutPill() -> ActiveToolPillView {
        let pill = ActiveToolPillView(
            symbolName: "person.and.background.dotted",
            accessibilityLabel: "Remove Background",
            symbolPointSize: 16
        ) { [weak self] in
            self?.onRemoveBackgroundTapped?()
        }
        pill.tooltipText = "Remove background"
        cutoutPill = pill
        return pill
    }

    private func makeEnhancePill() -> ActiveToolPillView {
        let pill = ActiveToolPillView(
            symbolName: "wand.and.stars",
            accessibilityLabel: "Enhance",
            symbolPointSize: 16
        ) { [weak self] in
            self?.onEnhanceTapped?()
        }
        pill.tooltipText = "Enhance clarity for low resolution"
        pill.isActive = enhanceActive
        enhancePill = pill
        return pill
    }

    private func makeSmartRedactPill() -> ActiveToolPillView {
        let pill = ActiveToolPillView(
            symbolName: "shield.lefthalf.filled",
            accessibilityLabel: "Smart Redact",
            symbolPointSize: 16
        ) { [weak self] in
            // Smart Redact is an action, not a tool mode — leave the user's
            // current tool selection untouched.
            self?.onSmartRedact?()
        }
        pill.tooltipText = "Smart Redact — find & hide sensitive info"
        pill.isActive = smartRedactActive
        smartRedactPill = pill
        return pill
    }

    // MARK: – Extract Structured Data pill

    private func makeExtractStructuredPill() -> ActiveToolPillView {
        let pill = ActiveToolPillView(
            symbolName: "chart.bar.doc.horizontal",
            accessibilityLabel: "Extract Structured Data",
            symbolPointSize: 16
        ) { [weak self] in
            self?.onExtractStructuredData?()
        }
        pill.tooltipText = "Extract Data"
        extractStructuredPill = pill
        return pill
    }

    private func makeUndoPill() -> ActiveToolPillView {
        let pill = ActiveToolPillView(
            symbolName: "arrow.uturn.backward",
            accessibilityLabel: "Undo",
            symbolPointSize: 16
        ) { [weak self] in
            self?.onUndo?()
        }
        pill.isEnabled = undoEnabled
        undoPill = pill
        return pill
    }

    private func makeRedoPill() -> ActiveToolPillView {
        let pill = ActiveToolPillView(
            symbolName: "arrow.uturn.forward",
            accessibilityLabel: "Redo",
            symbolPointSize: 16
        ) { [weak self] in
            self?.onRedo?()
        }
        pill.isEnabled = redoEnabled
        redoPill = pill
        return pill
    }

    private func makeCapturePill() -> ActiveToolPillView {
        ActiveToolPillView(
            symbolName: "camera.viewfinder",
            accessibilityLabel: "Capture",
            symbolPointSize: 16
        ) { [weak self] in
            self?.onCapture?()
        }
    }

    private func makeCaptureRegionPill() -> ActiveToolPillView {
        let pill = ActiveToolPillView(
            symbolName: "rectangle.dashed",
            accessibilityLabel: "Capture region",
            symbolPointSize: 16
        ) { [weak self] in
            self?.onCapture?()
        }
        pill.tooltipTextProvider = { Self.shortcutTooltip("Capture region", .captureRegion) }
        return pill
    }

    private func makeCaptureWindowPill() -> ActiveToolPillView {
        let pill = ActiveToolPillView(
            symbolName: "macwindow",
            accessibilityLabel: "Capture window",
            symbolPointSize: 16
        ) { [weak self] in
            self?.onCaptureWindow?()
        }
        pill.tooltipTextProvider = { Self.shortcutTooltip("Capture window", .captureWindow) }
        return pill
    }

    private func makeCaptureUnifiedPill(folded: Bool = false) -> ActiveToolPillView {
        guard folded else {
            let pill = ActiveToolPillView(
                symbolName: "camera.viewfinder",
                accessibilityLabel: "Capture",
                symbolPointSize: 22
            ) { [weak self] in
                self?.onCaptureUnified?()
            }
            pill.tooltipTextProvider = { Self.shortcutTooltip("Capture", .captureUnified) }
            return pill
        }
        // Folded: the click still fires Smart Capture, and the four specific
        // modes move onto the chevron menu.
        let pill = GroupedToolPillView(
            symbolName: "camera.viewfinder",
            accessibilityLabel: "Capture",
            symbolPointSize: 22
        ) {}
        pill.tooltipTextProvider = { Self.shortcutTooltip("Capture", .captureUnified) }
        pill.onActivateCurrent = { [weak self] in self?.onCaptureUnified?() }
        pill.onOpenMenu = { [weak self, weak pill] in
            guard let self, let pill else { return }
            let menu = NSMenu()
            menu.autoenablesItems = false
            self.addItem(to: menu, "Full Screen", #selector(self.foldedCaptureFullscreen))
            self.addItem(to: menu, "Delayed Capture", #selector(self.foldedCaptureDelayed))
            self.addItem(to: menu, "Scrolling Capture", #selector(self.foldedCaptureScroll))
            self.addItem(to: menu, "Live Capture", #selector(self.foldedCaptureLive))
            self.popUp(menu, from: pill)
        }
        return pill
    }

    // MARK: - Narrow-width folded pills
    //
    // Each stands in for a run of pills the bar no longer has room for. The
    // rule throughout: whatever was the primary action stays on the click, and
    // the rest of the run moves into a menu — so folding never relocates
    // something the user's hand already knows.

    /// Record Full Screen + Record Selection behind one pill: click records the
    /// full screen, chevron offers both.
    private func makeRecordFoldedPill() -> GroupedToolPillView {
        let pill = GroupedToolPillView(
            symbolName: "record.circle",
            accessibilityLabel: "Record",
            symbolPointSize: 18
        ) {}
        pill.tooltipText = "Record"
        pill.onActivateCurrent = { [weak self] in self?.onRecordScreen?() }
        pill.onOpenMenu = { [weak self, weak pill] in
            guard let self, let pill else { return }
            let menu = NSMenu()
            menu.autoenablesItems = false
            self.addItem(to: menu, "Record Full Screen", #selector(self.foldedRecordScreen))
            self.addItem(to: menu, "Record Selected Area", #selector(self.foldedRecordSelection))
            self.popUp(menu, from: pill)
        }
        return pill
    }

    /// Smart Redact / Extract / Enhance / Remove Background behind one pill.
    /// These are four unrelated one-shot actions with no natural primary, so
    /// the click opens the menu rather than picking a winner.
    private func makeAIFoldedPill() -> ActiveToolPillView {
        var pillRef: ActiveToolPillView?
        let pill = ActiveToolPillView(
            symbolName: "wand.and.stars",
            accessibilityLabel: "AI tools",
            symbolPointSize: 16
        ) { [weak self] in
            guard let self, let pill = pillRef else { return }
            let menu = NSMenu()
            menu.autoenablesItems = false
            self.addItem(to: menu, "Smart Redact", #selector(self.foldedSmartRedact))
            self.addItem(to: menu, "Extract Structured Data", #selector(self.foldedExtract))
            self.addItem(to: menu, "Enhance Clarity", #selector(self.foldedEnhance))
            self.addItem(to: menu, "Remove Background", #selector(self.foldedCutout))
            self.popUp(menu, from: pill)
        }
        pill.tooltipText = "AI tools"
        pillRef = pill
        aiFoldedPill = pill
        return pill
    }

    /// Find in Image, Info and Copy All behind one ⋯ pill. Export keeps its own
    /// pill: it is the one action that gets work OUT of the app.
    private func makeTrailingFoldedPill() -> ActiveToolPillView {
        var pillRef: ActiveToolPillView?
        let pill = ActiveToolPillView(
            symbolName: "ellipsis.circle",
            accessibilityLabel: "More",
            symbolPointSize: 16
        ) { [weak self] in
            guard let self, let pill = pillRef else { return }
            let menu = NSMenu()
            menu.autoenablesItems = false
            self.addItem(to: menu, "Find in Image", #selector(self.foldedFindInImage))
            self.addItem(to: menu, "Info", #selector(self.foldedToggleInfo))
            self.addItem(to: menu, "Copy All", #selector(self.foldedCopyAll))
            self.popUp(menu, from: pill)
        }
        pill.tooltipText = "More"
        pillRef = pill
        trailingFoldedPill = pill
        return pill
    }

    private func addItem(to menu: NSMenu, _ title: String, _ action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    private func popUp(_ menu: NSMenu, from pill: NSView) {
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: pill.bounds.height + 4), in: pill)
    }

    @objc private func foldedRecordScreen() { onRecordScreen?() }
    @objc private func foldedRecordSelection() { onRecordSelection?() }
    @objc private func foldedSmartRedact() { onSmartRedact?() }
    @objc private func foldedExtract() { onExtractStructuredData?() }
    @objc private func foldedEnhance() { onEnhanceTapped?() }
    @objc private func foldedCutout() { onRemoveBackgroundTapped?() }
    @objc private func foldedFindInImage() { onFindInImage?() }
    @objc private func foldedToggleInfo() { onToggleInfo?() }
    @objc private func foldedCopyAll() { onCopyAll?() }
    @objc private func foldedCaptureFullscreen() { onCaptureFullscreen?() }
    @objc private func foldedCaptureDelayed() { onCaptureDelayed?() }
    @objc private func foldedCaptureScroll() { onCaptureScroll?() }
    @objc private func foldedCaptureLive() { onCaptureLive?() }

    /// Delayed capture: a timer pill whose body starts a countdown-then-capture
    /// and whose chevron opens a 3/5/10/15s chooser. The chosen delay persists
    /// (`CaptureDelayPreference`).
    private func makeDelayedCapturePill() -> DelayedCapturePill {
        let pill = DelayedCapturePill(
            symbolName: "timer",
            accessibilityLabel: "Delayed capture",
            symbolPointSize: 18,
            onClick: {}
        )
        delayedPill = pill
        // Tooltip reads BOTH the live delay preference and the live shortcut on
        // each hover, so it stays current after either changes.
        pill.tooltipTextProvider = {
            Self.shortcutTooltip("Delayed capture — \(CaptureDelayPreference.current())s", .captureDelayed)
        }
        pill.onActivateCurrent = { [weak self] in self?.onCaptureDelayed?() }
        pill.onOpenMenu = { [weak self, weak pill] in
            guard let self, let pill else { return }
            self.showDelayMenu(from: pill)
        }
        return pill
    }

    /// Scrolling capture: select a viewport, scroll it yourself, get one tall
    /// stitched image.
    private func makeScrollCapturePill() -> ActiveToolPillView {
        let pill = ActiveToolPillView(
            symbolName: "rectangle.expand.vertical",
            accessibilityLabel: "Scrolling capture",
            symbolPointSize: 16
        ) { [weak self] in
            self?.onCaptureScroll?()
        }
        pill.tooltipTextProvider = { Self.shortcutTooltip("Scrolling capture", .captureScroll) }
        return pill
    }

    /// Live capture: grabs the current window layout as movable layers on one
    /// canvas.
    private func makeLiveCapturePill() -> ActiveToolPillView {
        let pill = ActiveToolPillView(
            symbolName: "square.stack.3d.up",
            accessibilityLabel: "Live capture",
            symbolPointSize: 16
        ) { [weak self] in
            self?.onCaptureLive?()
        }
        pill.tooltipTextProvider = { Self.shortcutTooltip("Live capture", .captureLive) }
        return pill
    }

    private func makeFullscreenCapturePill() -> ActiveToolPillView {
        let multi = NSScreen.screens.count > 1
        let pill = ActiveToolPillView(
            symbolName: "display",
            accessibilityLabel: "Full screen capture",
            symbolPointSize: 16
        ) { [weak self] in
            self?.onCaptureFullscreen?()
        }
        // On multi-monitor the click opens the monitor chooser (handled by the
        // capture coordinator); the tooltip hints it.
        pill.tooltipTextProvider = {
            Self.shortcutTooltip("Full screen capture", .captureFullscreen)
                + (multi ? " — choose a monitor" : "")
        }
        return pill
    }

    private func makeRecordScreenPill() -> ActiveToolPillView {
        let multi = NSScreen.screens.count > 1
        let pill = ActiveToolPillView(
            symbolName: "record.circle",
            accessibilityLabel: "Record full screen",
            symbolPointSize: 16
        ) { [weak self] in
            self?.onRecordScreen?()
        }
        pill.tooltipText = multi ? "Record full screen — choose a monitor" : "Record full screen"
        return pill
    }

    private func makeRecordSelectionPill() -> ActiveToolPillView {
        let pill = ActiveToolPillView(
            symbolName: "rectangle.dashed.badge.record",
            accessibilityLabel: "Record selected area",
            symbolPointSize: 16
        ) { [weak self] in
            self?.onRecordSelection?()
        }
        pill.tooltipText = "Record selected area"
        return pill
    }

    /// "Label (⌘⇧C)" built from the LIVE KeyboardShortcuts store so tooltips
    /// reflect the user's current customization; just "Label" when unassigned.
    private static func shortcutTooltip(_ label: String, _ name: KeyboardShortcuts.Name) -> String {
        guard let s = KeyboardShortcuts.getShortcut(for: name)?.description, !s.isEmpty else { return label }
        return "\(label) (\(s))"
    }

    private func showDelayMenu(from pill: DelayedCapturePill) {
        let current = CaptureDelayPreference.current()
        let menu = NSMenu()
        for seconds in CaptureDelayPreference.durations {
            let item = NSMenuItem(title: "\(seconds) seconds", action: #selector(selectDelay(_:)), keyEquivalent: "")
            item.target = self
            item.tag = seconds
            item.state = (seconds == current) ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: pill.bounds.height + 4), in: pill)
    }

    @objc private func selectDelay(_ sender: NSMenuItem) {
        CaptureDelayPreference.set(sender.tag)
    }

    private func makeToolPills(
        folded: Set<EditorToolbarFit.ClusterID> = []
    ) -> [ActiveToolPillView] {
        var pills: [ActiveToolPillView] = []
        activeToolLayout = Self.makeToolLayout(folded: folded)
        groupPills.removeAll()
        for (idx, slot) in activeToolLayout.enumerated() {
            switch slot {
            case let .single(_, symbol, label):
                let pill = ActiveToolPillView(
                    symbolName: symbol,
                    accessibilityLabel: label
                ) { [weak self] in
                    self?.handlePillClick(slotIndex: idx)
                }
                pills.append(pill)
            case let .group(group):
                // Restore the last-used sub-tool so the grouped pill fronts it.
                let current = ToolGroupPreference.last(group)
                groupCurrent[group.id] = current
                let member = group.member(current) ?? group.members[0]
                let pill = GroupedToolPillView(
                    symbolName: member.symbol,
                    accessibilityLabel: member.label
                ) {}
                pill.onActivateCurrent = { [weak self] in self?.activateGroupCurrent(group) }
                pill.onOpenMenu = { [weak self] in self?.openGroupMenu(group) }
                groupPills[group.id] = pill
                pills.append(pill)
            }
        }
        // Initial pill state: first tool (Select, the neutral default) active.
        pills[0].isActive = true
        toolPills = pills
        return pills
    }

    private func handlePillClick(slotIndex idx: Int) {
        guard idx < activeToolLayout.count,
              case let .single(tool, _, _) = activeToolLayout[idx] else { return }
        deactivateSmartRedact()
        onSelectTool?(tool)
        setSelectedTool(tool)
        os_log("editor toolbar pill → %{public}@", log: log, type: .info, String(describing: tool))
    }

    // MARK: - Tool groups

    /// Plain click on a grouped pill: re-arm its last-used sub-tool.
    private func activateGroupCurrent(_ group: ToolGroup) {
        let current = groupCurrent[group.id] ?? group.defaultTool
        deactivateSmartRedact()
        onSelectTool?(current)
        setSelectedTool(current)
        os_log("editor toolbar group %{public}@ → %{public}@",
               log: log, type: .info, group.id, String(describing: current))
    }

    /// Chevron tap / long-press: show the group's sub-tool chooser.
    private func openGroupMenu(_ group: ToolGroup) {
        guard let pill = groupPills[group.id] else { return }
        toolPopover?.close()
        let current = groupCurrent[group.id] ?? group.defaultTool
        let items = group.members.map {
            ToolGroupPopoverController.Item(tool: $0.tool, symbol: $0.symbol, label: $0.label)
        }
        let controller = ToolGroupPopoverController(
            items: items, current: current
        ) { [weak self] picked in
            self?.toolPopover?.close()
            self?.selectGroupSubTool(picked, in: group)
        }
        let pop = NSPopover()
        pop.behavior = .transient
        pop.contentViewController = controller
        pop.show(relativeTo: pill.bounds, of: pill, preferredEdge: .maxY)
        toolPopover = pop
    }

    /// Chooser pick: remember it, arm it, and reflect it on the pill.
    private func selectGroupSubTool(_ tool: EditorTool, in group: ToolGroup) {
        guard group.contains(tool) else { return }
        ToolGroupPreference.store(tool, in: group)
        deactivateSmartRedact()
        onSelectTool?(tool)
        setSelectedTool(tool)   // updates groupCurrent + pill visuals
    }

    /// Update a grouped pill's icon/label/tooltip to front `tool`.
    private func showGroupSubTool(_ tool: EditorTool, in group: ToolGroup) {
        groupCurrent[group.id] = tool
        guard let member = group.member(tool), let pill = groupPills[group.id] else { return }
        pill.setBaseSymbol(member.symbol)
        pill.tooltipText = member.label
        pill.setAccessibilityLabel(member.label)
    }

    private func makeCopyPill() -> ActiveToolPillView {
        let pill = ActiveToolPillView(
            symbolName: "doc.on.doc",
            accessibilityLabel: "Copy All",
            symbolPointSize: 16
        ) { [weak self] in
            self?.onCopyAll?()
        }
        copyPill = pill
        return pill
    }

    private func makeExportPill() -> ActiveToolPillView {
        let pill = ActiveToolPillView(
            symbolName: "square.and.arrow.up",
            accessibilityLabel: "Export",
            symbolPointSize: 16
        ) { [weak self] in
            self?.onExportPNG?()
        }
        exportPill = pill
        return pill
    }

    // MARK: - Tool layout

    /// One slot in the drawing-tools row. Single tools map to one pill; a
    /// `group` slot collapses related tools behind one `GroupedToolPillView`.
    enum ToolSlot {
        case single(EditorTool, symbol: String, label: String)
        case group(ToolGroup)
    }

    /// Rectangle + Ellipse behind one grouped pill (default Rectangle).
    nonisolated static let shapeGroup = ToolGroup(
        id: "shape",
        members: [
            .init(tool: .rectangle, symbol: "rectangle", label: "Rectangle"),
            .init(tool: .ellipse, symbol: "circle", label: "Ellipse"),
        ],
        defaultTool: .rectangle
    )

    /// Straight Arrow + Free Arrow behind one grouped pill (default Arrow). The
    /// chevron opens the chooser; the last-used member is remembered.
    nonisolated static let arrowGroup = ToolGroup(
        id: "arrow",
        members: [
            .init(tool: .arrow, symbol: "arrow.up.right", label: "Line Arrow"),
            .init(tool: .penArrow, symbol: ToolGlyph.freeArrow, label: "Free Arrow"),
        ],
        defaultTool: .arrow
    )

    // MARK: Narrow-width groups
    //
    // At small window widths whole runs of the drawing row fold behind one
    // grouped pill each, reusing the Arrow/Shape idiom users already know: the
    // pill fronts the last-used member and its chevron opens the chooser. The
    // folded groups SUPERSET the wide-width ones — Draw swallows Arrow and
    // Shape — so a tool never appears in two visible groups at once.

    /// Select + Hand, folded first (`.navigate`).
    nonisolated static let navigateGroup = ToolGroup(
        id: "navigate",
        members: [
            .init(tool: .select, symbol: "cursorarrow", label: "Select"),
            .init(tool: .hand, symbol: "hand.raised", label: "Hand"),
        ],
        defaultTool: .select
    )

    /// Every mark-making vector tool behind one pill (`.draw`).
    nonisolated static let drawGroup = ToolGroup(
        id: "draw",
        members: [
            .init(tool: .pen, symbol: "pencil.tip", label: "Pen"),
            .init(tool: .line, symbol: "line.diagonal", label: "Line"),
            .init(tool: .arrow, symbol: "arrow.up.right", label: "Line Arrow"),
            .init(tool: .penArrow, symbol: ToolGlyph.freeArrow, label: "Free Arrow"),
            .init(tool: .rectangle, symbol: "rectangle", label: "Rectangle"),
            .init(tool: .ellipse, symbol: "circle", label: "Ellipse"),
        ],
        defaultTool: .pen
    )

    /// Text + Step, the labelling pair (`.mark`).
    nonisolated static let markGroup = ToolGroup(
        id: "mark",
        members: [
            .init(tool: .text, symbol: "textformat", label: "Text"),
            .init(tool: .badge, symbol: "1.circle", label: "Step"),
        ],
        defaultTool: .text
    )

    /// All grouped tool sets, for membership lookups.
    nonisolated static let groups: [ToolGroup] = [
        shapeGroup, arrowGroup, navigateGroup, drawGroup, markGroup,
    ]

    /// The drawing-tools row for a given fold state, left → right. Live Text
    /// trails (a gap is added in `makeToolbarView`) since it is a separate
    /// text-recognition mode. Pure data, so `nonisolated` — usable off the main
    /// actor (and in tests).
    nonisolated static func makeToolLayout(
        folded: Set<EditorToolbarFit.ClusterID> = []
    ) -> [ToolSlot] {
        var slots: [ToolSlot] = []
        if folded.contains(.navigate) {
            slots.append(.group(navigateGroup))
        } else {
            slots.append(.single(.select, symbol: "cursorarrow", label: "Select"))
            slots.append(.single(.hand, symbol: "hand.raised", label: "Hand"))
        }
        slots.append(.single(.crop, symbol: "crop", label: "Crop"))
        if folded.contains(.draw) {
            slots.append(.group(drawGroup))
        } else {
            slots.append(.single(.pen, symbol: "pencil.tip", label: "Pen"))
            slots.append(.single(.line, symbol: "line.diagonal", label: "Line"))
            slots.append(.group(arrowGroup))
            slots.append(.group(shapeGroup))
        }
        if folded.contains(.mark) {
            slots.append(.group(markGroup))
        } else {
            slots.append(.single(.text, symbol: "textformat", label: "Text"))
            slots.append(.single(.badge, symbol: "1.circle", label: "Step"))
        }
        slots.append(.single(.blur, symbol: "drop.fill", label: "Blur"))
        slots.append(.single(.textSelect, symbol: "text.viewfinder", label: "Live Text"))
        return slots
    }

    /// The wide-open row — the layout with nothing folded.
    nonisolated static let toolLayout: [ToolSlot] = makeToolLayout(folded: [])

    /// The group `tool` belongs to in the CURRENT (possibly folded) row. A
    /// static lookup would return Arrow while Draw is the pill actually on
    /// screen, so selection would highlight a pill that isn't there.
    func group(containing tool: EditorTool) -> ToolGroup? {
        activeToolLayout.compactMap { slot -> ToolGroup? in
            if case let .group(g) = slot, g.contains(tool) { return g }
            return nil
        }.first
    }

    /// The group `tool` belongs to at full width, or nil if it isn't grouped.
    nonisolated static func group(containing tool: EditorTool) -> ToolGroup? {
        [shapeGroup, arrowGroup].first { $0.contains(tool) }
    }

    /// The pill index that hosts `tool` in the CURRENT row, or nil when it
    /// isn't on the bar. Each member of a group resolves to that group's slot.
    func slotIndex(for tool: EditorTool) -> Int? {
        activeToolLayout.firstIndex { slot in
            switch slot {
            case let .single(t, _, _): return t == tool
            case let .group(g): return g.contains(tool)
            }
        }
    }

    /// The pill index that hosts `tool` at full width, or nil if it isn't on
    /// the bar. Each member of a group resolves to that group's single slot.
    nonisolated static func slotIndex(for tool: EditorTool) -> Int? {
        toolLayout.firstIndex { slot in
            switch slot {
            case let .single(t, _, _): return t == tool
            case let .group(g): return g.contains(tool)
            }
        }
    }
}

/// Transparent event-eater laid over the toolbar while a blocking AI action
/// runs — swallows all mouse interaction without touching the pills beneath.
private final class ToolbarInteractionBlocker: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }
    override func mouseDown(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
}
