import AppKit

/// A borderless floating window that shows a short label with **no**
/// delay. AppKit's built-in `toolTip` waits ~2s before appearing and the
/// delay isn't adjustable through public API, so the editor toolbar uses
/// this instead to surface tool names the instant the pointer arrives.
///
/// Styled like the editor's surface cards (white/near-black fill, hairline
/// border) so it reads as part of the same theme. Shared singleton — only
/// one tooltip is ever visible, and hovering a new button just repositions
/// and retitles the same window.
@MainActor
final class InstantTooltip {

    static let shared = InstantTooltip()

    private var window: NSWindow?
    private let container = NSView()
    private let label = NSTextField(labelWithString: "")

    private init() {}

    private func makeWindowIfNeeded() {
        guard window == nil else { return }

        let win = NSWindow(
            contentRect: .zero,
            styleMask: .borderless,
            backing: .buffered,
            defer: true
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.level = .popUpMenu
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]

        container.wantsLayer = true
        container.layer?.cornerRadius = 5
        container.layer?.borderWidth = 1

        label.font = .systemFont(ofSize: 11, weight: .regular)
        label.textColor = .labelColor
        label.backgroundColor = .clear
        label.isBezeled = false
        label.drawsBackground = false
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -7),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -3),
        ])

        win.contentView = container
        window = win
    }

    /// Show `text` centered just below `view`, immediately.
    func show(_ text: String, below view: NSView) {
        guard let hostWindow = view.window else { return }
        makeWindowIfNeeded()
        guard let win = window else { return }

        label.stringValue = text
        win.appearance = hostWindow.effectiveAppearance
        // Layer colors are CGColors, so resolve the dynamic theme colors
        // against the host window's appearance (dark vs light).
        hostWindow.effectiveAppearance.performAsCurrentDrawingAppearance {
            container.layer?.backgroundColor = Theme.surfaceColor.cgColor
            container.layer?.borderColor = Theme.surfaceBorderColor.cgColor
        }

        container.layoutSubtreeIfNeeded()
        let size = container.fittingSize
        win.setContentSize(size)

        let inWindow = view.convert(view.bounds, to: nil)
        let onScreen = hostWindow.convertToScreen(inWindow)
        let gap: CGFloat = 5
        let origin = NSPoint(
            x: onScreen.midX - size.width / 2,
            y: onScreen.minY - gap - size.height
        )
        win.setFrameOrigin(origin)
        win.orderFrontRegardless()
    }

    func hide() {
        window?.orderOut(nil)
    }
}

/// Base view that shows an `InstantTooltip` the moment the pointer enters,
/// and hides it on exit. Subclasses set `tooltipText`.
class HoverTooltipView: NSView {

    /// Text shown on hover. Nil or empty → no tooltip.
    var tooltipText: String?

    /// Optional dynamic text, evaluated on EACH hover so the tooltip always
    /// reflects live state — e.g. a user-customized keyboard shortcut. Takes
    /// precedence over `tooltipText` whenever it returns a non-nil value.
    var tooltipTextProvider: (() -> String?)?

    /// Whether the tooltip tracks the pointer while Sealshot is INACTIVE.
    ///
    /// Off by default: an editor toolbar tooltip appearing while you work in
    /// another app would be noise. The floating capture panel opts in, because
    /// it is a `.nonactivatingPanel` that deliberately never makes Sealshot
    /// active — so the default would mean its tooltips never fire at all.
    var tracksWhileAppInactive = false {
        didSet {
            guard tracksWhileAppInactive != oldValue else { return }
            updateTrackingAreas()
        }
    }

    private var hoverTracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = hoverTracking { removeTrackingArea(existing) }
        let activation: NSTrackingArea.Options =
            tracksWhileAppInactive ? .activeAlways : .activeInActiveApp
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, activation],
            owner: self
        )
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        let text = tooltipTextProvider?() ?? tooltipText
        if let text, !text.isEmpty {
            InstantTooltip.shared.show(text, below: self)
        }
    }

    override func mouseExited(with event: NSEvent) {
        InstantTooltip.shared.hide()
    }
}
