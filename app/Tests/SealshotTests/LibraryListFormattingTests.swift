import XCTest
@testable import Sealshot

final class LibraryListFormattingTests: XCTestCase {
    func testDimensionsFormat() {
        XCTAssertEqual(LibraryListFormatting.dimensions(2560, 1440), "2560 × 1440")
    }
    func testDimensionsNilWhenZero() {
        XCTAssertNil(LibraryListFormatting.dimensions(0, 0))
        XCTAssertNil(LibraryListFormatting.dimensions(1920, 0))
    }
    func testSizeFormatNonEmpty() {
        XCTAssertFalse(LibraryListFormatting.size(2_400_000).isEmpty)
        XCTAssertEqual(LibraryListFormatting.size(0), "Zero KB")   // ByteCountFormatter .file
    }
}
