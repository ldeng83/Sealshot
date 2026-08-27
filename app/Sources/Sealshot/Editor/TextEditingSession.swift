import AppKit
import Observation

/// Observable bridge between the live `InlineTextEditor` and the sidebar's text
/// styling panel. The canvas owns the editor and creates a session per edit;
/// the sidebar observes `EditorState.activeTextEditing` and renders controls
/// bound to this session. `epoch` bumps on every selection/attribute change so
/// the panel rebuilds with current values.
@MainActor
@Observable
final class TextEditingSession {
    private(set) var epoch: Int = 0
    private let editor: InlineTextEditor

    init(editor: InlineTextEditor) { self.editor = editor }

    func refresh() { epoch &+= 1 }

    /// Current selection's color, normalized to opaque (box opacity stripped)
    /// for display in the chip; nil = mixed/none.
    var color: NSColor? { editor.selectionColor.map { opaqueSRGB($0) } }
    var fontSize: CGFloat? { editor.selectionFontSize }
    var isBold: Bool? { editor.selectionIsBold }
    /// Selected font family (`nil` = System, or mixed — the panel shows System).
    var fontFamily: String? { editor.selectionFontFamily ?? nil }

    // Parity read-outs (mirror the selected-text-object panel).
    var weight: TextWeight? { editor.selectionWeight }
    var isItalic: Bool { editor.selectionIsItalic }
    var underline: Bool { editor.selectionUnderline }
    var strikethrough: Bool { editor.selectionStrikethrough }
    var highlight: NSColor? { editor.selectionHighlight }
    var outlineColor: NSColor? { editor.selectionOutlineColor }
    var outlineWidth: CGFloat { editor.selectionOutlineWidth }
    var alignment: TextAlignment { editor.alignment }
    var lineSpacing: CGFloat { editor.lineSpacing }
    var verticalAlignment: TextVerticalAlignment { editor.verticalAlignment }
    var opacity: Double { editor.opacity }

    func applyColor(_ c: NSColor) { editor.applyColor(c) }
    func applyFontSize(_ size: CGFloat) { editor.applyFontSize(size) }
    func setBold(_ bold: Bool) { editor.setBold(bold) }
    func applyFontFamily(_ family: String?) {
        editor.applyFontFamily(family)
        AnnotationTextFont.remembered = family
    }
    func applyWeight(_ w: TextWeight?) { editor.applyWeight(w) }
    func setItalic(_ v: Bool) { editor.setItalic(v) }
    func setUnderline(_ v: Bool) { editor.setUnderline(v) }
    func setStrikethrough(_ v: Bool) { editor.setStrikethrough(v) }
    func applyHighlight(_ c: NSColor?) { editor.applyHighlight(c) }
    func applyOutline(_ c: NSColor?) { editor.applyOutline(c) }
    func applyOutlineWidth(_ w: CGFloat) { editor.applyOutlineWidth(w) }
    func setAlignment(_ a: TextAlignment) { editor.setAlignment(a) }
    func setLineSpacing(_ s: CGFloat) { editor.setLineSpacing(s) }
    func setVerticalAlignment(_ v: TextVerticalAlignment) { editor.setVerticalAlignment(v) }
    func setOpacity(_ o: Double) { editor.setOpacity(o) }
}
