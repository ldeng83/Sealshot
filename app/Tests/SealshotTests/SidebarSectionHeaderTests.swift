import XCTest
import AppKit
@testable import Sealshot

@MainActor
final class SidebarSectionHeaderTests: XCTestCase {

    /// The header renders at the section-header font (10pt medium), set both via
    /// the attributed string AND as the field's default font.
    func test_rendersSectionHeaderFont() {
        let h = SidebarSectionHeader(text: "Summary")
        // Default font (fallback if attributes are ever dropped).
        XCTAssertEqual(h.font?.pointSize, Theme.sectionHeaderFont.pointSize)
        // Attributed-string font (what's actually drawn).
        let rendered = h.attributedStringValue.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertEqual(rendered?.pointSize, Theme.sectionHeaderFont.pointSize)
    }

    /// Regression: the header is a decorative label and must be click-through, so
    /// clicking it never reaches NSTextField/NSControl mouse handling (which used
    /// to reset the attributed styling to the system default 13pt font).
    func test_isClickThrough() {
        let h = SidebarSectionHeader(text: "Summary")
        h.frame = NSRect(x: 0, y: 0, width: 120, height: 20)
        XCTAssertNil(h.hitTest(NSPoint(x: 60, y: 10)), "section header should not intercept clicks")
    }
}
