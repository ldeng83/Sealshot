import AppKit
import SwiftUI

/// A single-line text label for the Library list row's file name. Unlike a
/// SwiftUI `Text`, it:
///
/// - shows a **native tooltip with the full name** while the text is
///   truncated (SwiftUI `.help()` doesn't fire inside the gesture-laden row),
/// - **forwards a plain click / double-click** back to the row, so clicking the
///   name still selects the item (respecting ⇧/⌘) and double-clicking still
///   opens it, and
/// - **reports whether the name is truncated** at the current width.
///
/// List view only.
struct SelectableRowLabel: NSViewRepresentable {
    let text: String
    /// Shown as a native tooltip only while the text is truncated — a name
    /// that already fits gets no tooltip.
    let tooltip: String
    /// Plain click (no drag-highlight). The closure reads the live modifier
    /// flags itself (⇧ range / ⌘ toggle / plain).
    var onClick: () -> Void
    /// Double click with no drag — open/activate the item.
    var onDoubleClick: () -> Void
    /// Called (on layout) when the truncated state changes: true when the name
    /// no longer fits the label's width and is showing an ellipsis.
    var onTruncationChange: (Bool) -> Void = { _ in }
    /// Label font — defaults to the list's system size; the grid passes a
    /// smaller (caption) font.
    var font: NSFont = .systemFont(ofSize: NSFont.systemFontSize)

    func makeNSView(context: Context) -> ArrowCursorLabel {
        let label = ArrowCursorLabel(labelWithString: text)
        // Not selectable: a click on a selectable field starts the field
        // editor, which drops the middle-ellipsis and shows the (clipped)
        // full text — read as the name "expanding" on click.
        label.isSelectable = false
        label.isEditable = false
        label.isBordered = false
        label.drawsBackground = false
        label.backgroundColor = .clear
        label.focusRingType = .none
        label.font = font
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        label.cell?.truncatesLastVisibleLine = true
        // Fill the available width and truncate rather than dictating the row
        // width from the (possibly long) file name.
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        label.tooltipWhenTruncated = tooltip
        label.onClick = onClick
        label.onDoubleClick = onDoubleClick
        label.onTruncationChange = onTruncationChange
        return label
    }

    func updateNSView(_ label: ArrowCursorLabel, context: Context) {
        if label.stringValue != text { label.stringValue = text }
        label.tooltipWhenTruncated = tooltip
        label.onClick = onClick
        label.onDoubleClick = onDoubleClick
        label.onTruncationChange = onTruncationChange
    }
}

/// Label that draws the arrow cursor, shows its tooltip only while truncated,
/// and reports a plain click / double-click and its truncation state to the
/// owning row.
final class ArrowCursorLabel: NSTextField {
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onTruncationChange: ((Bool) -> Void)?
    /// Tooltip applied only while the text is truncated (see `layout()`).
    var tooltipWhenTruncated: String?
    private var lastTruncated: Bool?

    /// Pointer cursor over the whole label instead of the selectable field's
    /// default I-beam.
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    /// After each layout, compare the natural (untruncated) text width to the
    /// available width and report changes, so the row knows whether a
    /// click-to-reveal is warranted.
    override func layout() {
        super.layout()
        let natural = attributedStringValue.size().width
        let truncated = natural > bounds.width + 0.5
        // Assign only on change — re-registering the tooltip dismisses one
        // that is currently on screen (every re-render lays out again, e.g.
        // when clicking the row toggles the selection highlight).
        let desired = truncated ? tooltipWhenTruncated : nil
        if toolTip != desired { toolTip = desired }
        if truncated != lastTruncated {
            lastTruncated = truncated
            onTruncationChange?(truncated)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            onDoubleClick?()
        } else {
            onClick?()
        }
    }
}
