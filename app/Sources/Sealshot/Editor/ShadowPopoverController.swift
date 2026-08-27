import AppKit

/// Inline editor for `ShadowStyle`, shown in an `NSPopover` anchored to the
/// "Shadow" row in the tool-properties panel. Agnostic to whether it edits
/// an object's style or a per-tool creation default — the caller supplies
/// closures.
///
/// - `read()`: called on every slider/switch change to obtain the latest
///   `ShadowStyle` baseline before mutating one field and writing back.
/// - `write(updated)`: called after every change; owns persistence.
/// - `onEditBegin()`: called at the start of each user interaction (drag start
///   for sliders; before the action for discrete controls). Undo wiring lives
///   in the caller, not here.
/// - `onEditEnd()`: called at the end of each user interaction (drag end for
///   sliders; after the action for discrete controls).
@MainActor
final class ShadowPopoverController: NSViewController {

    private let read: () -> ShadowStyle
    private let write: (ShadowStyle) -> Void

    var onEditBegin: () -> Void = { }
    var onEditEnd: () -> Void = { }

    // Retain target-action handler objects for the lifetime of the view.
    private var enableHandler: EnableHandler?
    private var presetsHandler: PresetsHandler?
    private var blurHandler: SliderHandler?
    private var offsetXHandler: SliderHandler?
    private var offsetYHandler: SliderHandler?
    private var opacityHandler: SliderHandler?
    private var resetHandler: ResetHandler?
    private var colorApplier: ShadowColorApplier?
    private var directionHandler: DirectionHandler?

    // Stored references so they can be refreshed when offsets change via
    // any source (preset, reset, direction grid, pad drag).
    private weak var positionPad: ShadowPositionPad?
    private weak var offsetXSlider: NSSlider?
    private weak var offsetYSlider: NSSlider?
    // Color chip reference — updated alongside sliders when presets/reset fire.
    private weak var colorChipView: ColorChipButton?
    // All arranged subviews below the enable row: hidden when shadow is off.
    private var bodyViewsGroup: [NSView] = []

    init(read: @escaping () -> ShadowStyle, write: @escaping (ShadowStyle) -> Void) {
        self.read = read
        self.write = write
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let shadow = read()

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // — Enable / disable toggle —
        let enableRow = NSStackView()
        enableRow.orientation = .horizontal
        enableRow.spacing = 8
        let enableSwitch = NSSwitch()
        enableSwitch.state = shadow.enabled ? .on : .off
        let eh = EnableHandler(read: read, write: write,
                               onEditBegin: { [weak self] in self?.onEditBegin() },
                               onEditEnd: { [weak self] in self?.onEditEnd() },
                               onDidWrite: { [weak self] in self?.updateEnabledVisibility() })
        enableSwitch.target = eh
        enableSwitch.action = #selector(EnableHandler.toggled(_:))
        enableHandler = eh
        enableRow.addArrangedSubview(enableSwitch)
        enableRow.addArrangedSubview(rowLabel("Shadow"))
        stack.addArrangedSubview(enableRow)

        // — Presets —
        stack.addArrangedSubview(SidebarSectionHeader(text: "Presets"))
        let presetsSeg = NSSegmentedControl()
        presetsSeg.segmentCount = 3
        presetsSeg.setLabel("Subtle", forSegment: 0)
        presetsSeg.setLabel("Pronounced", forSegment: 1)
        presetsSeg.setLabel("Glow", forSegment: 2)
        presetsSeg.trackingMode = .momentary
        presetsSeg.segmentStyle = .texturedRounded
        presetsSeg.translatesAutoresizingMaskIntoConstraints = false
        let ph = PresetsHandler(write: write,
                                onEditBegin: { [weak self] in self?.onEditBegin() },
                                onEditEnd: { [weak self] in self?.onEditEnd() },
                                onDidWrite: { [weak self] in self?.refreshPositionControls() })
        presetsSeg.target = ph
        presetsSeg.action = #selector(PresetsHandler.picked(_:))
        presetsHandler = ph
        stack.addArrangedSubview(presetsSeg)

        // — Color —
        stack.addArrangedSubview(SidebarSectionHeader(text: "Color"))
        let ca = ShadowColorApplier(read: read, write: write,
                                    onEditBegin: { [weak self] in self?.onEditBegin() },
                                    onEditEnd: { [weak self] in self?.onEditEnd() })
        let colorChip = ColorChipButton(color: shadow.color.nsColor, allowsNoColor: false)
        colorChip.onPick = { [weak ca] color in ca?.pick(color) }
        colorApplier = ca
        colorChipView = colorChip
        stack.addArrangedSubview(colorChip)

        // — Blur —
        stack.addArrangedSubview(SidebarSectionHeader(text: "Blur"))
        let blurH = SliderHandler(read: read, write: write) { s, v in s.blur = CGFloat(v) }
        blurHandler = blurH
        stack.addArrangedSubview(shadowSlider(
            value: Double(shadow.blur), min: 0, max: 30, handler: blurH))

        // — Position (pad + direction grid) — inserted ABOVE Offset X/Y sliders —
        stack.addArrangedSubview(SidebarSectionHeader(text: "Position"))

        let pad = ShadowPositionPad()
        pad.offset = shadow.offset
        pad.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            pad.widthAnchor.constraint(equalToConstant: 128),
            pad.heightAnchor.constraint(equalToConstant: 128),
        ])
        positionPad = pad

        // Wire pad drag → edit bracketing + live write
        pad.onDragStart = { [weak self] in self?.onEditBegin() }
        pad.onDragEnd = { [weak self] in self?.onEditEnd() }
        pad.onChange = { [weak self] newOffset in
            guard let self else { return }
            var sh = self.read(); sh.offset = newOffset; self.write(sh)
            self.offsetXSlider?.doubleValue = Double(newOffset.width)
            self.offsetYSlider?.doubleValue = Double(newOffset.height)
        }

        // Direction grid — 3×3 buttons (↖ ↑ ↗ / ← • → / ↙ ↓ ↘)
        let dirGrid = buildDirectionGrid()

        let posRow = NSStackView()
        posRow.orientation = .horizontal
        posRow.spacing = 12
        posRow.alignment = .centerY
        posRow.addArrangedSubview(pad)
        posRow.addArrangedSubview(dirGrid)
        stack.addArrangedSubview(posRow)

        // — Offset X —
        stack.addArrangedSubview(SidebarSectionHeader(text: "Offset X"))
        let oxH = SliderHandler(read: read, write: write) { [weak self] s, v in
            s.offset.width = CGFloat(v)
            self?.positionPad?.offset = s.offset
        }
        offsetXHandler = oxH
        let oxSlider = shadowSlider(
            value: Double(shadow.offset.width), min: -40, max: 40, handler: oxH)
        offsetXSlider = oxSlider
        stack.addArrangedSubview(oxSlider)

        // — Offset Y —
        stack.addArrangedSubview(SidebarSectionHeader(text: "Offset Y"))
        let oyH = SliderHandler(read: read, write: write) { [weak self] s, v in
            s.offset.height = CGFloat(v)
            self?.positionPad?.offset = s.offset
        }
        offsetYHandler = oyH
        let oySlider = shadowSlider(
            value: Double(shadow.offset.height), min: -40, max: 40, handler: oyH)
        offsetYSlider = oySlider
        stack.addArrangedSubview(oySlider)

        // — Opacity —
        stack.addArrangedSubview(SidebarSectionHeader(text: "Opacity"))
        let opH = SliderHandler(read: read, write: write) { s, v in s.opacity = v }
        opacityHandler = opH
        stack.addArrangedSubview(shadowSlider(
            value: shadow.opacity, min: 0, max: 1, handler: opH))

        // — Reset —
        let rh = ResetHandler(write: write,
                              onEditBegin: { [weak self] in self?.onEditBegin() },
                              onEditEnd: { [weak self] in self?.onEditEnd() },
                              onDidWrite: { [weak self] in self?.refreshPositionControls() })
        let resetBtn = NSButton(title: "Reset to Default", target: rh,
                                action: #selector(ResetHandler.reset))
        resetBtn.bezelStyle = .rounded
        resetHandler = rh
        stack.addArrangedSubview(resetBtn)

        // Body views = everything after the enable row; hidden when shadow is off.
        if let enableIdx = stack.arrangedSubviews.firstIndex(of: enableRow) {
            bodyViewsGroup = Array(stack.arrangedSubviews[(enableIdx + 1)...])
        }

        // Container — fixed width; height auto-fits the stack.
        let host = NSView()
        host.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: host.topAnchor),
            stack.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            host.widthAnchor.constraint(equalToConstant: 280),
        ])
        view = host
        // Apply initial visibility so the popover opens at the correct size.
        updateEnabledVisibility()
    }

    // MARK: Private helpers

    /// Sync position pad, offset sliders, and color chip to reflect the current
    /// shadow state (called after preset / reset / direction-grid changes).
    private func refreshPositionControls() {
        let shadow = read()
        positionPad?.offset = shadow.offset
        offsetXSlider?.doubleValue = Double(shadow.offset.width)
        offsetYSlider?.doubleValue = Double(shadow.offset.height)
        colorChipView?.color = shadow.color.nsColor
    }

    /// Show or hide all parameter controls based on `shadow.enabled`.
    /// Called on toggle and on initial load so the popover opens at the right size.
    private func updateEnabledVisibility() {
        let enabled = read().enabled
        for v in bodyViewsGroup { v.isHidden = !enabled }
        // Resize the popover to fit the (possibly shorter) content.
        if isViewLoaded, view.window != nil {
            view.layoutSubtreeIfNeeded()
            preferredContentSize = view.fittingSize
        }
    }

    /// Build a 3×3 NSGridView of directional arrow buttons, wrapped in a
    /// container so the grid can be centered in the right-hand column of the
    /// Position row. Every button is fixed at 28×28 pt so the total grid size
    /// is deterministic regardless of glyph intrinsic width, and repeated opens
    /// produce an identical layout.
    private func buildDirectionGrid() -> NSView {
        // Row-major layout: (dx, dy) pairs and labels
        let cells: [(Int, Int, String)] = [
            (-1, -1, "↖"), (0, -1, "↑"), (1, -1, "↗"),
            (-1,  0, "←"), (0,  0, "•"), (1,  0, "→"),
            (-1,  1, "↙"), (0,  1, "↓"), (1,  1, "↘"),
        ]

        let dh = DirectionHandler(read: read, write: write,
                                  onEditBegin: { [weak self] in self?.onEditBegin() },
                                  onEditEnd: { [weak self] in self?.onEditEnd() },
                                  onDidWrite: { [weak self] in self?.refreshPositionControls() })
        directionHandler = dh

        var rows: [[NSView]] = []
        for rowIdx in 0..<3 {
            var rowViews: [NSView] = []
            for colIdx in 0..<3 {
                let (dx, dy, label) = cells[rowIdx * 3 + colIdx]
                let btn = NSButton(title: label, target: dh,
                                   action: #selector(DirectionHandler.tapped(_:)))
                btn.bezelStyle = .texturedRounded
                btn.font = NSFont.systemFont(ofSize: 14)
                btn.isBordered = true
                btn.translatesAutoresizingMaskIntoConstraints = false
                // Fixed equal size so all nine cells are uniform and the grid
                // has a constant total width/height regardless of glyph metrics.
                NSLayoutConstraint.activate([
                    btn.widthAnchor.constraint(equalToConstant: 28),
                    btn.heightAnchor.constraint(equalToConstant: 28),
                ])
                // Encode dx/dy into the tag: tag = (dy+1)*3 + (dx+1) → 0..8
                btn.tag = (dy + 1) * 3 + (dx + 1)
                rowViews.append(btn)
            }
            rows.append(rowViews)
        }

        let gridView = NSGridView(views: rows)
        gridView.columnSpacing = 2
        gridView.rowSpacing = 2
        gridView.translatesAutoresizingMaskIntoConstraints = false

        // Wrap in a container so the grid is centered in the available column
        // space next to the position pad (both horizontally and vertically).
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(gridView)
        NSLayoutConstraint.activate([
            gridView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            gridView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            container.widthAnchor.constraint(greaterThanOrEqualTo: gridView.widthAnchor),
            container.heightAnchor.constraint(greaterThanOrEqualTo: gridView.heightAnchor),
        ])
        return container
    }

    private func rowLabel(_ text: String) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        return f
    }

    private func shadowSlider(value: Double, min: Double, max: Double,
                               handler: SliderHandler) -> StyleEditSlider {
        let slider = StyleEditSlider(value: value, minValue: min, maxValue: max,
                                     target: handler, action: #selector(SliderHandler.changed(_:)))
        slider.onDragStart = { [weak self] in self?.onEditBegin() }
        slider.onDragEnd = { [weak self] in self?.onEditEnd() }
        slider.isContinuous = true
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        return slider
    }

    // MARK: Nested handlers

    /// Toggles `enabled` on the shadow and writes the updated style.
    @MainActor
    private final class EnableHandler: NSObject {
        private let read: () -> ShadowStyle
        private let write: (ShadowStyle) -> Void
        private let onEditBegin: () -> Void
        private let onEditEnd: () -> Void
        private let onDidWrite: () -> Void
        init(read: @escaping () -> ShadowStyle, write: @escaping (ShadowStyle) -> Void,
             onEditBegin: @escaping () -> Void, onEditEnd: @escaping () -> Void,
             onDidWrite: @escaping () -> Void = { }) {
            self.read = read; self.write = write
            self.onEditBegin = onEditBegin; self.onEditEnd = onEditEnd
            self.onDidWrite = onDidWrite
        }
        @objc func toggled(_ sender: NSSwitch) {
            onEditBegin()
            var s = read(); s.enabled = sender.state == .on; write(s)
            onEditEnd()
            onDidWrite()
        }
    }

    /// Snaps all shadow fields to a named preset and writes.
    @MainActor
    private final class PresetsHandler: NSObject {
        private let write: (ShadowStyle) -> Void
        private let onEditBegin: () -> Void
        private let onEditEnd: () -> Void
        private let onDidWrite: () -> Void
        init(write: @escaping (ShadowStyle) -> Void,
             onEditBegin: @escaping () -> Void, onEditEnd: @escaping () -> Void,
             onDidWrite: @escaping () -> Void) {
            self.write = write
            self.onEditBegin = onEditBegin; self.onEditEnd = onEditEnd
            self.onDidWrite = onDidWrite
        }
        @objc func picked(_ sender: NSSegmentedControl) {
            let presets: [ShadowStyle] = [
                ShadowStyle(enabled: true, color: SerializableColor(.black),
                            blur: 6, offset: CGSize(width: 1, height: 2), opacity: 0.35),
                .pronounced,
                ShadowStyle(enabled: true, color: SerializableColor(.white),
                            blur: 12, offset: CGSize(width: 0, height: 0), opacity: 0.80),
            ]
            let idx = sender.selectedSegment
            guard presets.indices.contains(idx) else { return }
            onEditBegin()
            write(presets[idx])
            onEditEnd()
            onDidWrite()
        }
    }

    /// Generic one-field mutator: reads the current style, applies a mutation,
    /// and writes the result. Used for all five numeric sliders.
    @MainActor
    private final class SliderHandler: NSObject {
        private let read: () -> ShadowStyle
        private let write: (ShadowStyle) -> Void
        private let apply: (inout ShadowStyle, Double) -> Void
        init(read: @escaping () -> ShadowStyle,
             write: @escaping (ShadowStyle) -> Void,
             apply: @escaping (inout ShadowStyle, Double) -> Void) {
            self.read = read; self.write = write; self.apply = apply
        }
        @objc func changed(_ sender: NSSlider) {
            var s = read(); apply(&s, sender.doubleValue); write(s)
        }
    }

    /// Writes the canonical `.pronounced` default. "Reset to Default" button target.
    @MainActor
    private final class ResetHandler: NSObject {
        private let write: (ShadowStyle) -> Void
        private let onEditBegin: () -> Void
        private let onEditEnd: () -> Void
        private let onDidWrite: () -> Void
        init(write: @escaping (ShadowStyle) -> Void,
             onEditBegin: @escaping () -> Void, onEditEnd: @escaping () -> Void,
             onDidWrite: @escaping () -> Void) {
            self.write = write
            self.onEditBegin = onEditBegin; self.onEditEnd = onEditEnd
            self.onDidWrite = onDidWrite
        }
        @objc func reset() {
            onEditBegin()
            write(.pronounced)
            onEditEnd()
            onDidWrite()
        }
    }

    /// Handles taps on the 3×3 direction grid. Decodes (dx, dy) from the button
    /// tag (tag = (dy+1)*3 + (dx+1)), snaps the current offset to that direction,
    /// and performs one bracketed edit.
    @MainActor
    private final class DirectionHandler: NSObject {
        private let read: () -> ShadowStyle
        private let write: (ShadowStyle) -> Void
        private let onEditBegin: () -> Void
        private let onEditEnd: () -> Void
        private let onDidWrite: () -> Void
        init(read: @escaping () -> ShadowStyle, write: @escaping (ShadowStyle) -> Void,
             onEditBegin: @escaping () -> Void, onEditEnd: @escaping () -> Void,
             onDidWrite: @escaping () -> Void) {
            self.read = read; self.write = write
            self.onEditBegin = onEditBegin; self.onEditEnd = onEditEnd
            self.onDidWrite = onDidWrite
        }
        @objc func tapped(_ sender: NSButton) {
            // Decode tag: tag = (dy+1)*3 + (dx+1)
            let tag = sender.tag
            let dx = (tag % 3) - 1
            let dy = (tag / 3) - 1
            var sh = read()
            let newOffset = shadowDirectionSnap(current: sh.offset, dx: dx, dy: dy, fallbackDistance: 14)
            sh.offset = newOffset
            onEditBegin()
            write(sh)
            onEditEnd()
            onDidWrite()
        }
    }
}

/// 2-D position pad for shadow offset. Square view with `isFlipped = true` so
/// y-down matches screen-space shadow offset conventions. Drag anywhere in the
/// pad to set the offset; center = (0,0); edges = ±maxOffset.
@MainActor
private final class ShadowPositionPad: NSView {

    override var isFlipped: Bool { true }

    /// Current shadow offset (screen-space px). Setting triggers a redraw.
    var offset: CGSize = .zero { didSet { needsDisplay = true } }

    /// Maximum magnitude in each axis (maps to edge of pad).
    var maxOffset: CGFloat = 40

    /// Called continuously during drag with the new offset value.
    var onChange: ((CGSize) -> Void)?
    /// Called when a drag begins (mouseDown).
    var onDragStart: (() -> Void)?
    /// Called when a drag ends (mouseUp).
    var onDragEnd: (() -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let bounds = self.bounds
        let mid = CGPoint(x: bounds.midX, y: bounds.midY)

        // Background: rounded rect
        ctx.saveGState()
        let bg = NSColor.controlBackgroundColor.withAlphaComponent(0.8)
        bg.setFill()
        let roundedPath = CGPath(roundedRect: bounds.insetBy(dx: 1, dy: 1),
                                  cornerWidth: 6, cornerHeight: 6, transform: nil)
        ctx.addPath(roundedPath)
        ctx.clip()
        ctx.fillPath()

        // Crosshair lines
        ctx.setStrokeColor(NSColor.separatorColor.withAlphaComponent(0.35).cgColor)
        ctx.setLineWidth(0.5)
        ctx.move(to: CGPoint(x: mid.x, y: bounds.minY + 4))
        ctx.addLine(to: CGPoint(x: mid.x, y: bounds.maxY - 4))
        ctx.move(to: CGPoint(x: bounds.minX + 4, y: mid.y))
        ctx.addLine(to: CGPoint(x: bounds.maxX - 4, y: mid.y))
        ctx.strokePath()

        // Center ring
        let ringRadius: CGFloat = 3
        ctx.setStrokeColor(NSColor.tertiaryLabelColor.cgColor)
        ctx.setLineWidth(1)
        ctx.addEllipse(in: CGRect(x: mid.x - ringRadius, y: mid.y - ringRadius,
                                  width: ringRadius * 2, height: ringRadius * 2))
        ctx.strokePath()

        // Dot position (inverse of shadowPadOffset: center + fraction * halfSize)
        let dotX = bounds.midX + offset.width / maxOffset * bounds.midX
        let dotY = bounds.midY + offset.height / maxOffset * bounds.midY
        let dotPos = CGPoint(x: dotX, y: dotY)

        // Line from center to dot
        if dotPos.x != mid.x || dotPos.y != mid.y {
            ctx.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.5).cgColor)
            ctx.setLineWidth(1)
            ctx.move(to: mid)
            ctx.addLine(to: dotPos)
            ctx.strokePath()
        }

        ctx.restoreGState()

        // 1 pt outline drawn outside the clip so the full stroke is visible.
        NSColor.separatorColor.setStroke()
        ctx.setLineWidth(1.0)
        ctx.addPath(roundedPath)
        ctx.strokePath()

        // Accent dot
        let dotRadius: CGFloat = 5
        NSColor.controlAccentColor.setFill()
        let dotRect = CGRect(x: dotPos.x - dotRadius, y: dotPos.y - dotRadius,
                             width: dotRadius * 2, height: dotRadius * 2)
        let dotPath = NSBezierPath(ovalIn: dotRect)
        dotPath.fill()
    }

    override func mouseDown(with event: NSEvent) {
        onDragStart?()
        let p = convert(event.locationInWindow, from: nil)
        let newOffset = shadowPadOffset(point: p, size: bounds.width, maxOffset: maxOffset)
        offset = newOffset
        onChange?(newOffset)
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let newOffset = shadowPadOffset(point: p, size: bounds.width, maxOffset: maxOffset)
        offset = newOffset
        onChange?(newOffset)
    }

    override func mouseUp(with event: NSEvent) {
        onDragEnd?()
    }
}

/// Forwards a color pick from a `ColorChipButton` into a live `ShadowStyle`,
/// reading the current baseline before mutating the `color` field.
@MainActor
private final class ShadowColorApplier {
    private let read: () -> ShadowStyle
    private let write: (ShadowStyle) -> Void
    private let onEditBegin: () -> Void
    private let onEditEnd: () -> Void
    init(read: @escaping () -> ShadowStyle, write: @escaping (ShadowStyle) -> Void,
         onEditBegin: @escaping () -> Void = { }, onEditEnd: @escaping () -> Void = { }) {
        self.read = read; self.write = write
        self.onEditBegin = onEditBegin; self.onEditEnd = onEditEnd
    }
    func pick(_ color: NSColor?) {
        guard let color else { return }
        onEditBegin()
        var s = read()
        s.color = SerializableColor(opaqueSRGB(color))
        write(s)
        onEditEnd()
    }
}
