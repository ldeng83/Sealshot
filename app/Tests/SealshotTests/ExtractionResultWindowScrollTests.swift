import AppKit
import XCTest
@testable import Sealshot

/// The Extract Structured Data window shows line-structured data — space-padded
/// tables (rendered `.byClipping`), CSV, JSON, pre-broken OCR text. Its text
/// views used to soft-wrap with no horizontal scroller, so a wide table's
/// columns were clipped at the view edge with no way to reach them.
@MainActor
final class ExtractionResultWindowScrollTests: XCTestCase {

    private func makeController() -> ExtractionResultWindowController {
        ExtractionResultWindowController(
            record: ExtractionRecord(items: StructuredItems(),
                                     markdown: "| A | B |\n|---|---|\n| 1 | 2 |",
                                     focusRect: nil,
                                     version: ExtractionRecord.currentVersion),
            onReExtract: {})
    }

    private func textScrollViews(in root: NSView) -> [NSScrollView] {
        var found: [NSScrollView] = []
        var queue: [NSView] = [root]
        while let view = queue.popLast() {
            if let scroll = view as? NSScrollView, scroll.documentView is NSTextView {
                found.append(scroll)
            }
            queue.append(contentsOf: view.subviews)
        }
        return found
    }

    func test_everyTextView_scrollsHorizontally() throws {
        let controller = makeController()
        let root = try XCTUnwrap(controller.window?.contentView)
        let scrolls = textScrollViews(in: root)
        XCTAssertFalse(scrolls.isEmpty, "no text scroll views found — did the layout change?")

        for scroll in scrolls {
            let tv = scroll.documentView as! NSTextView
            XCTAssertTrue(scroll.hasHorizontalScroller,
                          "missing horizontal scroller")
            XCTAssertFalse(tv.textContainer?.widthTracksTextView ?? true,
                           "width-tracking container re-enables soft wrap")
            XCTAssertTrue(tv.isHorizontallyResizable,
                          "text view cannot grow to its content width")
        }
    }

    /// Shown-window behavior: when content overflows, the scroller must be
    /// visible WITH a usable knob; when everything fits, the track must hide
    /// entirely rather than sit empty ("a scroll bar with no scroller").
    func test_shownWindow_scrollerHasKnobOnlyWhenContentOverflows() throws {
        let wideRow = (0..<40).map { "Column\($0)Value" }.joined(separator: " | ")
        let wide = makeShownController(markdown: "| \(wideRow) |\n|---|\n| x |")
        defer { wide.close() }
        let narrow = makeShownController(markdown: "| a | b |\n|---|---|\n| 1 | 2 |")
        defer { narrow.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        let wideScrolls = try textScrollViews(in: XCTUnwrap(wide.window?.contentView))
        let overflowing = wideScrolls.first {
            ($0.documentView?.frame.width ?? 0) > $0.contentView.bounds.width + 1
        }
        let scroller = try XCTUnwrap(overflowing?.horizontalScroller,
                                     "wide table produced no overflowing scroll view")
        XCTAssertFalse(scroller.isHidden, "overflowing content must show the scroller")
        XCTAssertLessThan(scroller.knobProportion, 0.999,
                          "the scroller must have a draggable knob, not an empty track")

        for scroll in try textScrollViews(in: XCTUnwrap(narrow.window?.contentView)) {
            let doc = scroll.documentView?.frame.width ?? 0
            if doc <= scroll.contentView.bounds.width + 1 {
                XCTAssertTrue(scroll.horizontalScroller?.isHidden ?? true,
                              "content that fits must hide the track, not show it empty")
            }
        }
    }

    private func makeShownController(markdown: String) -> ExtractionResultWindowController {
        let c = ExtractionResultWindowController(
            record: ExtractionRecord(items: StructuredItems(), markdown: markdown,
                                     focusRect: nil,
                                     version: ExtractionRecord.currentVersion),
            onReExtract: {})
        c.window?.orderFront(nil)
        c.window?.layoutIfNeeded()
        return c
    }

    /// The renderer clips table rows on purpose; the window must let them be
    /// reached. A row far wider than the window has to widen the text view
    /// beyond the visible clip — WITHOUT the test forcing layout. NSTextView
    /// lays out lazily, and an earlier version of this test called
    /// `ensureLayout` itself, which made it pass while the real window's
    /// scroller showed an empty track: only the app can force the layout the
    /// user's knob depends on.
    func test_wideTableRow_extendsBeyondTheClip_withoutForcedLayout() throws {
        // The wide row sits BELOW filler so lazy layout has a reason to skip it.
        let filler = (0..<80).map { "line \($0)" }.joined(separator: "\n\n")
        let wideRow = (0..<24).map { "Column\($0)Value" }.joined(separator: " | ")
        let controller = ExtractionResultWindowController(
            record: ExtractionRecord(items: StructuredItems(),
                                     markdown: filler + "\n\n| \(wideRow) |\n|---|\n| x |",
                                     focusRect: nil,
                                     version: ExtractionRecord.currentVersion),
            onReExtract: {})
        controller.window?.layoutIfNeeded()
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let root = try XCTUnwrap(controller.window?.contentView)
        let overflowing = textScrollViews(in: root).contains { scroll in
            guard let tv = scroll.documentView as? NSTextView else { return false }
            return tv.frame.width > scroll.contentView.bounds.width + 1
        }
        XCTAssertTrue(overflowing,
                      "a table row wider than the window must extend the text view past the clip without external ensureLayout")
    }
}
