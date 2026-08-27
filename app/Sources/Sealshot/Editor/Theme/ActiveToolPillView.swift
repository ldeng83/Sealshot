import AppKit

/// Custom view set as `NSToolbarItem.view` for each tool button in the
/// editor toolbar. Draws a soft accent-tinted rounded-rect background
/// when `isActive` is true; renders the SF Symbol in `.medium` weight
/// normally and `.semibold` when active. Forwards clicks to `onClick`.
/// Subclassed by `GroupedToolPillView` (Line/Arrow group), so not `final`.
class ActiveToolPillView: HoverTooltipView {

    static let pillSize: CGFloat = 28
    static let defaultSymbolPointSize: CGFloat = 14

    private var baseSymbolName: String
    private var overrideSymbolName: String?
    private var overrideTint: NSColor?
    private var flashWorkItem: DispatchWorkItem?
    private let symbolPointSize: CGFloat
    private let onClick: () -> Void
    private let imageView = NSImageView()

    var isActive: Bool = false {
        didSet {
            if isActive != oldValue {
                refreshSymbol()
                needsDisplay = true
            }
        }
    }

    /// When false the glyph is dimmed and clicks/tooltips are ignored.
    /// Used for the Undo/Redo buttons when their stack is empty.
    var isEnabled: Bool = true {
        didSet {
            if isEnabled != oldValue { refreshSymbol() }
        }
    }

    init(
        symbolName: String,
        accessibilityLabel: String,
        symbolPointSize: CGFloat = ActiveToolPillView.defaultSymbolPointSize,
        onClick: @escaping () -> Void
    ) {
        self.baseSymbolName = symbolName
        self.symbolPointSize = symbolPointSize
        self.onClick = onClick
        super.init(frame: NSRect(x: 0, y: 0, width: Self.pillSize, height: Self.pillSize))
        wantsLayer = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyDown
        // Custom instant tooltip (no AppKit hover delay), triggered across
        // the whole pill by HoverTooltipView's tracking area.
        tooltipText = accessibilityLabel
        setAccessibilityRole(.button)
        setAccessibilityLabel(accessibilityLabel)
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(equalToConstant: Self.pillSize),
            heightAnchor.constraint(equalToConstant: Self.pillSize),
        ])
        refreshSymbol()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not implemented") }

    /// Replace the displayed base symbol. Used by grouped pills that mirror the
    /// last-used sub-tool. Ignored visually while a flash override is active;
    /// the new base shows once the flash reverts.
    func setBaseSymbol(_ name: String) {
        baseSymbolName = name
        refreshSymbol()
    }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard isActive else { return }
        let path = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
        Theme.accentColor.withAlphaComponent(0.15).setFill()
        path.fill()
    }

    override func mouseDown(with event: NSEvent) {
        performClick()
    }

    /// The one click path, so a caller (or a test) exercises exactly what a
    /// real click does — including the disabled guard — rather than reaching
    /// past it to `onClick`.
    func performClick() {
        guard isEnabled else { return }
        InstantTooltip.shared.hide()
        onClick()
    }

    override func mouseEntered(with event: NSEvent) {
        guard isEnabled else { return }
        super.mouseEntered(with: event)
    }

    private func refreshSymbol() {
        let weight: NSFont.Weight = isActive ? .semibold : .medium
        imageView.image = ToolGlyph.image(overrideSymbolName ?? baseSymbolName,
                                          pointSize: symbolPointSize, weight: weight)
        let tint: NSColor = overrideTint
            ?? (isActive ? Theme.accentColor
                         : (isEnabled ? .labelColor : .tertiaryLabelColor))
        imageView.contentTintColor = tint
    }

    /// Briefly swap to `symbolName`/`tint` and show `text` below the pill, then
    /// revert. Restarts cleanly if called again mid-flash.
    func flashConfirmation(symbolName: String, tint: NSColor, text: String, duration: TimeInterval = 1.0) {
        flashWorkItem?.cancel()
        overrideSymbolName = symbolName
        overrideTint = tint
        refreshSymbol()
        InstantTooltip.shared.show(text, below: self)

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.overrideSymbolName = nil
            self.overrideTint = nil
            self.refreshSymbol()
            InstantTooltip.shared.hide()
        }
        flashWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }
}
