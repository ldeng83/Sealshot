import XCTest
@testable import Sealshot

/// The still-capture content filters must exclude Sealshot's OWN windows so the
/// editor never appears (even as a translucent, mid-`orderOut` ghost) in a
/// capture. The app-matching predicate that decides which running apps to
/// exclude is the unit under test here; the SCContentFilter assembly itself is
/// a ScreenCaptureKit boundary verified in the GUI.
final class SelfExcludingContentFilterTests: XCTestCase {
    func test_isOwn_matchesSameBundleID() {
        XCTAssertTrue(SelfExcludingContentFilter.isOwn(
            candidateBundleID: "com.seal-shot.sealshot",
            ownBundleID: "com.seal-shot.sealshot"))
    }

    func test_isOwn_differentBundleID_false() {
        XCTAssertFalse(SelfExcludingContentFilter.isOwn(
            candidateBundleID: "com.apple.Safari",
            ownBundleID: "com.seal-shot.sealshot"))
    }

    func test_isOwn_nilOwnBundleID_false() {
        XCTAssertFalse(SelfExcludingContentFilter.isOwn(
            candidateBundleID: "com.seal-shot.sealshot", ownBundleID: nil))
    }

    func test_isOwn_nilCandidate_false() {
        XCTAssertFalse(SelfExcludingContentFilter.isOwn(
            candidateBundleID: nil, ownBundleID: "com.seal-shot.sealshot"))
    }
}
