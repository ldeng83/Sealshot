import AppKit

/// Non-destructive suggestion list shown under the "Add tag…" field. Renders as
/// a borderless child window (immune to the sidebar scroll clip), never alters
/// the field's text — selecting a row calls `onPick`.
@MainActor
final class TagSuggestionDropdown {
    var onPick: ((TagSuggestion) -> Void)?
    private(set) var isVisible = false
    private var items: [TagSuggestion] = []
    private var selection = -1
    private var panel: NSWindow?
    private let stack = NSStackView()

    init() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
    }

    var selected: TagSuggestion? {
        items.indices.contains(selection) ? items[selection] : nil
    }

    func moveSelection(_ delta: Int) {
        guard !items.isEmpty else { return }
        selection = max(-1, min(items.count - 1, selection + delta))
        renderRows()
    }

    func hide() {
        if let p = panel {
            p.orderOut(nil)
            p.parent?.removeChildWindow(p)
        }
        panel = nil
        isVisible = false
        selection = -1
        items = []
    }

    func update(suggestions: [TagSuggestion], below field: NSTextField) {
        items = suggestions
        if selection >= items.count { selection = -1 }
        guard !items.isEmpty, let window = field.window else { hide(); return }
        renderRows()

        let width = max(field.frame.width, 180)
        let height = stack.fittingSize.height
        let p = ensurePanel(in: window)
        p.setContentSize(NSSize(width: width, height: height))

        // Anchor just below the field, converted to screen coordinates.
        let fieldRectInWindow = field.convert(field.bounds, to: nil)
        let originInWindow = NSPoint(x: fieldRectInWindow.minX,
                                     y: fieldRectInWindow.minY - height - 2)
        let originInScreen = window.convertPoint(toScreen: originInWindow)
        p.setFrameOrigin(originInScreen)
        if !isVisible {
            window.addChildWindow(p, ordered: .above)
            isVisible = true
        }
    }

    private func ensurePanel(in window: NSWindow) -> NSWindow {
        if let panel { return panel }
        let p = NSWindow(contentRect: .zero, styleMask: [.borderless],
                         backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = false
        let bg = NSVisualEffectView()
        bg.material = .menu
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 8
        bg.layer?.masksToBounds = true
        bg.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(bg)
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            bg.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bg.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bg.topAnchor.constraint(equalTo: content.topAnchor),
            bg.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor),
        ])
        p.contentView = content
        panel = p
        return p
    }

    private func renderRows() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, item) in items.enumerated() {
            stack.addArrangedSubview(rowView(item, selected: i == selection))
        }
    }

    private func rowView(_ item: TagSuggestion, selected: Bool) -> NSView {
        let row = SuggestionRowView()
        row.onClick = { [weak self] in self?.onPick?(item) }
        row.translatesAutoresizingMaskIntoConstraints = false
        row.wantsLayer = true
        row.layer?.backgroundColor = selected
            ? NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
            : NSColor.clear.cgColor

        let tagLabel = NSTextField(labelWithString: item.tag)
        tagLabel.font = NSFont.systemFont(ofSize: 12)
        let trailingText: String = {
            switch item.kind {
            case .canonical: return "suggested"
            case .existing:  return item.count.map(String.init) ?? ""
            }
        }()
        let trailing = NSTextField(labelWithString: trailingText)
        trailing.font = NSFont.systemFont(ofSize: 11)
        trailing.textColor = .tertiaryLabelColor

        let h = NSStackView(views: [tagLabel, NSView(), trailing])
        h.orientation = .horizontal
        h.translatesAutoresizingMaskIntoConstraints = false
        h.edgeInsets = NSEdgeInsets(top: 5, left: 10, bottom: 5, right: 10)
        row.addSubview(h)
        NSLayoutConstraint.activate([
            h.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            h.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            h.topAnchor.constraint(equalTo: row.topAnchor),
            h.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            row.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
        ])
        return row
    }
}

/// A clickable row that reports clicks without stealing key focus from the field.
@MainActor
private final class SuggestionRowView: NSView {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClick?() }
}
