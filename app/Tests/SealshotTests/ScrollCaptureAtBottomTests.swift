// app/Tests/SealshotTests/ScrollCaptureAtBottomTests.swift
import XCTest
@testable import Sealshot

private final class AtBottomInjector: ScrollInjecting, ScrollPositionReporting {
    var atBottom = false
    func parkPointer(atGlobal point: CGPoint) {}
    func scrollContentDown(points: Int) async {}
    var isAtBottom: Bool { atBottom }
}
private final class PlainInjector: ScrollInjecting {
    func parkPointer(atGlobal point: CGPoint) {}
    func scrollContentDown(points: Int) async {}
}

final class ScrollCaptureAtBottomTests: XCTestCase {
    func testReportsBottomWhenInjectorAtBottom() {
        let inj = AtBottomInjector(); inj.atBottom = true
        XCTAssertTrue(ScrollCaptureController.injectorReportsBottom(inj))
    }
    func testFalseWhenNotAtBottom() {
        let inj = AtBottomInjector(); inj.atBottom = false
        XCTAssertFalse(ScrollCaptureController.injectorReportsBottom(inj))
    }
    func testFalseForNonReportingInjector() {
        XCTAssertFalse(ScrollCaptureController.injectorReportsBottom(PlainInjector()))
    }
    func testFalseForNilInjector() {
        XCTAssertFalse(ScrollCaptureController.injectorReportsBottom(nil))
    }
}
