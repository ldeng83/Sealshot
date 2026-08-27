import XCTest
@testable import Sealshot

/// Which point of the Live Text pipeline Find in Image joins when it is opened
/// from an already-running Live Text session.
///
/// Opening the panel sets `.waitingForEnhancementDecision`, and the tool-change
/// observer that would normally resolve it cannot run — the tool is already
/// `.textSelect`, so there is no transition. Anything this leaves unresolved
/// hangs the panel on "waiting for image scan" permanently, because
/// `imageTextSearchScanCanFinish` reads that stage as "not ready".
final class ImageTextSearchScanStageTests: XCTestCase {

    func test_enhancedBaseAlreadyShown_scansIt() {
        XCTAssertEqual(
            imageTextSearchScanStageOnEnteringSearch(
                showingEnhanced: true, hasEnhancedImage: true,
                enhanceSessionActive: true, enhanceRunning: false, liveTextHasText: true),
            .recognizingCurrentBase)
    }

    func test_enhancementStillRunning_waitsForIt() {
        // The enhanced base is about to replace what is on screen; scanning the
        // current one would produce boxes for pixels that are on their way out.
        XCTAssertEqual(
            imageTextSearchScanStageOnEnteringSearch(
                showingEnhanced: false, hasEnhancedImage: false,
                enhanceSessionActive: true, enhanceRunning: true, liveTextHasText: nil),
            .waitingForEnhancedOCR)
    }

    func test_liveTextFoundNoText_scansCurrentBase() {
        XCTAssertEqual(
            imageTextSearchScanStageOnEnteringSearch(
                showingEnhanced: false, hasEnhancedImage: false,
                enhanceSessionActive: true, enhanceRunning: false, liveTextHasText: false),
            .recognizingCurrentBase)
    }

    /// The case that hung: Live Text had already read the capture and FOUND
    /// text, with no enhancement pending. Every decision had been made, and the
    /// stage sat waiting for one anyway.
    func test_liveTextFoundText_scansCurrentBase() {
        XCTAssertEqual(
            imageTextSearchScanStageOnEnteringSearch(
                showingEnhanced: false, hasEnhancedImage: false,
                enhanceSessionActive: true, enhanceRunning: false, liveTextHasText: true),
            .recognizingCurrentBase)
    }

    /// Recognition still in flight is not a reason to wait HERE: the scan runs
    /// against the current base and reports "recognizing" until the layout
    /// lands, which resolves on its own.
    func test_recognitionInFlight_scansCurrentBase() {
        XCTAssertEqual(
            imageTextSearchScanStageOnEnteringSearch(
                showingEnhanced: false, hasEnhancedImage: false,
                enhanceSessionActive: true, enhanceRunning: false, liveTextHasText: nil),
            .recognizingCurrentBase)
    }

    /// No Live Text enhance session — the tool is transitioning, so the
    /// observer will seed the stage. Nothing to decide here.
    func test_noEnhanceSession_leavesTheStageAlone() {
        XCTAssertNil(
            imageTextSearchScanStageOnEnteringSearch(
                showingEnhanced: false, hasEnhancedImage: false,
                enhanceSessionActive: false, enhanceRunning: false, liveTextHasText: nil))
    }
}
