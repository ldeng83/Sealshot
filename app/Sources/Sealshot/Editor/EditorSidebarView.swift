import AppKit
import Observation

/// Which panel the sidebar should show.
enum SidebarPanel: Equatable {
    case tool(EditorTool)   // creation defaults for the active tool
    case object             // properties of the single selected annotation
    case multiObject        // summary + Delete for a multi-selection
    case objectList         // Select-tool layers list (all objects, expandable)
    case redactionReview    // smart-redaction proposals awaiting Apply/Cancel
}

/// Pure routing.
///
/// - A smart-redaction review in progress wins over everything: the user is
///   deciding what gets hidden before anything else matters.
/// - A single selection always shows the direct Object panel (either tool).
/// - The **Select** tool, when objects exist and the selection isn't a single
///   object (0 or 2+), shows the expandable objects list (layers panel).
/// - The Info tool keeps its multi-object summary for 2+ selected.
/// - Otherwise the per-tool defaults panel.
func sidebarPanel(tool: EditorTool, selectionCount: Int, annotationCount: Int,
                  reviewingRedactions: Bool = false) -> SidebarPanel {
    if reviewingRedactions { return .redactionReview }
    if selectionCount == 1 { return .object }
    if tool == .select && annotationCount > 0 { return .objectList }
    if selectionCount > 1 { return .multiObject }
    return .tool(tool)
}

/// Order annotations for the layers list: front-most first. `annotations` is
/// stored back-to-front (last drawn is on top), so the list is its reverse.
func objectListOrder(_ annotations: [Annotation]) -> [Annotation] {
    annotations.reversed()
}

/// Pure mapping from an annotation to its display title in the objects list and
/// the single-object panel header.
enum ObjectRowDescriptor {
    static func title(for annotation: Annotation) -> String {
        switch annotation.geometry {
        case .arrow: return "Line Arrow"
        case .rectangle: return "Rectangle"
        case .text: return "Text"
        case .ellipse: return "Ellipse"
        case .line: return "Line"
        case .badge: return "Step"
        case .pen: return "Pen"
        case .penArrow: return "Free Arrow"
        case .blur: return "Blur"
        case .image: return "Image"   // image overlays: UI label in their own task (plan Task 5)
        case .cut: return "Cut"
        }
    }
}

/// Right column of the editor — header label ("Tool Properties") above
/// a per-tool content host. The host's child view is swapped whenever
/// `state.selectedTool` changes; the content factories live in
/// `EditorToolPropertiesViews.swift`.
@MainActor
final class EditorSidebarView: NSView {

    static let width: CGFloat = 240

    private var state: EditorState
    private let titleLabel = NSTextField(labelWithString: "Tool Properties")
    private let host = NSView()
    private var rebuildWorkItem: DispatchWorkItem?
    /// Test hook: how many full panel rebuilds have run.
    private(set) var debugRebuildCount = 0

    /// Identity of what the panel is showing, so a rebuild that keeps the SAME
    /// content (e.g. editing a property of the selected object) can restore the
    /// scroll position instead of jumping to the top. Selection / mode / tool
    /// changes give a different signature → a fresh top.
    private var lastContentSignature: String?
    /// Scroll offset (y) to reapply once the rebuilt scrolling content is laid
    /// out; nil when the content changed and the panel should reset to the top.
    private var pendingScrollRestore: CGFloat?

    private var currentContentSignature: String {
        let ids = state.selectedAnnotationIDs.map(\.uuidString).sorted().joined(separator: ",")
        let review: String = { if case .found = state.redactionScan { return "review" }; return "" }()
        return [String(describing: state.sidebarPanelMode),
                String(describing: state.selectedTool),
                "vid:\(videoMode)", "enh:\(state.enhanceEditing)",
                "txt:\(state.activeTextEditing != nil)", review, "sel:\(ids)"].joined(separator: "|")
    }

    /// Test hook: the scroll view currently wrapping the panel content in the
    /// host, if any (the Info panel wraps its content so tall content scrolls).
    var debugHostScrollView: NSScrollView? {
        host.subviews.compactMap { $0 as? NSScrollView }.first
    }
    var onCommitCrop: (() -> Void)?
    var onCopyCrop: (() -> Void)?
    /// Rename the open capture from the Info panel's Name field (routed to
    /// the window controller's safe rename path).
    var onRenameRequested: ((String) -> Void)?
    var onCutCrop: (() -> Void)?
    var onSoftCrop: (() -> Void)?
    var onCopySelectedText: (() -> Void)?
    var onCopyAllText: (() -> Void)?
    var onEnhanceApply: (() -> Void)?
    var onEnhanceCancel: (() -> Void)?
    /// The Live Text copy buttons, captured when the textSelect panel is built,
    /// so a copy (button or ⌘C) can confirm on the right one.
    private weak var liveTextCopySelectedButton: ClosureButton?
    private weak var liveTextCopyAllButton: ClosureButton?
    private weak var imageTextSearchPanel: ImageTextSearchPanel?
    private var focusImageTextSearchOnNextBuild = false

    /// Flash "✓ Copied" on the Live Text copy button matching the action.
    func flashLiveTextCopied(all: Bool) {
        (all ? liveTextCopyAllButton : liveTextCopySelectedButton)?.flashConfirmation()
    }
    /// Invoked by the "Save current frame" button shown while a video plays.
    var onCaptureFrame: (() -> Void)?
    var onMoveImageTextSearchResult: ((Int) -> Void)?
    var onExitImageTextSearch: (() -> Void)?
    /// While a video is in the canvas the panel replaces tool properties with a
    /// frame-grab control (the image-editing tools don't apply to video).
    private var videoMode = false

    init(state: EditorState) {
        self.state = state
        super.init(frame: .zero)
        wantsLayer = true
        // 1pt hairline border on the leading edge separating the sidebar
        // from the canvas backdrop. Implemented as a sub-layer so we only
        // get the leading edge (not all 4 sides).
        let borderLine = CALayer()
        borderLine.name = "sidebar-leading-border"
        layer?.addSublayer(borderLine)
        applySurfaceColors()
        setupLayout()
        rebuildContent()
        startObserving()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not implemented") }

    override func layout() {
        super.layout()
        if let sublayers = layer?.sublayers {
            for sub in sublayers where sub.name == "sidebar-leading-border" {
                sub.frame = CGRect(x: 0, y: 0, width: 1, height: bounds.height)
            }
        }
    }

    // Re-resolve the static cgColors (surface + border) when the theme changes
    // (Settings Light/Dark switch) — see LabeledField for the rationale.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applySurfaceColors()
    }

    // The window's effective appearance (incl. the app's theme override) is only
    // reliable once we're in the window. Repaint then, so a layer first painted
    // against the wrong ambient appearance can't stay stale (no appearance CHANGE
    // fires in that case, so viewDidChangeEffectiveAppearance alone misses it).
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applySurfaceColors()
    }

    /// Paint the surface + leading border with colours resolved against THIS
    /// view's effective appearance. A bare `Theme.surfaceColor.cgColor` resolves
    /// against the AMBIENT `NSAppearance.current` (often the system appearance),
    /// so when the app's theme override differs the layer is painted for the
    /// wrong appearance — e.g. a near-black sidebar under a light theme.
    private func applySurfaceColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Theme.surfaceColor.cgColor
            for sub in layer?.sublayers ?? [] where sub.name == "sidebar-leading-border" {
                sub.backgroundColor = Theme.surfaceBorderColor.cgColor
            }
        }
    }

    private func setupLayout() {
        titleLabel.font = Theme.panelTitleFont
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)
        addSubview(host)
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            host.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 16),
            host.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            host.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            host.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
        ])
    }

    private func startObserving() {
        withObservationTracking {
            _ = state.selectedTool
            _ = state.selectedAnnotationIDs
            _ = state.primarySelectionID
            _ = state.annotations.count
            _ = state.expandedObjectIDs
            _ = state.activeTextEditing != nil
            _ = state.activeTextEditing?.epoch
            _ = state.sidebarRefreshToken
            // Scan PHASE changes only (idle/scanning/found/empty) — kept-flag
            // toggles must NOT rebuild the review panel (flashes the list,
            // drops hover); its rows update in place.
            _ = state.redactionReviewGeneration
            // Blur tool-default panel adapts to these: shape toggles the brush-
            // width control, mode relabels Strength↔Opacity.
            _ = state.blurRegionShape
            _ = state.blurMode
            // Clearing this on mouseUp re-fires the observation, running the
            // rebuild deferred during the drag.
            _ = state.interactionInProgress
            // Mode switch (Properties / Info / Find) triggers a full rebuild.
            _ = state.sidebarPanelMode
            // Live Text result: rebuild the panel to disable copy + show the
            // "no text" hint when recognition finds nothing. Find in Image
            // updates its retained panel in place, so don't observe this there
            // and destroy the focused search field when OCR completes.
            if state.selectedTool == .textSelect,
               !state.sidebarPanelMode.isImageTextSearch { _ = state.liveTextHasText }
            // Enables/disables the Find panel's Focus Area scope choice.
            if state.sidebarPanelMode.isImageTextSearch { _ = state.focusRect }
            // Video playing in canvas: Info mode shows the video's info, not the image's.
            _ = state.playingVideoURL
            // Extraction progress: tags/summary being generated toggles the Info
            // panel between content and a progress bar.
            _ = state.isGeneratingTags
            _ = state.isGeneratingSummary
            // Enhance panel: rebuild when the panel is toggled open/closed,
            // when the draft params change (Apply enabled-state), or when the
            // enhanced image/visible-state changes (toggle row state + params guard).
            _ = state.enhanceEditing
            _ = state.enhanceDraft
            _ = state.showingEnhanced
            _ = state.enhancedImage != nil
            _ = state.enhanceRunning
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.startObserving()
                self.scheduleRebuild()
            }
        }
    }

    /// Coalesce rebuilds: `annotations` fires on every mouse event of a
    /// canvas drag, and tearing down + re-laying-out the whole panel per
    /// tick makes the drag lag. One trailing rebuild keeps the list current
    /// without the per-tick churn; 50ms is imperceptible on a plain click.
    private func scheduleRebuild() {
        rebuildWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Skip rebuilds while a slider drag is editing a style — the
            // live slider would be destroyed mid-drag. `endStyleEdit()`
            // bumps `sidebarRefreshToken` to force one rebuild afterward.
            // Same while a canvas drag is in flight: tearing down the panel
            // mid-drag hitches it; mouseUp re-fires the observation.
            if self.state.styleEditingInProgress { return }
            if self.state.interactionInProgress { return }
            // A color palette is open: rebuilding would tear down the chip that
            // anchors it and dismiss the popover. `rebuildAfterPaletteClose`
            // refreshes once the palette closes.
            if ColorChipButton.openPaletteCount > 0 { return }
            self.rebuildContent()
        }
        rebuildWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    /// Called by a `ColorChipButton` when its palette popover closes: rebuilds
    /// once now that palette-open suppression is lifted, so the panel reflects
    /// any edits made while the palette was open.
    func rebuildAfterPaletteClose() {
        scheduleRebuild()
    }

    /// Toggle the video frame-grab panel. Called by the controller when a
    /// recording starts/stops playing in the canvas.
    func setVideoMode(_ on: Bool) {
        guard videoMode != on else { return }
        videoMode = on
        rebuildContent()
    }

    /// Rebind to a new EditorState on image switch WITHOUT recreating the view
    /// (recreating caused a visible flash). Swaps the observed state, resets
    /// per-image cached flags to their fresh-init defaults, re-arms observation
    /// against the new state, and rebuilds content once.
    func rebind(state newState: EditorState) {
        guard newState !== state else { return }
        state = newState
        // Reset per-image cached flags to their fresh-init defaults so a
        // video→image or image→image switch doesn't keep a stale mode.
        videoMode = false
        startObserving()   // re-arm withObservationTracking against newState
        rebuildContent()   // immediate rebuild for the new image's content
    }

    /// Focus/select the Find field now, or after the mode-change rebuild creates
    /// it. Used by both the toolbar pill and ⌘F.
    func focusImageTextSearchField() {
        focusImageTextSearchOnNextBuild = true
        guard let panel = imageTextSearchPanel else { return }
        focusImageTextSearchOnNextBuild = false
        panel.focusQueryField()
    }

    /// Refresh only the result count/navigation controls. Rebuilding the full
    /// sidebar here would replace the active field editor on every keystroke.
    func updateImageTextSearch(status: ImageTextSearchStatus) {
        if let panel = imageTextSearchPanel {
            panel.update(status: status)
        } else if state.showsImageTextSearchPanel,
                  state.imageTextSearchScanStage.isReady {
            // The retained control panel does not exist while the waiting
            // message is visible. Build it exactly once when final OCR lands.
            rebuildContent()
        }
    }

    private func rebuildContent() {
        debugRebuildCount += 1
        // If the panel is showing the same thing (a property edit on the selected
        // object), remember the current scroll offset to restore after the
        // rebuild; otherwise let the new content start at the top.
        let signature = currentContentSignature
        if signature == lastContentSignature {
            pendingScrollRestore = debugHostScrollView?.contentView.bounds.origin.y
        } else {
            pendingScrollRestore = nil
        }
        lastContentSignature = signature

        host.subviews.forEach { $0.removeFromSuperview() }
        // Make every static label in the panel (titles, values, hints, object
        // properties, tags) selectable/copyable like a web page, on every exit
        // path of this rebuild.
        defer { Self.enableTextSelection(in: self) }

        var reviewing = false
        if case .found = state.redactionScan { reviewing = true }

        // Enhance panel takeover — highest priority; shown while the pill is
        // active, regardless of mode/tool/selection.
        if state.enhanceEditing {
            titleLabel.stringValue = "Enhance Clarity"
            let content = EditorToolPropertiesViews.makeEnhance(state: state, onApply: { [weak self] in
                self?.onEnhanceApply?()
            }, onCancel: { [weak self] in
                self?.onEnhanceCancel?()
            })
            installScrolling(content)
            return
        }

        // Find in Image owns the sidebar just like Info and the persistent AI
        // modes. Its OCR result updates happen in place (see above), preserving
        // field focus while the user types.
        if state.sidebarPanelMode.isImageTextSearch {
            titleLabel.stringValue = "Find in Image"
            guard state.imageTextSearchScanStage.isReady else {
                installScrolling(makeImageTextSearchWaitingView())
                return
            }
            let panel = ImageTextSearchPanel(
                query: state.imageTextSearchQuery,
                scope: state.imageTextSearchScope,
                focusAreaAvailable: state.focusRect != nil,
                status: state.imageTextSearchStatus)
            panel.onQueryChanged = { [weak self] query in
                self?.state.imageTextSearchQuery = query
            }
            panel.onScopeChanged = { [weak self] scope in
                self?.state.imageTextSearchScope = scope
            }
            panel.onMoveResult = { [weak self] delta in
                self?.onMoveImageTextSearchResult?(delta)
            }
            panel.onExit = { [weak self] in self?.onExitImageTextSearch?() }
            imageTextSearchPanel = panel
            installScrolling(panel)
            if focusImageTextSearchOnNextBuild {
                focusImageTextSearchOnNextBuild = false
                DispatchQueue.main.async { [weak panel] in panel?.focusQueryField() }
            }
            return
        }

        // Info is shown only when nothing supersedes it: a selection or a
        // redaction review takes the panel instead (handled by the routing
        // below), so "just show the object property" wins over Info.
        if state.sidebarPanelMode.showsInfo(
            selectionCount: state.selectedAnnotationIDs.count,
            reviewingRedactions: reviewing) {
            titleLabel.stringValue = "Info"
            let content = EditorToolPropertiesViews.makeInfo(
                state: state,
                onRename: { [weak self] name in self?.onRenameRequested?(name) })
            // The Info panel (Name, dimensions, dates, source app, size, tags)
            // can outgrow a short window, so it scrolls instead of overflowing
            // off the bottom; the scroll view fills the host down to the strip.
            installScrolling(content)
            return
        }

        if videoMode {
            titleLabel.stringValue = "Video"
            let content = makeVideoControls()
            content.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(content)
            NSLayoutConstraint.activate([
                content.topAnchor.constraint(equalTo: host.topAnchor),
                content.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            ])
            return
        }

        if let session = state.activeTextEditing {
            titleLabel.stringValue = "Text"
            let content = EditorToolPropertiesViews.makeTextEditing(session: session)
            installScrolling(content)   // the text style panel can outgrow the sidebar
            return
        }

        let panel = sidebarPanel(tool: state.selectedTool,
                                 selectionCount: state.selectedAnnotationIDs.count,
                                 annotationCount: state.annotations.count,
                                 reviewingRedactions: reviewing)
        let content: NSView
        switch panel {
        case .redactionReview:
            titleLabel.stringValue = "Smart Redaction"
            content = SmartRedactionReviewPanel(state: state)
        case .object:
            titleLabel.stringValue = objectTitle(for: state.selectedAnnotation)
            content = EditorToolPropertiesViews.makeObject(state: state)
        case .objectList:
            titleLabel.stringValue = "Objects"
            content = EditorToolPropertiesViews.makeObjectsList(state: state)
        case .multiObject:
            titleLabel.stringValue = "\(state.selectedAnnotationIDs.count) Objects"
            content = EditorToolPropertiesViews.makeMultiObject(state: state)
        case .tool(let tool):
            titleLabel.stringValue = tool.displayName
            content = EditorToolPropertiesViews.make(
                for: tool, state: state,
                onCommitCrop: { [weak self] in self?.onCommitCrop?() },
                onCopyCrop: { [weak self] in self?.onCopyCrop?() },
                onCutCrop: { [weak self] in self?.onCutCrop?() },
                onSoftCrop: { [weak self] in self?.onSoftCrop?() },
                onCopySelectedText: { [weak self] in self?.onCopySelectedText?() },
                onCopyAllText: { [weak self] in self?.onCopyAllText?() },
                onLiveTextButtons: { [weak self] selected, all in
                    self?.liveTextCopySelectedButton = selected
                    self?.liveTextCopyAllButton = all
                }
            )
        }
        content.translatesAutoresizingMaskIntoConstraints = false
        switch panel {
        case .redactionReview:
            // Its own list scrolls internally; fill the sidebar down to the strip.
            host.addSubview(content)
            NSLayoutConstraint.activate([
                content.topAnchor.constraint(equalTo: host.topAnchor),
                content.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                content.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            ])
        case .object, .tool:
            // The object/text style AND tool-default panels can outgrow the
            // sidebar → scroll them. Using the same scrolled container for both
            // (and the inline path) keeps their content width identical, so the
            // panel doesn't shift when rotating tool / selection / inline-edit.
            installScrolling(content)
        default:
            host.addSubview(content)
            NSLayoutConstraint.activate([
                content.topAnchor.constraint(equalTo: host.topAnchor),
                content.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            ])
        }
    }

    private func makeImageTextSearchWaitingView() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10

        let progress = NSProgressIndicator()
        progress.style = .spinning
        progress.controlSize = .small
        progress.isIndeterminate = true
        progress.usesThreadedAnimation = true
        progress.startAnimation(nil)
        stack.addArrangedSubview(progress)

        let message = NSTextField(wrappingLabelWithString: "Waiting for image scan...")
        message.font = Theme.valueFont
        message.textColor = .secondaryLabelColor
        stack.addArrangedSubview(message)
        message.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    /// Wrap `content` in a vertically-scrolling view that fills the host down
    /// to the bottom, so a panel taller than the sidebar gains a scrollbar
    /// instead of running off the bottom edge. The content keeps its natural
    /// height and wraps to the clip width (no horizontal scrolling).
    private func installScrolling(_ content: NSView) {
        content.translatesAutoresizingMaskIntoConstraints = false

        // A flipped document anchors content to the TOP of the clip view; a
        // non-flipped one sinks short content to the bottom, leaving a gap.
        let document = FlippedClipView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        // Force OVERLAY scrollers so the scroller floats instead of stealing
        // ~17px of clip width when it appears (legacy style). The content's -10
        // trailing inset already reserves room for the overlay bar, so the
        // content width stays constant whether or not the panel overflows —
        // keeping the three text-tool states (and every panel) identical in width.
        scroll.scrollerStyle = .overlay
        scroll.documentView = document
        host.addSubview(scroll)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: host.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: host.bottomAnchor),

            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            // Width tracks the clip view so content wraps instead of scrolling
            // sideways; height is driven by the content pinned inside it.
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),

            content.topAnchor.constraint(equalTo: document.topAnchor),
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            // Right inset so content clears the (overlay) scrollbar when it appears.
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -10),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])

        // Restore the pre-rebuild scroll offset once the new content has laid out
        // (same-content rebuilds only — see rebuildContent). Clamp to the new
        // scrollable range so a shorter panel doesn't over-scroll.
        if let y = pendingScrollRestore {
            pendingScrollRestore = nil
            scroll.layoutSubtreeIfNeeded()
            let maxY = max(0, document.frame.height - scroll.contentView.bounds.height)
            scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: min(y, maxY)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    /// Recursively mark static (non-editable) text labels as selectable so the
    /// panel's text can be highlighted and copied. Editable fields are already
    /// selectable, so they're left untouched.
    private static func enableTextSelection(in view: NSView) {
        for sub in view.subviews {
            if let field = sub as? NSTextField, !field.isEditable {
                field.isSelectable = true
            }
            enableTextSelection(in: sub)
        }
    }

    /// The video-mode panel: a "Save current frame" button that grabs the
    /// frame on screen and adds it to the library as a new image.
    private func makeVideoControls() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10

        let button = NSButton(title: " Save current frame",
                              image: NSImage(systemSymbolName: "camera.fill",
                                             accessibilityDescription: "Save current frame") ?? NSImage(),
                              target: self, action: #selector(captureFrameClicked))
        button.imagePosition = .imageLeading
        button.bezelStyle = .rounded
        stack.addArrangedSubview(button)

        let hint = NSTextField(wrappingLabelWithString:
            "Grabs the frame on screen and adds it to your library as a new image.")
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor
        stack.addArrangedSubview(hint)
        hint.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        return stack
    }

    @objc private func captureFrameClicked() { onCaptureFrame?() }

    private func objectTitle(for annotation: Annotation?) -> String {
        guard let annotation = annotation else { return "Object" }
        return ObjectRowDescriptor.title(for: annotation)
    }
}

private extension EditorTool {
    var displayName: String {
        switch self {
        case .select: return "Select"
        case .hand: return "Hand"
        case .textSelect: return "Live Text"
        case .crop: return "Crop"
        case .arrow: return "Line Arrow"
        case .rectangle: return "Rectangle"
        case .text: return "Text"
        case .ellipse: return "Ellipse"
        case .line: return "Line"
        case .badge: return "Step"
        case .pen: return "Pen"
        case .penArrow: return "Free Arrow"
        case .blur: return "Blur"
        }
    }
}

/// A flipped document view so scroll-view content anchors to the TOP of the
/// clip view. A non-flipped document sinks short content to the bottom of the
/// clip, leaving a gap above the first row.
private final class FlippedClipView: NSView {
    override var isFlipped: Bool { true }
}
