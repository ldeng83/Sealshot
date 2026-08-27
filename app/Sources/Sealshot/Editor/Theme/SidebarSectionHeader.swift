import AppKit

/// All-caps, letter-spaced, small secondary-color label used as a
/// section header in the sidebar's tool-properties panel. Reusable
/// across all per-tool views.
final class SidebarSectionHeader: NSTextField {

    init(text: String) {
        super.init(frame: .zero)
        isEditable = false
        isBezeled = false
        isSelectable = false
        drawsBackground = false
        translatesAutoresizingMaskIntoConstraints = false
        // Set the plain font/colour as defaults too (not only via the attributed
        // string): if anything ever drops the attributed attributes, the field
        // still renders at the section-header size/colour rather than the system
        // default (13pt regular).
        font = Theme.sectionHeaderFont
        textColor = .secondaryLabelColor
        applyText(text)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not implemented") }

    func setText(_ text: String) { applyText(text) }

    /// The header is a decorative label — it must never intercept mouse events.
    /// Returning `nil` keeps clicks from reaching `NSTextField`/`NSControl`'s
    /// mouse handling, which otherwise discards our attributed-string styling and
    /// re-renders the text in the field's default font (system 13pt regular) on
    /// the first click. Clicks pass through to the panel behind instead.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func applyText(_ text: String) {
        let attributed = NSAttributedString(
            string: text.uppercased(),
            attributes: [
                .font: Theme.sectionHeaderFont,
                // Secondary (not tertiary): tertiary is ~26% black, nearly
                // invisible on the white light-mode surface. Secondary reads
                // clearly in both modes.
                .foregroundColor: NSColor.secondaryLabelColor,
                .kern: Theme.sectionHeaderKern,
            ]
        )
        self.attributedStringValue = attributed
    }
}
