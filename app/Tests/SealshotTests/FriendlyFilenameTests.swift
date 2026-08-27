import XCTest
@testable import Sealshot

final class FriendlyFilenameTests: XCTestCase {
    func testSanitizesUnsafeChars() {
        XCTAssertEqual(FriendlyFilename.sanitize("SAML Error: InvalidNameIDPolicy"),
                       "SAML Error - InvalidNameIDPolicy")
    }
    func testCollapsesAndTrims() {
        XCTAssertEqual(FriendlyFilename.sanitize("  Stripe   Payment  "), "Stripe Payment")
    }
    func testEmptyFallsBackToScreenshot() {
        XCTAssertEqual(FriendlyFilename.sanitize("  "), "Screenshot")
    }

    func testStripsDecorativeSymbol() {
        // ✳ is U+2733 (a symbol), not ASCII '*'.
        XCTAssertEqual(FriendlyFilename.sanitize("✳ Claude Code"), "Claude Code")
    }

    func testStripsEmoji() {
        XCTAssertEqual(FriendlyFilename.sanitize("Report 📊 final"), "Report final")
    }

    func testStripsAsteriskAndOtherNonStructuralIllegals() {
        XCTAssertEqual(FriendlyFilename.sanitize("a*b?c%d"), "abcd")
    }

    func testKeepsLettersDigitsSpacesAndBasicPunctuation() {
        XCTAssertEqual(FriendlyFilename.sanitize("Q3 report (final), v2"), "Q3 report (final), v2")
    }

    func testEmptyAfterStrippingSymbols_returnsScreenshot() {
        XCTAssertEqual(FriendlyFilename.sanitize("✳✳✳"), "Screenshot")
    }
}
