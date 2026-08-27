import XCTest
@testable import Sealshot

final class WindowFilterTests: XCTestCase {

    private func candidate(
        id: UInt32 = 1,
        pid: pid_t = 9999,
        bundleID: String? = "com.example.app",
        isOnScreen: Bool = true,
        windowLayer: Int = 0,
        width: CGFloat = 800,
        height: CGFloat = 600
    ) -> WindowCandidate {
        WindowCandidate(
            windowID: id,
            owningPID: pid,
            owningBundleID: bundleID,
            isOnScreen: isOnScreen,
            windowLayer: windowLayer,
            frame: CGRect(x: 0, y: 0, width: width, height: height)
        )
    }

    func testDropsOwnPIDWindows() {
        let ours = candidate(id: 1, pid: 1234)
        let theirs = candidate(id: 2, pid: 5678)
        let result = filterPickerCandidates([ours, theirs], ownPID: 1234)
        XCTAssertEqual(result.map(\.windowID), [2])
    }

    func testDropsOffScreenWindows() {
        // SCK keeps minimized / hidden / recently-closed windows in its
        // list with cached frames; those would cause phantom highlights
        // over empty desktop regions. The Cmd+Tab-to-unminimize case still
        // works because macOS flips `isOnScreen` at the start of the
        // animation and the picker's 100ms poll picks it up in time.
        let onScreen = candidate(id: 1, isOnScreen: true)
        let offScreen = candidate(id: 2, isOnScreen: false)
        let result = filterPickerCandidates([onScreen, offScreen], ownPID: 1)
        XCTAssertEqual(result.map(\.windowID), [1])
    }

    func testDropsSubMinSizeWindows() {
        let big = candidate(id: 1, width: 800, height: 600)
        let tiny = candidate(id: 2, width: 99, height: 99)  // 99*99 = 9801 < 100*100 = 10000
        let result = filterPickerCandidates([big, tiny], ownPID: 1)
        XCTAssertEqual(result.map(\.windowID), [1])
    }

    func testDropsWindowServerOwnedWindows() {
        let app = candidate(id: 1, bundleID: "com.example.app")
        let server = candidate(id: 2, bundleID: "com.apple.WindowServer")
        let result = filterPickerCandidates([app, server], ownPID: 1)
        XCTAssertEqual(result.map(\.windowID), [1])
    }

    func testDropsNonZeroWindowLayer() {
        // Layer 0 = normal app windows. Anything else is popovers, tooltips,
        // status indicators, sheets — visually parts of "one window" the
        // user sees, but distinct SCWindows in SCK's list.
        let main = candidate(id: 1, windowLayer: 0)
        let popover = candidate(id: 2, windowLayer: 3)
        let tooltip = candidate(id: 3, windowLayer: 17)
        let result = filterPickerCandidates([main, popover, tooltip], ownPID: 1)
        XCTAssertEqual(result.map(\.windowID), [1])
    }

    func testKeepsNormalAppWindow() {
        let safari = candidate(
            id: 42,
            pid: 5678,
            bundleID: "com.apple.Safari",
            isOnScreen: true,
            width: 1280,
            height: 800
        )
        let result = filterPickerCandidates([safari], ownPID: 1234)
        XCTAssertEqual(result.map(\.windowID), [42])
    }
}
