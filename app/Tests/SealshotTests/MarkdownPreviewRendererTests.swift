import XCTest
import AppKit
@testable import Sealshot

@MainActor
final class MarkdownPreviewRendererTests: XCTestCase {

    func test_headingGetsLargerBoldFont() {
        let a = MarkdownPreviewRenderer.render("# Title")
        let font = a.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertNotNil(font)
        XCTAssertGreaterThan(font!.pointSize, 13)
        XCTAssertTrue(font!.fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertTrue(a.string.contains("Title"))
        XCTAssertFalse(a.string.contains("#"))
    }

    func test_bulletListRendersBullet() {
        let a = MarkdownPreviewRenderer.render("- item one")
        XCTAssertTrue(a.string.contains("•"))
        XCTAssertTrue(a.string.contains("item one"))
    }

    func test_boldInlineGetsBoldFont() {
        let a = MarkdownPreviewRenderer.render("a **bold** word")
        XCTAssertFalse(a.string.contains("*"))
        let r = (a.string as NSString).range(of: "bold")
        let font = a.attribute(.font, at: r.location, effectiveRange: nil) as? NSFont
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.bold) ?? false)
    }

    func test_plainTextPreserved() {
        let a = MarkdownPreviewRenderer.render("just text")
        XCTAssertTrue(a.string.contains("just text"))
    }

    func test_rendersMarkdownTable_notRawPipes() {
        let md = "| A | B |\n| --- | --- |\n| 1 | 2 |"
        let s = MarkdownPreviewRenderer.render(md).string
        XCTAssertTrue(s.contains("A")); XCTAssertTrue(s.contains("1"))
        XCTAssertFalse(s.contains("---"), "separator row should not appear literally")
        XCTAssertFalse(s.contains("| A |"), "raw pipe row should be reformatted")
    }

    func test_plainText_stripsMarkdown() {
        let s = MarkdownPreviewRenderer.plainText("# Title\n- item\n**bold**")
        XCTAssertFalse(s.contains("#"))
        XCTAssertFalse(s.contains("**"))
        XCTAssertTrue(s.contains("Title"))
        XCTAssertTrue(s.contains("item"))
    }
}
