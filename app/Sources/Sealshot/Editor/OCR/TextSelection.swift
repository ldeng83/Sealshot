import Foundation

/// An insertion point in a recognized-text layout: `char` is an index in
/// `0...line.count` (a caret position, not a character). Comparable in
/// reading order.
struct TextPosition: Equatable, Comparable {
    var line: Int
    var char: Int

    static func < (a: TextPosition, b: TextPosition) -> Bool {
        a.line != b.line ? a.line < b.line : a.char < b.char
    }
}

/// A text selection as an anchor/focus pair (drag start / drag current).
/// `ordered` normalizes so `start <= end`.
struct TextSelection: Equatable {
    var anchor: TextPosition
    var focus: TextPosition

    static func collapsed(at p: TextPosition) -> TextSelection {
        TextSelection(anchor: p, focus: p)
    }

    var ordered: (start: TextPosition, end: TextPosition) {
        anchor <= focus ? (anchor, focus) : (focus, anchor)
    }

    var isEmpty: Bool { anchor == focus }
}
