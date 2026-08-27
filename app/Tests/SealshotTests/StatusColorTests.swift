import XCTest
import SwiftUI
@testable import Sealshot

final class StatusColorTests: XCTestCase {
    func testDistinctColorsPerStatus() {
        XCTAssertEqual(statusColor(.new), Color.accentColor)
        XCTAssertEqual(statusColor(.reviewed), Color.green)
        XCTAssertEqual(statusColor(.archived), Color.gray)
    }
}
