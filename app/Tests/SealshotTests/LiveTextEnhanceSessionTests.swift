import XCTest
import CoreGraphics
@testable import Sealshot

/// Live Text auto-enhance session: invoking the Live Text tool shows the
/// enhanced base (generating it if needed) so OCR reads reconstructed glyphs;
/// leaving the tool restores the user's prior original/enhanced choice.
@MainActor
final class LiveTextEnhanceSessionTests: XCTestCase {

    private func img(_ w: Int = 4) -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: w, height: w, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    private func makeState(enhanced: CGImage? = nil, showing: Bool = false) -> EditorState {
        EditorState(sourceImage: img(), sourceURL: nil,
                    enhancedImage: enhanced, showingEnhanced: showing)
    }

    func test_begin_enhancedAlreadyShowing_startsNoSession() {
        let s = makeState(enhanced: img(8), showing: true)
        XCTAssertEqual(s.beginLiveTextEnhanceSession(), .none)
        XCTAssertFalse(s.endLiveTextEnhanceSession())
        XCTAssertTrue(s.showingEnhanced, "user's own enhanced view must survive")
    }

    func test_begin_cachedEnhancedHidden_showsItAndEndRestores() {
        let s = makeState(enhanced: img(8), showing: false)
        XCTAssertEqual(s.beginLiveTextEnhanceSession(), .showedExisting)
        XCTAssertTrue(s.showingEnhanced)
        XCTAssertFalse(s.persistedShowingEnhanced,
                       "mid-session saves must persist the user's pre-session value")
        XCTAssertFalse(s.endLiveTextEnhanceSession(), "cached image → nothing to cancel")
        XCTAssertFalse(s.showingEnhanced, "prior visibility restored")
        XCTAssertTrue(s.persistedShowingEnhanced == s.showingEnhanced)
    }

    func test_begin_noEnhanced_requestsGeneration_endCancelsWhileAwaiting() {
        let s = makeState()
        XCTAssertEqual(s.beginLiveTextEnhanceSession(), .needsGeneration)
        XCTAssertTrue(s.endLiveTextEnhanceSession(), "still awaiting generation → cancel it")
        XCTAssertFalse(s.showingEnhanced)
    }

    func test_generationCompletesDuringSession_endRestoresOffKeepsCache() {
        let s = makeState()
        XCTAssertEqual(s.beginLiveTextEnhanceSession(), .needsGeneration)
        // What the enhance pipeline does on success:
        s.enhancedImage = img(8)
        s.showingEnhanced = true
        XCTAssertFalse(s.persistedShowingEnhanced)
        XCTAssertFalse(s.endLiveTextEnhanceSession(), "generation finished → nothing to cancel")
        XCTAssertFalse(s.showingEnhanced, "reverted to pre-session OFF")
        XCTAssertNotNil(s.enhancedImage, "generated image stays cached for next time")
    }

    func test_begin_isIdempotentWithinASession() {
        let s = makeState(enhanced: img(8), showing: false)
        XCTAssertEqual(s.beginLiveTextEnhanceSession(), .showedExisting)
        XCTAssertEqual(s.beginLiveTextEnhanceSession(), .none)
        s.endLiveTextEnhanceSession()
        XCTAssertFalse(s.showingEnhanced)
    }

    func test_end_withoutSession_isNoOp() {
        let s = makeState(enhanced: img(8), showing: false)
        XCTAssertFalse(s.endLiveTextEnhanceSession())
        XCTAssertFalse(s.showingEnhanced)
    }

    func test_readOnlyCapture_neverStartsASession() {
        let s = makeState()
        s.isReadOnly = true
        XCTAssertEqual(s.beginLiveTextEnhanceSession(), .none)
        XCTAssertFalse(s.showingEnhanced)
    }

    func test_persistedShowingEnhanced_matchesLiveValueOutsideSessions() {
        let s = makeState(enhanced: img(8), showing: true)
        XCTAssertTrue(s.persistedShowingEnhanced)
        s.showingEnhanced = false
        XCTAssertFalse(s.persistedShowingEnhanced)
    }

    // MARK: - Progress label

    // Live Text runs recognize → auto-enhance → recognize. The label must read
    // "Initializing…" only while the enhanced base the second pass needs does
    // not exist yet, so the sequence reads Initializing → Enhancing →
    // Recognizing rather than showing "Recognizing" twice.

    func test_progressLabel_initializing_whileTheEnhancedBaseIsStillMissing() {
        let s = makeState(enhanced: nil, showing: false)
        XCTAssertEqual(s.beginLiveTextEnhanceSession(), .needsGeneration)
        XCTAssertEqual(s.liveTextProgressLabel, "Initializing…")
    }

    func test_progressLabel_recognizing_onceTheEnhancedBaseIsShowing() {
        let s = makeState(enhanced: img(8), showing: false)
        XCTAssertEqual(s.beginLiveTextEnhanceSession(), .showedExisting)
        XCTAssertEqual(s.liveTextProgressLabel, "Recognizing text…")
    }

    func test_progressLabel_recognizing_whenNoEnhanceSessionIsRunning() {
        // Read-only captures and plain re-recognition never open a session.
        let s = makeState(enhanced: nil, showing: false)
        XCTAssertEqual(s.liveTextProgressLabel, "Recognizing text…")
    }

    // MARK: - Cancelling a read

    // Cancel leaves the tool: text-select with no recognized layout is a dead
    // tool, and staying in it risks the next state change re-triggering the
    // very recognition the user just cancelled.

    func test_cancelLiveTextRead_leavesTheToolAndRestoresTheUsersBase() {
        let s = makeState(enhanced: img(8), showing: false)
        s.selectedTool = .textSelect
        XCTAssertEqual(s.beginLiveTextEnhanceSession(), .showedExisting)
        XCTAssertTrue(s.showingEnhanced)

        XCTAssertFalse(s.cancelLiveTextRead(), "cached image → nothing to cancel")
        XCTAssertEqual(s.selectedTool, .select)
        XCTAssertFalse(s.showingEnhanced, "pre-session base restored")
    }

    func test_cancelLiveTextRead_reportsAnEnhanceStillGenerating() {
        let s = makeState(enhanced: nil, showing: false)
        s.selectedTool = .textSelect
        XCTAssertEqual(s.beginLiveTextEnhanceSession(), .needsGeneration)

        XCTAssertTrue(s.cancelLiveTextRead(),
                      "an in-flight generation must be reported so the caller cancels it")
        XCTAssertEqual(s.selectedTool, .select)
    }

    func test_cancelLiveTextRead_withoutASession_stillLeavesTheTool() {
        // Re-recognition of an already-enhanced capture opens no session.
        let s = makeState(enhanced: img(8), showing: true)
        s.selectedTool = .textSelect
        XCTAssertEqual(s.beginLiveTextEnhanceSession(), .none)

        XCTAssertFalse(s.cancelLiveTextRead())
        XCTAssertEqual(s.selectedTool, .select)
        XCTAssertTrue(s.showingEnhanced, "the user's own enhanced view must survive")
    }

    // MARK: - Holding the canvas off a base that is about to be replaced

    func test_endingTheSession_releasesTheCanvas() {
        // Left set, `ensureRecognition` returns early forever and Live Text
        // never reads anything for this capture again.
        let s = makeState(enhanced: nil, showing: false)
        s.selectedTool = .textSelect
        XCTAssertEqual(s.beginLiveTextEnhanceSession(), .needsGeneration)
        s.liveTextAwaitingEnhancement = true

        XCTAssertTrue(s.endLiveTextEnhanceSession())
        XCTAssertFalse(s.liveTextAwaitingEnhancement)
    }

    func test_cancellingTheRead_releasesTheCanvas() {
        let s = makeState(enhanced: nil, showing: false)
        s.selectedTool = .textSelect
        XCTAssertEqual(s.beginLiveTextEnhanceSession(), .needsGeneration)
        s.liveTextAwaitingEnhancement = true

        XCTAssertTrue(s.cancelLiveTextRead())
        XCTAssertFalse(s.liveTextAwaitingEnhancement)
        XCTAssertEqual(s.selectedTool, .select, "cancelling the enhance cancels the whole read")
        XCTAssertFalse(s.showingEnhanced, "pre-session base restored")
    }

    func test_awaitingEnhancement_defaultsOff() {
        // Every path that does NOT enhance — no text found, no Neural Engine,
        // a cached enhanced base — must leave the canvas free to read now.
        let s = makeState(enhanced: img(8), showing: false)
        XCTAssertFalse(s.liveTextAwaitingEnhancement)
        XCTAssertEqual(s.beginLiveTextEnhanceSession(), .showedExisting)
        XCTAssertFalse(s.liveTextAwaitingEnhancement,
                       "a cached base is already there — nothing to wait for")
    }
}
