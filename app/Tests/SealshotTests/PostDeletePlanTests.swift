import XCTest
@testable import Sealshot

/// `postDeletePlan` decides what the editor does after a strip deletion: does
/// the on-screen item (open image OR playing video) move, where to, and must
/// the open image's editor state be cleared. The video case is the bug fix —
/// a playing video is the current item even though it isn't `state.sourceURL`.
final class PostDeletePlanTests: XCTestCase {

    private func u(_ n: String) -> URL { URL(fileURLWithPath: "/shots/\(n)") }

    func test_openImageDeleted_switchesToNeighbor_andClears() {
        let order = [u("a.seal"), u("b.seal"), u("c.seal")]
        let plan = postDeletePlan(deleting: [u("a.seal")],
                                  openImage: u("a.seal"), playingVideo: nil, displayed: order)
        XCTAssertTrue(plan.switchNeeded)
        XCTAssertEqual(plan.switchTo, u("b.seal"))
        XCTAssertTrue(plan.clearOpenImage)
    }

    func test_playingVideoDeleted_switchesToNeighbor_keepsOpenImage() {
        let order = [u("img.seal"), u("clip.mov"), u("b.seal")]
        let plan = postDeletePlan(deleting: [u("clip.mov")],
                                  openImage: u("img.seal"), playingVideo: u("clip.mov"), displayed: order)
        XCTAssertTrue(plan.switchNeeded)
        XCTAssertEqual(plan.switchTo, u("b.seal"))
        XCTAssertFalse(plan.clearOpenImage)
    }

    func test_playingVideoDeleted_noOpenImage_stillSwitches() {
        let order = [u("clip.mov"), u("b.seal")]
        let plan = postDeletePlan(deleting: [u("clip.mov")],
                                  openImage: nil, playingVideo: u("clip.mov"), displayed: order)
        XCTAssertTrue(plan.switchNeeded)
        XCTAssertEqual(plan.switchTo, u("b.seal"))
        XCTAssertFalse(plan.clearOpenImage)
    }

    func test_deletingNonCurrentItem_noSwitch() {
        let order = [u("open.seal"), u("other.seal"), u("clip.mov")]
        let plan = postDeletePlan(deleting: [u("other.seal")],
                                  openImage: u("open.seal"), playingVideo: u("clip.mov"), displayed: order)
        XCTAssertFalse(plan.switchNeeded)
        XCTAssertNil(plan.switchTo)
        XCTAssertFalse(plan.clearOpenImage)
    }

    func test_videoCurrent_butOpenImageAlsoDeleted_clears() {
        let order = [u("img.seal"), u("clip.mov"), u("b.seal")]
        let plan = postDeletePlan(deleting: [u("img.seal"), u("clip.mov")],
                                  openImage: u("img.seal"), playingVideo: u("clip.mov"), displayed: order)
        XCTAssertTrue(plan.switchNeeded)
        XCTAssertEqual(plan.switchTo, u("b.seal"))
        XCTAssertTrue(plan.clearOpenImage)
    }

    func test_openImageDeleted_videoStillPlaying_clearsButNoSwitch() {
        // The user is watching a video; the underlying open image gets deleted
        // but the video isn't. Keep playing (no switch) yet clear the image so
        // its autosave can't resurrect it.
        let order = [u("img.seal"), u("clip.mov")]
        let plan = postDeletePlan(deleting: [u("img.seal")],
                                  openImage: u("img.seal"), playingVideo: u("clip.mov"), displayed: order)
        XCTAssertFalse(plan.switchNeeded)
        XCTAssertNil(plan.switchTo)
        XCTAssertTrue(plan.clearOpenImage)
    }

    func test_currentDeleted_nothingLeft_switchNeededButNilTarget() {
        let order = [u("a.seal")]
        let plan = postDeletePlan(deleting: [u("a.seal")],
                                  openImage: u("a.seal"), playingVideo: nil, displayed: order)
        XCTAssertTrue(plan.switchNeeded)
        XCTAssertNil(plan.switchTo)
        XCTAssertTrue(plan.clearOpenImage)
    }

    func test_noCurrentItem_noSwitch() {
        let order = [u("a.seal")]
        let plan = postDeletePlan(deleting: [u("a.seal")],
                                  openImage: nil, playingVideo: nil, displayed: order)
        XCTAssertFalse(plan.switchNeeded)
        XCTAssertNil(plan.switchTo)
        XCTAssertFalse(plan.clearOpenImage)
    }
}
