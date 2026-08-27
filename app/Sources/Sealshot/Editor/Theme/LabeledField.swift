import AppKit

/// Read-only floating-label input view — label at top, value below,
/// rounded rect background. Used in the meta row for Width/Height
/// and (later) anywhere a labeled value needs a card-like treatment.
final class LabeledField: NSView {

    private let labelView = NSTextField(labelWithString: "")
    private let valueView = NSTextField(labelWithString: "")

    init(label: String, value: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        applySurfaceColors()

        labelView.font = Theme.labelFont
        labelView.textColor = .secondaryLabelColor
        labelView.stringValue = label
        labelView.translatesAutoresizingMaskIntoConstraints = false
        labelView.isEditable = false
        labelView.isBezeled = false
        labelView.drawsBackground = false

        valueView.font = Theme.valueFont
        valueView.textColor = .labelColor
        valueView.stringValue = value
        valueView.translatesAutoresizingMaskIntoConstraints = false
        valueView.isEditable = false
        valueView.isBezeled = false
        valueView.drawsBackground = false

        addSubview(labelView)
        addSubview(valueView)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 80),
            heightAnchor.constraint(equalToConstant: 50),
            labelView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            labelView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            valueView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            valueView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
        ])
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not implemented") }

    // Layer colors are resolved from dynamic NSColors into static cgColors, so
    // they don't auto-update when the theme changes. Re-resolve on appearance
    // change (e.g. the Settings Light/Dark switch).
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applySurfaceColors()
    }

    // Repaint once we're in the window: a bare `…cgColor` at init resolves
    // against the ambient appearance, which may differ from the window's (app
    // theme override) — and no appearance CHANGE fires to correct it.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applySurfaceColors()
    }

    /// Resolve the surface/border cgColors against THIS view's effective
    /// appearance (not the ambient `NSAppearance.current`).
    private func applySurfaceColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Theme.surfaceColor.cgColor
            layer?.borderColor = Theme.surfaceBorderColor.cgColor
        }
    }

    func setValue(_ value: String) { valueView.stringValue = value }
}
