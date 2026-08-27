import XCTest
@testable import Sealshot

final class DisplayMenuBuilderTests: XCTestCase {

    private let displays = [
        DisplayDescriptor(index: 0, name: "Built-in", pixelWidth: 3024, pixelHeight: 1964),
        DisplayDescriptor(index: 1, name: "DELL U2720Q", pixelWidth: 3840, pixelHeight: 2160),
    ]

    func test_imageMenu_listsDisplaysThenAllDisplaysThenChoose() {
        let items = DisplayMenuBuilder.items(displays, allowAllDisplays: true)
        XCTAssertEqual(items, [.display(displays[0]), .display(displays[1]), .allDisplays, .chooseOnScreen])
    }

    func test_recordingMenu_omitsAllDisplays() {
        let items = DisplayMenuBuilder.items(displays, allowAllDisplays: false)
        XCTAssertEqual(items, [.display(displays[0]), .display(displays[1]), .chooseOnScreen])
    }

    func test_singleDisplay_stillHasChoose() {
        let items = DisplayMenuBuilder.items([displays[0]], allowAllDisplays: true)
        XCTAssertEqual(items, [.display(displays[0]), .allDisplays, .chooseOnScreen])
    }
}
