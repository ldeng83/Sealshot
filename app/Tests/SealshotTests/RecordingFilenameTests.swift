import XCTest
@testable import Sealshot

final class RecordingFilenameTests: XCTestCase {
    func test_usesFormatExtension() {
        let name = RecordingFilename.make(stamp: "2026-06-13 at 4_05_06 PM",
                                          format: .hevcMov, exists: { _ in false })
        XCTAssertEqual(name, "2026-06-13 at 4_05_06 PM.mov")
    }
    func test_deCollidesOnConflict() {
        let taken: Set<String> = ["Rec.mov", "Rec 2.mov"]
        let name = RecordingFilename.make(stamp: "Rec", format: .hevcMov,
                                          exists: { taken.contains($0) })
        XCTAssertEqual(name, "Rec 3.mov")
    }
}
