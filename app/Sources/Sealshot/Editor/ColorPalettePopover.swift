import AppKit

/// One palette swatch. `color == nil` renders the "no color" diagonal. Left
/// click selects; right-click (when `onRemove` is set) offers Remove.
final class SwatchView: NSView {
    let color: NSColor?
    var isSelected = false { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?
    var onRemove: (() -> Void)?

    init(color: NSColor?, side: CGFloat = 22) {
        self.color = color
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: side).isActive = true
        heightAnchor.constraint(equalToConstant: side).isActive = true
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5)
        if let color = color {
            color.setFill(); path.fill()
        } else {
            NSColor(white: 0.23, alpha: 1).setFill(); path.fill()
            let slash = NSBezierPath()
            slash.move(to: NSPoint(x: r.minX + 4, y: r.minY + 4))
            slash.line(to: NSPoint(x: r.maxX - 4, y: r.maxY - 4))
            NSColor.systemRed.setStroke(); slash.lineWidth = 2; slash.stroke()
        }
        NSColor.white.withAlphaComponent(0.18).setStroke(); path.lineWidth = 1; path.stroke()
        if isSelected {
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
            NSColor.controlAccentColor.setStroke(); ring.lineWidth = 2; ring.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) { onClick?() }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard onRemove != nil else { return nil }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Remove", action: #selector(removeClicked), keyEquivalent: ""))
        menu.items.first?.target = self
        return menu
    }
    @objc private func removeClicked() { onRemove?() }
}

/// In-app color palette shown in an `NSPopover`: presets, persisted "My colors",
/// and a custom picker (saturation/brightness + hue + hex + "Add"). Reports
/// every selection/edit through `onPick` (nil = no color, only when allowed).
final class ColorPalettePopoverController: NSViewController, NSTextFieldDelegate {

    static let presets: [NSColor] = [
        .systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue,
        .systemIndigo, .systemPink, .black, .white
    ]

    private let allowsNoColor: Bool
    private let store: CustomColorStore
    private var current: NSColor
    private var isNoColorSelected: Bool
    private let onPick: (NSColor?) -> Void
    /// Set by the host chip to close the popover on Esc.
    var onDismiss: (() -> Void)?

    private let sbView = SaturationBrightnessView()
    private let hueView = HueSliderView()
    private let hexField = NSTextField()
    private var myColorsRow = NSStackView()

    init(allowsNoColor: Bool, current: NSColor?, store: CustomColorStore = .shared,
         onPick: @escaping (NSColor?) -> Void) {
        self.allowsNoColor = allowsNoColor
        self.store = store
        self.isNoColorSelected = (current == nil)
        self.current = current ?? .systemRed
        self.onPick = onPick
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        // Wider side insets so the color pad isn't flush against the popover edge.
        root.edgeInsets = NSEdgeInsets(top: 12, left: 18, bottom: 12, right: 18)

        root.addArrangedSubview(sectionLabel("Presets"))
        root.addArrangedSubview(presetGrid())

        root.addArrangedSubview(sectionLabel("My colors"))
        myColorsRow = grid(rebuildMyColors())
        root.addArrangedSubview(myColorsRow)

        root.addArrangedSubview(sectionLabel("Custom"))
        root.addArrangedSubview(customPicker())

        root.widthAnchor.constraint(equalToConstant: 248).isActive = true   // 18 + 212 + 18
        self.view = root
        syncCustomControls(to: current)
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        // Dismissing the popover applies a pending hex edit even if end-editing
        // hasn't fired yet — but never reverts a No-color choice.
        autoCommitHex()
    }

    /// Esc closes the palette (in addition to clicking outside).
    override func cancelOperation(_ sender: Any?) {
        onDismiss?()
    }

    // MARK: Sections

    private func sectionLabel(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text.uppercased())
        l.font = .systemFont(ofSize: 10, weight: .semibold)
        l.textColor = .secondaryLabelColor
        return l
    }

    private func grid(_ swatches: [SwatchView]) -> NSStackView {
        let row = NSStackView(views: swatches)
        row.orientation = .horizontal
        row.spacing = 7
        row.alignment = .centerY
        return row
    }

    private func presetGrid() -> NSView {
        var swatches: [SwatchView] = Self.presets.map { color in
            let s = SwatchView(color: color)
            s.isSelected = sameColor(color, current)
            s.onClick = { [weak self] in self?.pick(color) }
            return s
        }
        if allowsNoColor {
            let none = SwatchView(color: nil)
            none.isSelected = isNoColorSelected
            none.onClick = { [weak self] in self?.pickNoColor() }
            swatches.append(none)
        }
        // Wrap to two rows of up to 5.
        let v = NSStackView()
        v.orientation = .vertical
        v.alignment = .leading
        v.spacing = 7
        for chunk in stride(from: 0, to: swatches.count, by: 5).map({ Array(swatches[$0..<min($0 + 5, swatches.count)]) }) {
            v.addArrangedSubview(grid(chunk))
        }
        return v
    }

    private func rebuildMyColors() -> [SwatchView] {
        store.colors.map { color in
            let s = SwatchView(color: color)
            s.isSelected = sameColor(color, current)
            s.onClick = { [weak self] in self?.pick(color) }
            s.onRemove = { [weak self] in
                self?.store.remove(color)
                self?.refreshMyColors()
            }
            return s
        }
    }

    private func refreshMyColors() {
        myColorsRow.arrangedSubviews.forEach { myColorsRow.removeArrangedSubview($0); $0.removeFromSuperview() }
        rebuildMyColors().forEach { myColorsRow.addArrangedSubview($0) }
    }

    private func customPicker() -> NSView {
        let col = NSStackView()
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 8

        sbView.translatesAutoresizingMaskIntoConstraints = false
        sbView.heightAnchor.constraint(equalToConstant: 96).isActive = true
        sbView.widthAnchor.constraint(equalToConstant: 212).isActive = true
        sbView.onChange = { [weak self] s, b in self?.customChanged() }

        hueView.translatesAutoresizingMaskIntoConstraints = false
        hueView.heightAnchor.constraint(equalToConstant: 14).isActive = true
        hueView.widthAnchor.constraint(equalToConstant: 212).isActive = true
        hueView.onChange = { [weak self] h in
            self?.sbView.hue = h
            self?.customChanged()
        }

        hexField.translatesAutoresizingMaskIntoConstraints = false
        hexField.widthAnchor.constraint(equalToConstant: 96).isActive = true
        hexField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        hexField.target = self
        hexField.action = #selector(hexCommitted)
        // Commit on focus loss (clicking elsewhere / dismissing the popover), not
        // only on Return — `controlTextDidEndEditing` covers both.
        hexField.delegate = self

        let addButton = NSButton(title: "+ Add to My colors", target: self, action: #selector(addCurrent))
        addButton.bezelStyle = .rounded
        addButton.controlSize = .small

        // Hex input and the Add button live on their own rows so neither is
        // cramped by the other.
        let hexRow = NSStackView(views: [NSTextField(labelWithString: "Hex"), hexField])
        hexRow.orientation = .horizontal
        hexRow.spacing = 6

        col.addArrangedSubview(sbView)
        col.addArrangedSubview(hueView)
        col.addArrangedSubview(hexRow)
        col.addArrangedSubview(addButton)
        return col
    }

    // MARK: Behavior

    private func pick(_ color: NSColor) {
        isNoColorSelected = false
        current = color
        syncCustomControls(to: color)
        refreshSelectionRings()
        onPick(color)
    }

    private func pickNoColor() {
        isNoColorSelected = true
        refreshSelectionRings()
        onPick(nil)
    }

    private func customChanged() {
        isNoColorSelected = false
        let color = HSB(hue: sbView.hue, saturation: sbView.saturation, brightness: sbView.brightness).nsColor
        current = color
        hexField.stringValue = hexString(from: color)
        refreshSelectionRings()
        onPick(color)
    }

    /// Return in the hex field: apply the typed color (overriding any "No color").
    @objc private func hexCommitted() { applyHexField() }

    /// Focus-loss / dismiss: apply the typed hex WITHOUT reverting an explicit
    /// "No color" choice — the field still shows the previous color's hex, and
    /// re-applying it would silently undo the user's No-color selection.
    private func autoCommitHex() {
        guard !isNoColorSelected else { return }
        applyHexField()
    }

    private func applyHexField() {
        guard let color = color(fromHex: hexField.stringValue) else {
            hexField.stringValue = hexString(from: current)   // revert invalid input
            return
        }
        // Skip a redundant re-pick when the field already matches the current
        // color (e.g. end-editing firing right after a swatch pick); but when No
        // color is selected, a typed hex should override it.
        guard isNoColorSelected || !sameColor(color, current) else { return }
        pick(color)
    }

    /// Apply the typed hex when the field loses focus — clicking another control
    /// in the popover, or dismissing the popover — so the user needn't press
    /// Return. Guarded so it never reverts a No-color choice.
    func controlTextDidEndEditing(_ obj: Notification) {
        guard (obj.object as AnyObject) === hexField else { return }
        autoCommitHex()
    }

    @objc private func addCurrent() {
        store.add(current)
        refreshMyColors()
    }

    private func syncCustomControls(to color: NSColor) {
        let hsb = HSB(color)
        sbView.hue = hsb.hue
        sbView.saturation = hsb.saturation
        sbView.brightness = hsb.brightness
        hueView.hue = hsb.hue
        hexField.stringValue = hexString(from: color)
    }

    private func refreshSelectionRings() {
        for case let s as SwatchView in allSwatches(view) {
            if s.color == nil {
                s.isSelected = isNoColorSelected
            } else {
                s.isSelected = !isNoColorSelected && sameColor(s.color!, current)
            }
        }
    }

    private func allSwatches(_ root: NSView) -> [NSView] {
        root.subviews.flatMap { [$0] + allSwatches($0) }
    }

    private func sameColor(_ a: NSColor, _ b: NSColor) -> Bool {
        hexString(from: a) == hexString(from: b)
    }
}
