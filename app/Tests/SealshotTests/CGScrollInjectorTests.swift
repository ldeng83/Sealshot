import XCTest
import CoreGraphics
@testable import Sealshot

/// The auto-mode scroll-block tap swallows the user's input but must let our
/// OWN synthetic scroll through. The decision can't depend solely on the
/// `eventSourceUserData` tag — that custom field doesn't reliably survive a
/// post→tap round-trip on every macOS version, and when it's lost the tap
/// eats our own scroll (auto-scroll silently does nothing). Matching our own
/// process id is the robust fallback.
final class CGScrollInjectorTests: XCTestCase {

    private let ourPID: Int64 = 4321

    func test_taggedSyntheticScroll_passes() {
        XCTAssertTrue(CGScrollInjector.shouldPassThroughBlockTap(
            eventType: .scrollWheel,
            userData: CGScrollInjector.syntheticTag,
            sourcePID: 0, ourPID: ourPID))
    }

    func test_ourScrollWithoutTag_passesByPID() {
        // The tag was lost in transit, but the event still carries our PID.
        XCTAssertTrue(CGScrollInjector.shouldPassThroughBlockTap(
            eventType: .scrollWheel,
            userData: 0,
            sourcePID: ourPID, ourPID: ourPID),
            "our own synthetic scroll must pass even when the userData tag is lost")
    }

    func test_userScroll_isSwallowed() {
        // Hardware/user scroll: no tag, source is the window server (pid 0).
        XCTAssertFalse(CGScrollInjector.shouldPassThroughBlockTap(
            eventType: .scrollWheel,
            userData: 0,
            sourcePID: 0, ourPID: ourPID))
    }

    func test_mouseButton_isSwallowed() {
        XCTAssertFalse(CGScrollInjector.shouldPassThroughBlockTap(
            eventType: .leftMouseDown,
            userData: CGScrollInjector.syntheticTag,
            sourcePID: ourPID, ourPID: ourPID),
            "only scroll-wheel events pass; clicks are always swallowed")
    }

    func test_zeroOurPID_doesNotMatchEverything() {
        // Defensive: if our PID can't be determined (0), the PID rule must not
        // pass every pid-0 hardware event.
        XCTAssertFalse(CGScrollInjector.shouldPassThroughBlockTap(
            eventType: .scrollWheel,
            userData: 0,
            sourcePID: 0, ourPID: 0))
    }
}
