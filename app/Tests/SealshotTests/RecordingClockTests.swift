import XCTest
import CoreMedia
@testable import Sealshot

final class RecordingClockTests: XCTestCase {
    private func t(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 600) }

    func test_beforePause_outputEqualsElapsedFromStart() {
        let clock = RecordingClock(start: t(10))
        XCTAssertEqual(clock.outputTime(for: t(12))?.seconds ?? -1, 2, accuracy: 0.001)
    }

    func test_pausedGapIsExcluded() {
        var clock = RecordingClock(start: t(10))
        _ = clock.outputTime(for: t(12))   // 2s in
        clock.pause(at: t(12))
        clock.resume(at: t(20))            // 8s paused
        // 1s after resume → output should be 3s, not 11s
        XCTAssertEqual(clock.outputTime(for: t(21))?.seconds ?? -1, 3, accuracy: 0.001)
    }

    func test_samplesDuringPauseAreDropped() {
        var clock = RecordingClock(start: t(10))
        clock.pause(at: t(12))
        XCTAssertNil(clock.outputTime(for: t(15)))  // nil = drop this sample
    }

    func test_multiplePausesAccumulate() {
        var clock = RecordingClock(start: t(0))
        clock.pause(at: t(2)); clock.resume(at: t(5))    // +3s paused
        clock.pause(at: t(8)); clock.resume(at: t(12))   // +4s paused (7s total)
        // 13s source, 7s paused → 6s of output.
        XCTAssertEqual(clock.outputTime(for: t(13))?.seconds ?? -1, 6, accuracy: 0.001)
    }

    func test_pauseWhileAlreadyPausedIsIgnored() {
        var clock = RecordingClock(start: t(0))
        clock.pause(at: t(2))
        clock.pause(at: t(4))      // ignored — original pause time stands
        clock.resume(at: t(6))     // 4s paused (from t2), not 2s
        XCTAssertEqual(clock.outputTime(for: t(7))?.seconds ?? -1, 3, accuracy: 0.001)
    }

    func test_resumeWithoutPauseIsNoOp() {
        var clock = RecordingClock(start: t(0))
        clock.resume(at: t(5))     // no prior pause → nothing changes
        XCTAssertFalse(clock.isPaused)
        XCTAssertEqual(clock.outputTime(for: t(8))?.seconds ?? -1, 8, accuracy: 0.001)
    }
}
