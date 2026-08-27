import XCTest
@testable import Sealshot

/// Imported files keep their original name ("<name> <timestamp>", Format A)
/// unless "include title & app in filename" is off, where they fall back to
/// timestamp-only like other captures — encryption no longer factors in.
final class ImportFilenameSubjectTests: XCTestCase {

    func test_includeTitleOn_keepsOriginalName() {
        XCTAssertEqual(
            CaptureConfig.importFilenameSubject("Balance Sheet", includeTitle: true),
            "Balance Sheet")
    }

    func test_includeTitleOff_dropsToTimestampOnly() {
        XCTAssertNil(
            CaptureConfig.importFilenameSubject("Balance Sheet", includeTitle: false))
    }
}
