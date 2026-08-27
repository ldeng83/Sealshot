import XCTest
import UniformTypeIdentifiers
@testable import Sealshot

final class SealshareTypeTests: XCTestCase {
    func testPreferredExtension() {
        XCTAssertEqual(UTType.sealshare.preferredFilenameExtension, "sealshare")
    }

    func testConformsToData() {
        XCTAssertTrue(UTType.sealshare.conforms(to: .data))
    }
}
