import XCTest
import CoreGraphics
@testable import Sealshot

/// Pure window-selection rules for attributing a title to region/fullscreen
/// captures. All coordinates share one (AppKit-global) space.
final class BestWindowTests: XCTestCase {

    private func win(_ frame: CGRect, title: String?, app: String?,
                     ownApp: Bool = false, onScreen: Bool = true, normal: Bool = true) -> WindowDescriptor {
        WindowDescriptor(frame: frame, title: title, appName: app,
                         isOwnApp: ownApp, isOnScreen: onScreen, isNormalLayer: normal)
    }

    func testPicksGreatestOverlap() {
        let reference = CGRect(x: 0, y: 0, width: 100, height: 100)
        let small = win(CGRect(x: 0, y: 0, width: 20, height: 20), title: "Small", app: "A")
        let big = win(CGRect(x: 0, y: 0, width: 80, height: 80), title: "Big", app: "B")
        let best = bestWindow(reference: reference, candidates: [small, big])
        XCTAssertEqual(best?.title, "Big")
    }

    func testFrontWindowWinsOverlapTie() {
        // Candidates arrive front-to-back; on an overlap tie the front one wins.
        let reference = CGRect(x: 0, y: 0, width: 100, height: 100)
        let front = win(CGRect(x: 0, y: 0, width: 50, height: 50), title: "Front", app: "A")
        let back = win(CGRect(x: 0, y: 0, width: 50, height: 50), title: "Back", app: "B")
        let best = bestWindow(reference: reference, candidates: [front, back])
        XCTAssertEqual(best?.title, "Front")
    }

    func testFrontWindowWithMoreVisibleAreaBeatsLargerOccludedBackground() {
        // Terminal (front) covers most of the selection; a maximized browser
        // sits behind covering all of it. The browser's raw overlap is larger,
        // but it's occluded — the visible terminal must win.
        let reference = CGRect(x: 0, y: 0, width: 100, height: 100)
        let terminal = win(CGRect(x: 0, y: 0, width: 100, height: 70), title: "zsh", app: "Terminal")
        let browser = win(CGRect(x: 0, y: 0, width: 100, height: 100), title: "MFA Recovery vs Management", app: "Chrome")
        // front-to-back: terminal in front, browser behind.
        let best = bestWindow(reference: reference, candidates: [terminal, browser])
        XCTAssertEqual(best?.title, "zsh")
    }

    func testFrontWindowBeatsLargerBackgroundWindow() {
        // Regression: a maximized background app (Music) must not steal the
        // capture from the smaller browser window actually visible in front.
        let reference = CGRect(x: 0, y: 0, width: 100, height: 100)
        let browser = win(CGRect(x: 0, y: 0, width: 100, height: 100), title: "CIAM SP-Initiated SSO", app: "Chrome")
        let music = win(CGRect(x: 0, y: 0, width: 400, height: 400), title: "", app: "Music")
        let best = bestWindow(reference: reference, candidates: [browser, music])
        XCTAssertEqual(best?.title, "CIAM SP-Initiated SSO")
    }

    func testExcludesOwnAppWindow() {
        let reference = CGRect(x: 0, y: 0, width: 100, height: 100)
        let own = win(CGRect(x: 0, y: 0, width: 100, height: 100), title: "Sealshot Overlay", app: "Sealshot", ownApp: true)
        let other = win(CGRect(x: 0, y: 0, width: 10, height: 10), title: "Real", app: "Chrome")
        let best = bestWindow(reference: reference, candidates: [own, other])
        XCTAssertEqual(best?.title, "Real")
    }

    func testExcludesOffScreenAndNonNormal() {
        let reference = CGRect(x: 0, y: 0, width: 100, height: 100)
        let offscreen = win(CGRect(x: 0, y: 0, width: 90, height: 90), title: "Hidden", app: "A", onScreen: false)
        let menubar = win(CGRect(x: 0, y: 0, width: 90, height: 90), title: "Menu", app: "B", normal: false)
        let real = win(CGRect(x: 0, y: 0, width: 30, height: 30), title: "Real", app: "C")
        let best = bestWindow(reference: reference, candidates: [offscreen, menubar, real])
        XCTAssertEqual(best?.title, "Real")
    }

    func testNoOverlap_returnsNil() {
        let reference = CGRect(x: 0, y: 0, width: 100, height: 100)
        let far = win(CGRect(x: 500, y: 500, width: 50, height: 50), title: "Far", app: "A")
        XCTAssertNil(bestWindow(reference: reference, candidates: [far]))
    }

    func testEmptyCandidates_returnsNil() {
        XCTAssertNil(bestWindow(reference: CGRect(x: 0, y: 0, width: 10, height: 10), candidates: []))
    }
}
