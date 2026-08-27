import AppKit

/// Horizontal label-on-left, value-on-right row for displaying simple
/// key-value pairs (e.g., "Format / PNG", "Size / 1.2 MB"). No border,
/// no background — relies on the surrounding panel for spacing.
final class KeyValueRow: NSView {

    private let labelView = NSTextField(labelWithString: "")
    private let valueView = NSTextField(labelWithString: "")

    init(label: String, value: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

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
        valueView.alignment = .right
        valueView.translatesAutoresizingMaskIntoConstraints = false
        valueView.isEditable = false
        valueView.isBezeled = false
        valueView.drawsBackground = false

        addSubview(labelView)
        addSubview(valueView)
        NSLayoutConstraint.activate([
            labelView.leadingAnchor.constraint(equalTo: leadingAnchor),
            labelView.centerYAnchor.constraint(equalTo: centerYAnchor),
            valueView.trailingAnchor.constraint(equalTo: trailingAnchor),
            valueView.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 20),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not implemented") }

    func setValue(_ value: String) { valueView.stringValue = value }
}
