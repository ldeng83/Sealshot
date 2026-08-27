import XCTest
import AppKit
@testable import Sealshot

final class SummaryLayoutTests: XCTestCase {

    private let font = NSFont.systemFont(ofSize: 12, weight: .regular)
    private let body = NSColor.secondaryLabelColor

    // MARK: parse

    func test_parse_overviewAndBullets() {
        let s = "Canadian passport (specimen).\n- Holder: Sarah Martin\n- Issued Ottawa, valid to 2023"
        let p = SummaryLayout.parse(s)
        XCTAssertEqual(p.overview, "Canadian passport (specimen).")
        XCTAssertEqual(p.bullets, ["Holder: Sarah Martin", "Issued Ottawa, valid to 2023"])
    }

    func test_parse_noBulletsIsSingleOverview() {
        let s = "A login screen with an email and password field."
        let p = SummaryLayout.parse(s)
        XCTAssertEqual(p.overview, s)
        XCTAssertTrue(p.bullets.isEmpty)
    }

    func test_parse_handlesBulletVariantsAndBlankLines() {
        let s = "Overview line.\n\n• first\n* second\n- third"
        let p = SummaryLayout.parse(s)
        XCTAssertEqual(p.overview, "Overview line.")
        XCTAssertEqual(p.bullets, ["first", "second", "third"])
    }

    // MARK: Markdown bold strip

    func test_stripMarkdownBold_removesMarkersAndReturnsRanges() {
        let (plain, ranges) = SummaryLayout.stripMarkdownBold("a **bold** word")
        XCTAssertEqual(plain, "a bold word")
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual((plain as NSString).substring(with: ranges[0]), "bold")
    }

    func test_stripMarkdownBold_noMarkers() {
        let (plain, ranges) = SummaryLayout.stripMarkdownBold("plain text")
        XCTAssertEqual(plain, "plain text")
        XCTAssertTrue(ranges.isEmpty)
    }

    func test_stripMarkdownBold_unbalancedLeavesAsIs() {
        let (plain, ranges) = SummaryLayout.stripMarkdownBold("a ** weird")
        XCTAssertEqual(plain, "a ** weird")
        XCTAssertTrue(ranges.isEmpty)
    }

    // MARK: compose

    func test_attributedSummary_stripsMarkersBoldNotColored() {
        let attr = SummaryLayout.attributedSummary(
            "**Key** point here.", tags: [], font: font,
            bodyColor: body, bulletColor: .tertiaryLabelColor, lineHeightMultiple: 1.30)
        // No literal asterisks survive.
        XCTAssertFalse(attr.string.contains("*"))
        // The emphasised word is semibold...
        let a0 = attr.attributes(at: 0, effectiveRange: nil)
        XCTAssertNotEqual(a0[.font] as? NSFont, font, "Markdown-bold should render semibold")
        // ...and the body colour is never changed to an accent.
        XCTAssertEqual(a0[.foregroundColor] as? NSColor, body)
        let mid = attr.attributes(at: attr.length - 2, effectiveRange: nil)
        XCTAssertEqual(mid[.foregroundColor] as? NSColor, body)
    }

    func test_attributedSummary_rendersBullets() {
        let attr = SummaryLayout.attributedSummary(
            "Overview.\n- one\n- two", tags: [], font: font,
            bodyColor: body, bulletColor: .tertiaryLabelColor, lineHeightMultiple: 1.30)
        XCTAssertTrue(attr.string.hasPrefix("Overview."))
        XCTAssertTrue(attr.string.contains("•\tone"))
        XCTAssertTrue(attr.string.contains("•\ttwo"))
    }
}
