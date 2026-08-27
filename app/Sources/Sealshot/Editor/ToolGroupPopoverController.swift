import AppKit

/// Compact chooser shown from the grouped Line/Arrow pill. Lists the group's
/// sub-tools (icon + label) with the current one check-marked; clicking a row
/// reports the pick via `onPick`. The owner closes the popover on pick.
final class ToolGroupPopoverController: NSViewController {

    struct Item {
        let tool: EditorTool
        let symbol: String
        let label: String
    }

    private let items: [Item]
    private let current: EditorTool
    private let onPick: (EditorTool) -> Void

    init(items: [Item], current: EditorTool, onPick: @escaping (EditorTool) -> Void) {
        self.items = items
        self.current = current
        self.onPick = onPick
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)

        for item in items {
            let row = ToolGroupRow(item: item, isCurrent: item.tool == current) { [weak self] picked in
                self?.onPick(picked)
            }
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -12).isActive = true
        }

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            // Wide enough for the longest label ("Free Arrow"/"Line Arrow" at
            // 13pt ≈ 66pt) plus icon + checkmark; 132pt squeezed the default
            // tool's label into "Rectangl…" / "Line Arro…".
            container.widthAnchor.constraint(equalToConstant: 160),
        ])
        view = container
    }
}

/// One selectable row in the Line/Arrow chooser: leading symbol, label, and a
/// trailing checkmark when it is the active sub-tool. Highlights on hover.
private final class ToolGroupRow: HoverTooltipView {

    private let tool: EditorTool
    private let onClick: (EditorTool) -> Void
    private var hovering = false { didSet { needsDisplay = true } }

    init(item: ToolGroupPopoverController.Item, isCurrent: Bool, onClick: @escaping (EditorTool) -> Void) {
        self.tool = item.tool
        self.onClick = onClick
        super.init(frame: NSRect(x: 0, y: 0, width: 120, height: 30))
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 30).isActive = true

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyDown
        icon.image = ToolGlyph.image(item.symbol, pointSize: 14, weight: .medium)
        icon.contentTintColor = .labelColor

        let label = NSTextField(labelWithString: item.label)
        label.font = .systemFont(ofSize: 13, weight: .regular)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        addSubview(icon)
        addSubview(label)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        if isCurrent {
            let check = NSImageView()
            check.translatesAutoresizingMaskIntoConstraints = false
            check.imageScaling = .scaleProportionallyDown
            check.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
            check.contentTintColor = Theme.accentColor
            addSubview(check)
            NSLayoutConstraint.activate([
                check.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
                check.centerYAnchor.constraint(equalTo: centerYAnchor),
                // Keep a gap between the label and the checkmark so they never touch.
                check.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 12),
            ])
        }

        tooltipText = item.label
        setAccessibilityRole(.button)
        setAccessibilityLabel(item.label)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard hovering else { return }
        let path = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
        Theme.accentColor.withAlphaComponent(0.15).setFill()
        path.fill()
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        hovering = true
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hovering = false
    }

    override func mouseDown(with event: NSEvent) {
        InstantTooltip.shared.hide()
        onClick(tool)
    }
}
