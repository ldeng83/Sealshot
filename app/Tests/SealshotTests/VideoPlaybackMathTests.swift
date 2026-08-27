import XCTest
@testable import Sealshot

/// Pure transport math behind the custom in-canvas video controls: time
/// labels, scrubber fraction ↔ time mapping, playback-speed cycling, and seek
/// clamping. Kept free of AVFoundation/AppKit so the fiddly bits are testable.
final class VideoPlaybackMathTests: XCTestCase {

    func test_timeLabel_minutesSeconds() {
        XCTAssertEqual(VideoPlaybackMath.timeLabel(0), "0:00")
        XCTAssertEqual(VideoPlaybackMath.timeLabel(5), "0:05")
        XCTAssertEqual(VideoPlaybackMath.timeLabel(42), "0:42")
        XCTAssertEqual(VideoPlaybackMath.timeLabel(195), "3:15")
    }

    func test_timeLabel_hoursWhenLong() {
        XCTAssertEqual(VideoPlaybackMath.timeLabel(3725), "1:02:05")  // 1h 2m 5s
    }

    func test_timeLabel_clampsNegativeAndNaN() {
        XCTAssertEqual(VideoPlaybackMath.timeLabel(-3), "0:00")
        XCTAssertEqual(VideoPlaybackMath.timeLabel(.nan), "0:00")
        XCTAssertEqual(VideoPlaybackMath.timeLabel(.infinity), "0:00")
    }

    func test_fractionAndTime_areInverse() {
        XCTAssertEqual(VideoPlaybackMath.fraction(forTime: 30, duration: 120), 0.25, accuracy: 1e-9)
        XCTAssertEqual(VideoPlaybackMath.time(forFraction: 0.25, duration: 120), 30, accuracy: 1e-9)
    }

    func test_fraction_zeroDuration_isZero_noNaN() {
        XCTAssertEqual(VideoPlaybackMath.fraction(forTime: 10, duration: 0), 0)
    }

    func test_fraction_clampsOutOfRange() {
        XCTAssertEqual(VideoPlaybackMath.fraction(forTime: -5, duration: 120), 0)
        XCTAssertEqual(VideoPlaybackMath.fraction(forTime: 999, duration: 120), 1)
    }

    func test_clampedSeek_staysInBounds() {
        XCTAssertEqual(VideoPlaybackMath.clampedSeek(-10, duration: 120), 0, accuracy: 1e-9)
        XCTAssertEqual(VideoPlaybackMath.clampedSeek(200, duration: 120), 120, accuracy: 1e-9)
        XCTAssertEqual(VideoPlaybackMath.clampedSeek(50, duration: 120), 50, accuracy: 1e-9)
    }

    func test_speedCycle_wrapsThroughPresets() {
        XCTAssertEqual(VideoPlaybackMath.speeds.first, 0.5)
        XCTAssertEqual(VideoPlaybackMath.nextSpeed(after: 1.0), 1.25)
        XCTAssertEqual(VideoPlaybackMath.nextSpeed(after: 2.0), 0.5)        // wraps
        XCTAssertEqual(VideoPlaybackMath.nextSpeed(after: 0.9), 1.0)        // nearest-then-next for off-grid
    }

    func test_speedLabel_trimsTrailingZeros() {
        XCTAssertEqual(VideoPlaybackMath.speedLabel(1.0), "1×")
        XCTAssertEqual(VideoPlaybackMath.speedLabel(1.25), "1.25×")
        XCTAssertEqual(VideoPlaybackMath.speedLabel(0.5), "0.5×")
    }
}
