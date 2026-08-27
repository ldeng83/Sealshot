import AppKit
import XCTest
@testable import Sealshot

/// The results window offers two views of one record: "Text" (the rendered
/// preview) and "Markdown" (the raw source it renders from), switched by a
/// segmented control at the top centre.
@MainActor
final class ExtractionResultWindowTabsTests: XCTestCase {

    private let markdown = "| A | B |\n|---|---|\n| 1 | 2 |"

    private func makeShown() -> ExtractionResultWindowController {
        let c = ExtractionResultWindowController(
            record: ExtractionRecord(items: StructuredItems(), markdown: markdown,
                                     focusRect: nil,
                                     version: ExtractionRecord.currentVersion),
            onReExtract: {})
        c.window?.orderFront(nil)
        c.window?.layoutIfNeeded()
        return c
    }

    private func find<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
        var found: [T] = []
        var queue: [NSView] = [root]
        while let v = queue.popLast() {
            if let match = v as? T { found.append(match) }
            queue.append(contentsOf: v.subviews)
        }
        return found
    }

    func test_tabGroup_isTextAndMarkdown() throws {
        let c = makeShown(); defer { c.close() }
        let root = try XCTUnwrap(c.window?.contentView)
        let seg = try XCTUnwrap(find(NSSegmentedControl.self, in: root).first)
        XCTAssertEqual(seg.segmentCount, 2)
        XCTAssertEqual(seg.label(forSegment: 0), "Text")
        XCTAssertEqual(seg.label(forSegment: 1), "Markdown")
        XCTAssertEqual(seg.selectedSegment, 0, "the rendered Text view is the default")
    }

    func test_tabGroup_isHorizontallyCentred() throws {
        let c = makeShown(); defer { c.close() }
        let root = try XCTUnwrap(c.window?.contentView)
        let seg = try XCTUnwrap(find(NSSegmentedControl.self, in: root).first)
        let inRoot = seg.convert(seg.bounds, to: root)
        XCTAssertEqual(inRoot.midX, root.bounds.midX, accuracy: 2,
                       "tab group must sit at the top centre")
        XCTAssertLessThan(inRoot.minY == 0 ? inRoot.maxY : root.bounds.height - inRoot.maxY + inRoot.height, 60,
                          "tab group must be in the header region")
    }

    func test_markdownTab_showsTheRawSource() throws {
        let c = makeShown(); defer { c.close() }
        let root = try XCTUnwrap(c.window?.contentView)
        let seg = try XCTUnwrap(find(NSSegmentedControl.self, in: root).first)
        seg.selectedSegment = 1
        seg.performClick(nil)   // fires the target action like a user click

        let sourceShown = find(NSTextView.self, in: root)
            .contains { $0.string == markdown && !$0.isHiddenOrHasHiddenAncestor }
        XCTAssertTrue(sourceShown, "Markdown tab must display the record's raw markdown")
    }

    /// The rendered Text view must NOT show pipe syntax — that's what the
    /// Markdown tab is for.
    func test_textTab_showsRenderedContentNotSyntax() throws {
        let c = makeShown(); defer { c.close() }
        let root = try XCTUnwrap(c.window?.contentView)
        let visible = find(NSTextView.self, in: root)
            .filter { !$0.isHiddenOrHasHiddenAncestor && !$0.string.isEmpty }
        XCTAssertFalse(visible.isEmpty)
        XCTAssertFalse(visible.contains { $0.string.contains("|---|") },
                       "default tab must show the rendered table, not markdown syntax")
    }
}
