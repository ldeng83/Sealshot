import CoreGraphics
import Foundation

/// Grow-only sizing engine for text boxes (pure — unit-tested without UI).
///
/// The box rect is a MASK over text laid out at `layoutWidth`. While typing:
/// hard newlines (Enter) and style changes grow the HEIGHT; soft wrapping is
/// allowed only while the height has room for the extra rows — otherwise the
/// LAYOUT WIDTH grows so typing continues on the current row (per spec:
/// Enter is how you add rows). Nothing ever shrinks during a session.
enum TextBoxSizer {
    struct Result: Equatable { var rect: CGRect; var layoutWidth: CGFloat }

    static func grownBox(runs: [TextRun], lineSpacing: CGFloat,
                         rect: CGRect, layoutWidth: CGFloat,
                         rectFollowsWidth: Bool) -> Result {
        var rect = rect
        var width = max(layoutWidth, rect.width)

        // Text wraps within the box's horizontal padding, so measurements use the
        // box width minus 2·pad. The returned width/rect stay full box widths.
        func wrapHeight(boxWidth: CGFloat) -> CGFloat {
            textBoxHeight(runs: runs, width: max(1, boxWidth - 2 * textBoxHPadding), lineSpacing: lineSpacing)
        }

        // 1. Hard lines (explicit Enters) + style growth: the height every
        //    hard line needs even with NO soft wrapping.
        let unwrapped = textBoxHeight(runs: runs, width: 1_000_000, lineSpacing: lineSpacing)
        if unwrapped > rect.height { rect.size.height = ceil(unwrapped) }

        // 2. Soft wrapping: fits within the (possibly grown) height at the
        //    current layout width → done. Otherwise grow the width until the
        //    wrapped text fits the height (binary search on measurement).
        if wrapHeight(boxWidth: width) > rect.height + 0.5 {
            var lo = width
            var hi = max(width * 2, 64)
            while wrapHeight(boxWidth: hi) > rect.height + 0.5 {
                hi *= 2
                if hi > 1_000_000 { break }   // safety: give up growing, fall through
            }
            for _ in 0..<24 {
                let mid = (lo + hi) / 2
                if wrapHeight(boxWidth: mid) > rect.height + 0.5 {
                    lo = mid
                } else {
                    hi = mid
                }
            }
            width = ceil(hi)
        }

        if rectFollowsWidth { rect.size.width = max(rect.width, width) }
        return Result(rect: rect, layoutWidth: max(width, rect.width))
    }

    /// Rect for a NEW text box. Click: one character cell of the creation
    /// font (the box then grows with typing). Drag: exactly the dragged box
    /// (min 40×one line) — its height is the wrap capacity.
    static func creationRect(clickAt origin: CGPoint, draggedRect: CGRect,
                             isClick: Bool, style: Style) -> CGRect {
        let probe = TextRun(text: "M", color: style.strokeColor,
                            fontSize: style.fontSize, isBold: style.isBold)
        let lineH = textBoxHeight(runs: [probe], width: 10_000, lineSpacing: style.lineSpacing)
        if isClick {
            let charW = ceil(attributedString(for: [probe], opacity: 1).size().width)
            // + 2·pad so the caret/text has the box's horizontal padding on both
            // sides even for a one-character starting box.
            return CGRect(x: origin.x, y: origin.y, width: max(8, charW) + 2 * textBoxHPadding, height: lineH)
        }
        return CGRect(x: draggedRect.minX, y: draggedRect.minY,
                      width: max(40, draggedRect.width),
                      height: max(lineH, draggedRect.height))
    }
}
