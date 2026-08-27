import AppKit
import Observation

/// Bottom bar above the recent strip. Left: Recent/Tag tabs. Center:
/// zoom -/+ and dimensions.
@MainActor
/// The editable zoom-percentage field.
///
/// ⌘+scroll zooms everywhere else in the editor (`EditorCanvasView.scrollWheel`),
/// but once this field takes focus it swallows scroll events and nothing
/// happens — the one place pointing at the zoom control itself. Forward the
/// gesture instead; a plain scroll still falls through to the enclosing view.
final class ZoomPercentField: NSTextField {
    /// One notch of the wheel = one zoom step, matching the ± buttons either
    /// side of this field rather than the canvas's continuous zoom: this is a
    /// discrete control showing a discrete number.
    var onZoomIn: () -> Void = {}
    var onZoomOut: () -> Void = {}

    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) else {
            super.scrollWheel(with: event)
            return
        }
        // Trackpads deliver many small deltas; ignore the noise around zero so
        // a gentle two-finger drift doesn't ratchet the zoom.
        let dy = event.scrollingDeltaY
        guard abs(dy) > 0.5 else { return }
        if dy > 0 { onZoomIn() } else { onZoomOut() }
    }
}

final class EditorMetaRowView: NSView, NSTextFieldDelegate {

    /// Fixed bar height. Taller than the control intrinsic size so the
    /// vertically-centered zoom controls get padding above and below.
    static let height: CGFloat = 46

    private let state: EditorState?
    private let isCompact: Bool
    let onFitWindow: () -> Void
    let onZoom100: () -> Void
    let onFitWidth: () -> Void
    let onFitHeight: () -> Void
    /// Zoom into the focus-cropped area (with a margin so anchors stay
    /// draggable). Falls back to fit-window when no focus crop is set.
    let onFocus: () -> Void
    /// Set the zoom to an explicit factor (1.0 == 100%). Driven by the
    /// zoom slider. Clamping happens downstream in the scroll view, and the
    /// applied value flows back via `state.zoom`.
    let onSetZoom: (CGFloat) -> Void
    let onZoomIn: () -> Void
    let onZoomOut: () -> Void
    let onTabChange: (BottomTab) -> Void
    /// Collapse/show the bottom recent strip. Wired only in full mode — the
    /// compact (empty editor) meta row has no canvas to reclaim space for.
    var onToggleStrip: () -> Void = {}
    /// Strip media filter (All / Images / Videos) changed. Set by the owner.
    var onSelectMediaFilter: (StripMediaFilter) -> Void = { _ in }

    private let tabs = NSSegmentedControl(labels: ["Recent", "Deleted"],
                                           trackingMode: .selectOne,
                                           target: nil, action: nil)
    private static let filterOrder: [StripMediaFilter] = [.all, .images, .videos]
    private lazy var mediaFilterControl: NSSegmentedControl = makeMediaFilterControl()
    private let zoomSlider = NSSlider()
    /// When non-nil, the zoom % / slider display is pinned to this value
    /// (video mode — the video's zoom, reported by the player view) instead
    /// of following `state.zoom` (the IMAGE zoom, hidden under the video).
    private var zoomDisplayOverride: CGFloat?
    private let percentLabel = ZoomPercentField(labelWithString: "100%")
    /// The dimensions readout IS the Resize trigger: a subtle bordered button
    /// showing "W × H" that opens the Resize popover (anchored above it).
    private lazy var dimensionsButton: NSButton = {
        let b = NSButton(title: "", target: self, action: #selector(dimensionsClicked))
        b.bezelStyle = .rounded
        b.controlSize = .regular
        // The chevron is folded INTO the attributed title (see updateDimensions)
        // as a text attachment — a separate `.image` sat low and couldn't be
        // lifted with the title. `imageOnly`-free: no separate button image.
        b.imagePosition = .noImage
        b.toolTip = "Resize image…"
        return b
    }()

    /// Vertical nudge (points) applied to the whole readout so the rounded
    /// bezel's low default baseline reads centered. Tune here if it looks off.
    private static let dimensionsBaselineLift: CGFloat = 1.5
    /// Anchor for the controller-owned Resize popover.
    var resizeAnchorButton: NSButton { dimensionsButton }
    /// Set by the controller; receives the anchor button on click.
    var onResizeButtonClicked: (NSButton) -> Void = { _ in }
    private let stripToggle = NSButton()
    /// The floating zoom cluster (see `anchorZoomCluster`).
    private var zoomCluster: NSStackView?
    /// Fit / Focus / Fit width / Fit height / Actual size. Shown as five
    /// buttons when there is room, and collapsed behind `zoomPresetsButton`
    /// when there isn't — see `applyZoomPresetFit`.
    private var zoomPresetButtons: [NSButton] = []
    private var zoomPresetsButton: NSButton?
    private var zoomPresetsCollapsed = false
    private var zoomSliderCollapsed = false
    private var clusterAnchorConstraint: NSLayoutConstraint?

    init(
        state: EditorState,
        onFitWindow: @escaping () -> Void,
        onZoom100: @escaping () -> Void,
        onFitWidth: @escaping () -> Void,
        onFitHeight: @escaping () -> Void,
        onFocus: @escaping () -> Void,
        onSetZoom: @escaping (CGFloat) -> Void,
        onZoomIn: @escaping () -> Void,
        onZoomOut: @escaping () -> Void,
        onTabChange: @escaping (BottomTab) -> Void
    ) {
        self.state = state
        self.isCompact = false
        self.onFitWindow = onFitWindow
        self.onZoom100 = onZoom100
        self.onFitWidth = onFitWidth
        self.onFitHeight = onFitHeight
        self.onFocus = onFocus
        self.onSetZoom = onSetZoom
        self.onZoomIn = onZoomIn
        self.onZoomOut = onZoomOut
        self.onTabChange = onTabChange
        super.init(frame: .zero)
        wantsLayer = true
        applySurfaceColors()
        setupLayout()
        refreshZoomDisplay()
        refreshDimensions()
        observeZoomAndCrop()
    }

    /// Compact mode: no W/H label, no zoom controls, only the Recent/Deleted
    /// tab toggle. Used by the empty editor window.
    init(
        initialTab: BottomTab,
        onTabChange: @escaping (BottomTab) -> Void
    ) {
        self.state = nil
        self.isCompact = true
        self.onFitWindow = {}
        self.onZoom100 = {}
        self.onFitWidth = {}
        self.onFitHeight = {}
        self.onFocus = {}
        self.onSetZoom = { _ in }
        self.onZoomIn = {}
        self.onZoomOut = {}
        self.onTabChange = onTabChange
        super.init(frame: .zero)
        wantsLayer = true
        applySurfaceColors()
        setupLayout(initialTab: initialTab)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not implemented") }

    // Re-resolve the static cgColor background when the theme changes
    // (Settings Light/Dark switch) — see LabeledField for the rationale.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applySurfaceColors()
    }

    // Repaint once in the window: a bare `…cgColor` at init resolves against the
    // ambient appearance, which may differ from the window's (app theme override)
    // with no appearance CHANGE to correct it.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applySurfaceColors()
        activateClusterAnchorIfReady()
    }

    /// Resolve the surface cgColor against THIS view's effective appearance
    /// (not the ambient `NSAppearance.current`).
    private func applySurfaceColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Theme.surfaceColor.cgColor
        }
    }

    private func setupLayout(initialTab: BottomTab? = nil) {
        let activeTab = initialTab ?? state?.bottomTab ?? .recent
        tabs.selectedSegment = activeTab == .recent ? 0 : 1
        tabs.target = self
        tabs.action = #selector(tabsChanged(_:))

        if isCompact {
            // No strip toggle here, so keep the filter beside the tabs, centered.
            let leftControls = NSStackView(views: [tabs, mediaFilterControl])
            leftControls.orientation = .horizontal
            leftControls.spacing = 10
            leftControls.alignment = .centerY
            leftControls.translatesAutoresizingMaskIntoConstraints = false
            addSubview(leftControls)
            NSLayoutConstraint.activate([
                leftControls.centerXAnchor.constraint(equalTo: centerXAnchor),
                leftControls.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
            return
        }

        // Full-mode layout. Zoom is a slider (10%–800%) with a read-only
        // percentage readout; Fit and Original remain as quick presets.
        // The track is logarithmic (equal travel per doubling) so 100% sits
        // near the middle and control is even across the whole range.
        zoomSlider.minValue = log(Self.minPercent)
        zoomSlider.maxValue = log(Self.maxPercent)
        zoomSlider.doubleValue = sliderPosition(forZoom: state?.zoom ?? 1.0)
        zoomSlider.isContinuous = true
        zoomSlider.controlSize = .small
        zoomSlider.target = self
        zoomSlider.action = #selector(sliderChanged)
        zoomSlider.toolTip = "Zoom"
        zoomSlider.widthAnchor.constraint(equalToConstant: 130).isActive = true

        percentLabel.alignment = .right
        percentLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        percentLabel.textColor = .labelColor
        // ⌘+scroll over the field steps the zoom, matching the ± buttons beside
        // it. Without this the field swallows the gesture once focused.
        percentLabel.onZoomIn = { [weak self] in self?.onZoomIn() }
        percentLabel.onZoomOut = { [weak self] in self?.onZoomOut() }
        // Editable: the user can type an exact zoom % (click, type, Return). The
        // value is parsed + clamped to [minPercent, maxPercent] on commit
        // (controlTextDidEndEditing, which fires on Return / Tab / focus-out).
        // Kept borderless to match the compact zoom cluster.
        percentLabel.isSelectable = true
        percentLabel.isEditable = true
        percentLabel.isBordered = false
        percentLabel.drawsBackground = false
        percentLabel.delegate = self
        percentLabel.toolTip = "Zoom % (\(Int(Self.minPercent))–\(Int(Self.maxPercent))) — type a value and press Return"
        percentLabel.widthAnchor.constraint(equalToConstant: 44).isActive = true

        // The five presets share a magnifier-lens icon family (drawn template
        // images): a magnifying glass whose inner mark tells each action apart.
        let fitBtn = NSButton(image: zoomLensImage(.fit, accessibility: "Fit"),
                              target: self, action: #selector(fitClicked))
        fitBtn.bezelStyle = .rounded
        fitBtn.toolTip = "Fit whole image in window"
        let focusBtn = NSButton(image: zoomLensImage(.focus, accessibility: "Focus"),
                                target: self, action: #selector(focusClicked))
        focusBtn.bezelStyle = .rounded
        focusBtn.toolTip = "Zoom into the focus crop"
        let fitWidthBtn = NSButton(image: zoomLensImage(.width, accessibility: "Fit width"),
                                   target: self, action: #selector(fitWidthClicked))
        fitWidthBtn.bezelStyle = .rounded
        fitWidthBtn.toolTip = "Fit width"
        let fitHeightBtn = NSButton(image: zoomLensImage(.height, accessibility: "Fit height"),
                                    target: self, action: #selector(fitHeightClicked))
        fitHeightBtn.bezelStyle = .rounded
        fitHeightBtn.toolTip = "Fit height"
        let originalBtn = NSButton(image: zoomLensImage(.one, accessibility: "Actual size"),
                                   target: self, action: #selector(originalClicked))
        originalBtn.bezelStyle = .rounded
        originalBtn.toolTip = "Actual size (100%)"

        let zoomOutBtn = NSButton(title: "−", target: self, action: #selector(zoomOutClicked))
        zoomOutBtn.bezelStyle = .texturedRounded
        zoomOutBtn.controlSize = .small
        zoomOutBtn.toolTip = "Zoom out"
        let zoomInBtn = NSButton(title: "+", target: self, action: #selector(zoomInClicked))
        zoomInBtn.bezelStyle = .texturedRounded
        zoomInBtn.controlSize = .small
        zoomInBtn.toolTip = "Zoom in"

        // One stand-in for all five presets, used when the row is too narrow
        // to show them. Every preset stays reachable — they exist nowhere else
        // in the app, so hiding them outright would remove the capability.
        let presetsBtn = NSButton(image: zoomLensImage(.fit, accessibility: "Zoom presets"),
                                  target: self, action: #selector(zoomPresetsClicked))
        presetsBtn.bezelStyle = .rounded
        presetsBtn.toolTip = "Zoom presets"
        presetsBtn.isHidden = true
        zoomPresetsButton = presetsBtn
        zoomPresetButtons = [fitBtn, focusBtn, fitWidthBtn, fitHeightBtn, originalBtn]

        let centerStack = NSStackView(views: [zoomOutBtn, zoomSlider, zoomInBtn, percentLabel,
                                              fitBtn, focusBtn, fitWidthBtn, fitHeightBtn,
                                              originalBtn, presetsBtn])
        centerStack.orientation = .horizontal
        centerStack.spacing = 6
        centerStack.translatesAutoresizingMaskIntoConstraints = false
        self.zoomCluster = centerStack

        configureStripToggle()

        tabs.translatesAutoresizingMaskIntoConstraints = false
        mediaFilterControl.translatesAutoresizingMaskIntoConstraints = false
        dimensionsButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tabs)
        addSubview(centerStack)
        addSubview(dimensionsButton)
        addSubview(mediaFilterControl)
        addSubview(stripToggle)
        // The zoom cluster floats: centered over the CANVAS COLUMN when an
        // anchor is installed (`anchorZoomCluster`), else over the row itself
        // — with REQUIRED spacing to its neighbors so it clamps instead of
        // colliding when the Info panel squeezes the canvas. The dimensions
        // (Resize) button sits with the right-side controls, visually
        // separated from the zoom cluster.
        let fallbackCenter = centerStack.centerXAnchor.constraint(equalTo: centerXAnchor)
        fallbackCenter.priority = NSLayoutConstraint.Priority(500)
        self.fallbackCenterConstraint = fallbackCenter
        // The zoom cluster's neighbour gaps are HIGH but not required. At
        // required they add the cluster's full width to the row's minimum,
        // which propagates to the window — the row would then be what stops
        // the editor shrinking (the tool bar's old sin), and worse, it would
        // set that minimum BEFORE `applyZoomPresetFit` gets a chance to fold
        // the cluster down. Breaking instead lets the row be squeezed for the
        // one layout pass it takes the fold to land. Still above the 500
        // centring priority, so the anti-collision behaviour is unchanged at
        // every width where the row genuinely fits.
        let leadingGap = centerStack.leadingAnchor.constraint(
            greaterThanOrEqualTo: tabs.trailingAnchor, constant: 16)
        let trailingGap = centerStack.trailingAnchor.constraint(
            lessThanOrEqualTo: dimensionsButton.leadingAnchor, constant: -16)
        leadingGap.priority = NSLayoutConstraint.Priority(750)
        trailingGap.priority = NSLayoutConstraint.Priority(750)
        NSLayoutConstraint.activate([
            tabs.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            tabs.centerYAnchor.constraint(equalTo: centerYAnchor),
            centerStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            fallbackCenter,
            leadingGap,
            trailingGap,
            dimensionsButton.trailingAnchor.constraint(
                equalTo: mediaFilterControl.leadingAnchor, constant: -10),
            dimensionsButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            mediaFilterControl.trailingAnchor.constraint(equalTo: stripToggle.leadingAnchor, constant: -10),
            mediaFilterControl.centerYAnchor.constraint(equalTo: centerYAnchor),
            stripToggle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stripToggle.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    /// PRECISE centring: keep the zoom cluster's centerX over `view`'s (the
    /// canvas column), following Info-panel resizes live. ONE-DIRECTIONAL by
    /// construction: a naive cross-view equality lets the solver satisfy it
    /// by dragging the CANVAS toward the cluster instead (its width is
    /// content-driven — observed as a white strip left of the canvas), so
    /// the cluster is pinned at a computed offset from THIS row's leading
    /// edge, recalculated on layout/frame changes; the canvas is only ever
    /// read, never constrained. The required neighbor gaps still clamp the
    /// cluster instead of letting it collide at extreme sidebar widths.
    /// Safe to call before either view is in a window — activation defers to
    /// `viewDidMoveToWindow`.
    func anchorZoomCluster(toCenterOf view: NSView) {
        pendingClusterAnchorView = view
        activateClusterAnchorIfReady()
    }

    private weak var pendingClusterAnchorView: NSView?
    private var fallbackCenterConstraint: NSLayoutConstraint?
    private var anchorFrameObserver: NSObjectProtocol?

    private func activateClusterAnchorIfReady() {
        guard let cluster = zoomCluster, let view = pendingClusterAnchorView,
              window != nil, view.window === window else { return }
        if clusterAnchorConstraint == nil {
            let c = cluster.centerXAnchor.constraint(equalTo: leadingAnchor, constant: bounds.midX)
            c.priority = NSLayoutConstraint.Priority(750)
            c.isActive = true
            clusterAnchorConstraint = c
        }
        fallbackCenterConstraint?.isActive = false
        view.postsFrameChangedNotifications = true
        if anchorFrameObserver == nil {
            anchorFrameObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: view, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateClusterAnchorOffset() }
            }
        }
        updateClusterAnchorOffset()
    }

    private func updateClusterAnchorOffset() {
        guard let view = pendingClusterAnchorView, let c = clusterAnchorConstraint,
              window != nil, view.window === window else { return }
        let centerX = convert(NSPoint(x: view.bounds.midX, y: 0), from: view).x
        // Threshold keeps the layout()-driven update from ping-ponging.
        if abs(c.constant - centerX) > 0.5 { c.constant = centerX }
    }

    override func layout() {
        super.layout()
        updateClusterAnchorOffset()
    }

    /// Row width below which the five zoom presets collapse into one menu
    /// button. The expanded row needs ~725pt; below that its required chain
    /// (tabs → zoom cluster → Resize → filter → strip toggle) is what stops
    /// the window shrinking, exactly as the tool bar used to.
    static let zoomPresetCollapseWidth: CGFloat = 730
    /// Narrower still, the zoom SLIDER goes too. Zoom stays fully usable
    /// without it: − and + step it, and the % readout is editable.
    static let zoomSliderCollapseWidth: CGFloat = 600
    /// Extra room needed to expand again, so a resize drag that sits on a
    /// threshold doesn't swap controls in and out every frame.
    static let zoomPresetHysteresis: CGFloat = 24

    /// Collapse or restore the zoom controls for the width the row is ABOUT
    /// to have.
    ///
    /// Driven by the window controller rather than this view's own `layout()`,
    /// and for the same reason the tool bar is: the row's required chain is
    /// part of what sets the window's minimum width, so a row that waits to
    /// see a narrow width never sees one — the window cannot get there until
    /// the row has already folded. The controller knows the width being
    /// negotiated before it is applied; this view does not.
    /// `allowRestore` is false for widths that are a CONSEQUENCE of the
    /// current fold rather than a request — restoring for those re-raises the
    /// window's minimum and walks it back open. See the matching rule in
    /// `EditorWindowController.applyToolbarFit`.
    func applyZoomFit(availableWidth: CGFloat, allowRestore: Bool = false) {
        guard let presets = zoomPresetsButton, !zoomPresetButtons.isEmpty else { return }
        let width = availableWidth
        guard width > 0 else { return }

        /// Collapsed below `threshold`, restored only once there is
        /// `zoomPresetHysteresis` more room than that.
        func collapsed(below threshold: CGFloat, currently: Bool) -> Bool {
            currently ? width < threshold + Self.zoomPresetHysteresis : width < threshold
        }

        let foldPresets = collapsed(below: Self.zoomPresetCollapseWidth,
                                    currently: zoomPresetsCollapsed)
            || (!allowRestore && zoomPresetsCollapsed)
        if foldPresets != zoomPresetsCollapsed {
            zoomPresetsCollapsed = foldPresets
            for button in zoomPresetButtons { button.isHidden = foldPresets }
            presets.isHidden = !foldPresets
        }

        let foldSlider = collapsed(below: Self.zoomSliderCollapseWidth,
                                   currently: zoomSliderCollapsed)
            || (!allowRestore && zoomSliderCollapsed)
        if foldSlider != zoomSliderCollapsed {
            zoomSliderCollapsed = foldSlider
            zoomSlider.isHidden = foldSlider
        }
    }

    /// The collapsed presets, as a menu — same five actions, same order.
    @objc private func zoomPresetsClicked() {
        guard let button = zoomPresetsButton else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (title, action) in [
            ("Fit in Window", #selector(fitClicked)),
            ("Zoom to Focus", #selector(focusClicked)),
            ("Fit Width", #selector(fitWidthClicked)),
            ("Fit Height", #selector(fitHeightClicked)),
            ("Actual Size (100%)", #selector(originalClicked)),
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    /// Test hooks: which zoom controls the current width has folded away.
    var zoomPresetsCollapsedForTesting: Bool { zoomPresetsCollapsed }
    var zoomSliderCollapsedForTesting: Bool { zoomSliderCollapsed }

    deinit {
        if let observer = anchorFrameObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    @objc private func dimensionsClicked() { onResizeButtonClicked(dimensionsButton) }

    /// Borderless chevron that collapses/shows the recent strip. Icon and
    /// tooltip are kept in sync with the strip state via `setStripHidden`.
    private func configureStripToggle() {
        stripToggle.bezelStyle = .rounded
        stripToggle.isBordered = false
        stripToggle.imagePosition = .imageOnly
        stripToggle.target = self
        stripToggle.action = #selector(stripToggleClicked)
        stripToggle.translatesAutoresizingMaskIntoConstraints = false
        setStripHidden(false)
    }

    /// Reflect the strip's collapsed state on the toggle: chevron points down
    /// when the strip is showing (click to hide) and up when it's hidden
    /// (click to show). Called by the controller on init and on every toggle.
    func setStripHidden(_ hidden: Bool) {
        let symbol = hidden ? "chevron.up" : "chevron.down"
        let label = hidden ? "Show" : "Hide"
        stripToggle.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: hidden ? "Show recent strip" : "Hide recent strip"
        )
        stripToggle.toolTip = label
    }

    @objc private func stripToggleClicked() { onToggleStrip() }

    private func spacer(width: CGFloat) -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: width).isActive = true
        return v
    }

    // MARK: Actions

    @objc private func fitClicked() { onFitWindow() }
    @objc private func focusClicked() { onFocus() }
    @objc private func fitWidthClicked() { onFitWidth() }
    @objc private func fitHeightClicked() { onFitHeight() }
    @objc private func originalClicked() { onZoom100() }
    @objc private func zoomInClicked() { onZoomIn() }
    @objc private func zoomOutClicked() { onZoomOut() }

    @objc private func sliderChanged() {
        onSetZoom(zoom(forSliderPosition: zoomSlider.doubleValue))
    }

    // MARK: Logarithmic zoom slider mapping

    /// Slider endpoints in percent, sourced from the scroll view's clamp.
    private static let minPercent = Double(EditorCanvasScrollView.minZoom * 100)   // 10
    private static let maxPercent = Double(EditorCanvasScrollView.manualMaxZoom * 100) // 800

    /// Slider position (log space) for a given zoom factor.
    private func sliderPosition(forZoom zoom: CGFloat) -> Double {
        let pct = min(max(Double(zoom * 100), Self.minPercent), Self.maxPercent)
        return log(pct)
    }

    /// Zoom factor for a given slider position (inverse of `sliderPosition`).
    private func zoom(forSliderPosition pos: Double) -> CGFloat {
        CGFloat(exp(pos) / 100.0)
    }

    private func formattedPercent(_ zoom: CGFloat) -> String {
        "\(Int((zoom * 100).rounded()))%"
    }

    /// Commit a typed zoom % (fires on Return / Tab / focus-out). Parses the
    /// number, clamps to [minPercent, maxPercent], applies it, and reflects the
    /// clamped value. Non-numeric input restores the current zoom.
    /// True while `refreshZoomDisplay` is taking focus away from the percentage
    /// field because the zoom changed elsewhere. Ending editing fires
    /// `controlTextDidEndEditing`, which would otherwise commit the field's
    /// value back as a NEW zoom — a change from outside must not bounce back in.
    private var syncingFromExternalZoom = false

    func controlTextDidEndEditing(_ obj: Notification) {
        guard (obj.object as AnyObject?) === percentLabel else { return }
        guard !syncingFromExternalZoom else { return }
        // Keep only digits and a decimal point ("150%", "150 %" → 150).
        let filtered = percentLabel.stringValue.filter { $0.isNumber || $0 == "." }
        guard let pct = Double(filtered), pct > 0 else {
            refreshZoomDisplay()   // invalid → restore the current value
            return
        }
        let clampedZoom = CGFloat(min(max(pct, Self.minPercent), Self.maxPercent) / 100.0)
        onSetZoom(clampedZoom)
        // Reflect the applied (clamped) value now, independent of the state.zoom
        // observation tick.
        percentLabel.stringValue = formattedPercent(clampedZoom)
        let pos = sliderPosition(forZoom: clampedZoom)
        if abs(zoomSlider.doubleValue - pos) > 0.001 { zoomSlider.doubleValue = pos }
    }

    @objc private func tabsChanged(_ sender: NSSegmentedControl) {
        let newTab: BottomTab = sender.selectedSegment == 0 ? .recent : .deleted
        state?.bottomTab = newTab
        onTabChange(newTab)
    }

    /// Update the segmented control without firing `onTabChange`. Called
    /// by the controller when it changes `state.bottomTab` programmatically
    /// (e.g., after a restore switches back to Recent).
    func setActiveTab(_ tab: BottomTab) {
        tabs.selectedSegment = (tab == .recent) ? 0 : 1
    }

    /// Enable/disable the "Deleted" tab (segment 1). Greyed out and unclickable
    /// when the trash is empty.
    func setDeletedTabEnabled(_ enabled: Bool) {
        tabs.setEnabled(enabled, forSegment: 1)
    }

    private func makeMediaFilterControl() -> NSSegmentedControl {
        let images = [
            NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "All files"),
            NSImage(systemSymbolName: "photo", accessibilityDescription: "Images"),
            NSImage(systemSymbolName: "video", accessibilityDescription: "Videos"),
        ].map { $0 ?? NSImage() }
        let control = NSSegmentedControl(images: images, trackingMode: .selectOne,
                                         target: self, action: #selector(mediaFilterChanged(_:)))
        control.segmentStyle = .rounded
        control.selectedSegment = 0
        control.setToolTip("All files", forSegment: 0)
        control.setToolTip("Images", forSegment: 1)
        control.setToolTip("Videos", forSegment: 2)
        return control
    }

    @objc private func mediaFilterChanged(_ sender: NSSegmentedControl) {
        let idx = max(0, min(Self.filterOrder.count - 1, sender.selectedSegment))
        onSelectMediaFilter(Self.filterOrder[idx])
    }

    /// Reflect a filter on the control without firing `onSelectMediaFilter`.
    func setMediaFilter(_ filter: StripMediaFilter) {
        mediaFilterControl.selectedSegment = Self.filterOrder.firstIndex(of: filter) ?? 0
    }

    // MARK: Observation

    private func observeZoomAndCrop() {
        guard let state = state else { return }
        withObservationTracking {
            _ = state.zoom
            _ = state.croppedRect
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.refreshZoomDisplay()
                self?.refreshDimensions()
                self?.observeZoomAndCrop()
            }
        }
    }

    /// Reflect the active zoom in both the readout label and the slider thumb:
    /// the video override when set, else `state.zoom`. Keeps the slider in
    /// sync when zoom changes via Fit / Original / the ⌘+/⌘−/⌘0 keyboard
    /// shortcuts, not just direct slider drags.
    private func refreshZoomDisplay() {
        guard let zoom = zoomDisplayOverride ?? state?.zoom else { return }
        if percentLabel.currentEditor() != nil {
            // The zoom changed from somewhere ELSE while this field had focus —
            // ⌘±, ⌘0, Fit, the slider, the ± buttons, ⌘+scroll on the canvas.
            // Keeping focus strands a stale number the user appears to be
            // editing, and the field editor swallows further input aimed at the
            // zoom. Give up focus and show the new value.
            //
            // Only when the value actually MOVED: typing "15" on the way to
            // "150" must not yank focus away mid-edit.
            let shown = percentLabel.stringValue.filter { $0.isNumber || $0 == "." }
            let moved = Double(shown).map { abs($0 - Double(zoom) * 100) > 0.5 } ?? true
            if moved {
                // ORDER AND GUARD BOTH MATTER. Resigning first responder ends
                // editing, and AppKit treats that exactly like pressing Return:
                // `controlTextDidEndEditing` fires and commits whatever the
                // field is showing. Dropping focus first therefore re-applied
                // the STALE number — zoom out to 50% with the field focused and
                // it snapped straight back to 100%.
                //
                // So: write the new text first, and suppress the commit outright
                // for a change that came from outside rather than from typing.
                syncingFromExternalZoom = true
                // Write through the FIELD EDITOR, not just the field. While a
                // text field is being edited an NSTextView holds the live text;
                // setting `stringValue` leaves that untouched, so ending editing
                // commits the editor's stale copy. That is what made zooming to
                // 50% with this field focused snap straight back to 100%.
                percentLabel.currentEditor()?.string = formattedPercent(zoom)
                percentLabel.stringValue = formattedPercent(zoom)
                window?.makeFirstResponder(nil)
                // Clear on the NEXT turn: the end-editing notification does not
                // always arrive inside `makeFirstResponder`, and clearing here
                // would re-open the gate before it lands.
                DispatchQueue.main.async { [weak self] in
                    self?.syncingFromExternalZoom = false
                }
            }
        } else {
            percentLabel.stringValue = formattedPercent(zoom)
        }
        let pos = sliderPosition(forZoom: zoom)
        if abs(zoomSlider.doubleValue - pos) > 0.001 {
            zoomSlider.doubleValue = pos
        }
    }

    /// Pin (non-nil) or release (nil) the zoom display to an external value —
    /// the in-canvas video player's zoom while a video session is active.
    /// Resize is image-only, so the trigger disables while pinned.
    func setZoomDisplayOverride(_ zoom: CGFloat?) {
        zoomDisplayOverride = zoom
        // The field edits the IMAGE zoom; while a video's zoom is pinned here,
        // typing would set the hidden image zoom — disable editing then.
        percentLabel.isEditable = (zoom == nil)
        dimensionsButton.isEnabled = (zoom == nil)
        dimensionsButton.toolTip = zoom == nil ? "Resize image…" : "Resize applies to images"
        refreshZoomDisplay()
    }

    /// Test hook: the zoom % currently shown in the readout.
    var debugPercentText: String { percentLabel.stringValue }

    /// Test hooks: the strip toggle's tooltip, and a click on it.
    var debugStripToggleTooltip: String? { stripToggle.toolTip }
    func debugClickStripToggle() { stripToggleClicked() }

    private func refreshDimensions() {
        guard let state = state else { return }
        let size = state.visibleImageSize
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let lift = Self.dimensionsBaselineLift
        let title = NSMutableAttributedString(
            string: "\(Int(size.width)) × \(Int(size.height))  ",
            attributes: [
                .font: font,
                .baselineOffset: lift,
                .foregroundColor: NSColor.labelColor,
            ])
        // Chevron as a text attachment so it rides the same baseline lift as the
        // number (a separate button image couldn't be moved with the title).
        if let chevron = NSImage(systemSymbolName: "chevron.up",
                                 accessibilityDescription: "Resize image")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold)) {
            let attachment = NSTextAttachment()
            attachment.image = chevron
            let h = chevron.size.height
            // Center the glyph on the font's cap height, then apply the shared lift.
            attachment.bounds = CGRect(x: 0, y: (font.capHeight - h) / 2 + lift,
                                       width: chevron.size.width, height: h)
            title.append(NSAttributedString(attachment: attachment))
        }
        dimensionsButton.attributedTitle = title
    }
}

// MARK: - Zoom-button magnifier-lens icons

/// Which distinguishing mark goes inside the magnifier lens.
private enum ZoomLensGlyph { case fit, focus, width, height, one }

/// Builds a template `NSImage` of a magnifying glass whose inner mark tells the
/// five zoom actions apart. Geometry is authored in a 24-unit top-left space
/// (matching the design mock) and the lens is enlarged 1.12× about its centre
/// for the "Larger" size. Template image → the system tints it like the other
/// toolbar controls and it adapts to light/dark automatically.
private func zoomLensImage(_ glyph: ZoomLensGlyph, accessibility: String) -> NSImage {
    let pt: CGFloat = 15
    let image = NSImage(size: NSSize(width: pt, height: pt), flipped: true) { _ in
        let s = pt / 24.0
        let k: CGFloat = 1.12
        // 24-unit point, enlarged about the lens centre (10,10), then to points.
        func P(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: (10 + (x - 10) * k) * s, y: (10 + (y - 10) * k) * s)
        }
        func stroke(_ pts: [(CGFloat, CGFloat)], width: CGFloat) {
            let path = NSBezierPath()
            for (i, p) in pts.enumerated() {
                let q = P(p.0, p.1)
                if i == 0 { path.move(to: q) } else { path.line(to: q) }
            }
            path.lineWidth = width
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            NSColor.black.setStroke()   // template mask — actual tint is applied by AppKit
            path.stroke()
        }
        // Lens + handle.
        let c = P(10, 10)
        let r = 7.4 * k * s
        let lens = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        lens.lineWidth = 1.3
        NSColor.black.setStroke()
        lens.stroke()
        stroke([(15.2, 15.2), (20.6, 20.6)], width: 1.6)   // handle
        // Inner mark.
        switch glyph {
        case .fit:   // four diagonal arrows toward the lens corners
            stroke([(6.7, 6.7), (8.7, 8.7)], width: 1.2)
            stroke([(6.7, 8.7), (6.7, 6.7), (8.7, 6.7)], width: 1.2)
            stroke([(13.3, 6.7), (11.3, 8.7)], width: 1.2)
            stroke([(13.3, 8.7), (13.3, 6.7), (11.3, 6.7)], width: 1.2)
            stroke([(6.7, 13.3), (8.7, 11.3)], width: 1.2)
            stroke([(6.7, 11.3), (6.7, 13.3), (8.7, 13.3)], width: 1.2)
            stroke([(13.3, 13.3), (11.3, 11.3)], width: 1.2)
            stroke([(13.3, 11.3), (13.3, 13.3), (11.3, 13.3)], width: 1.2)
        case .focus: // four square brackets (viewfinder corners)
            stroke([(6.9, 8.4), (6.9, 6.9), (8.4, 6.9)], width: 1.2)
            stroke([(11.6, 6.9), (13.1, 6.9), (13.1, 8.4)], width: 1.2)
            stroke([(13.1, 11.6), (13.1, 13.1), (11.6, 13.1)], width: 1.2)
            stroke([(8.4, 13.1), (6.9, 13.1), (6.9, 11.6)], width: 1.2)
        case .width: // ↔
            stroke([(6.3, 10), (13.7, 10)], width: 1.2)
            stroke([(8, 8.2), (6.3, 10), (8, 11.8)], width: 1.2)
            stroke([(12, 8.2), (13.7, 10), (12, 11.8)], width: 1.2)
        case .height: // ↕
            stroke([(10, 6.3), (10, 13.7)], width: 1.2)
            stroke([(8.2, 8), (10, 6.3), (11.8, 8)], width: 1.2)
            stroke([(8.2, 12), (10, 13.7), (11.8, 12)], width: 1.2)
        case .one:   // numeral 1
            stroke([(8.8, 8.3), (10.3, 7.3), (10.3, 13)], width: 1.2)
            stroke([(8.9, 13), (11.9, 13)], width: 1.2)
        }
        return true
    }
    image.isTemplate = true
    image.accessibilityDescription = accessibility
    return image
}
