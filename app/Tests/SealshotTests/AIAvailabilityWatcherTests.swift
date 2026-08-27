import XCTest
@testable import Sealshot

/// The pure compare-and-decide function behind `AIAvailabilityWatcher`:
/// whether a freshly observed `AIAvailability.status` is worth telling the
/// rest of the app about via `.aiAvailabilityDidChange`.
///
/// This is the only part of the watcher that is unit-testable — the
/// `NSApplication.didBecomeActiveNotification` wiring around it is a thin
/// shell with no logic of its own.
final class AIAvailabilityWatcherTests: XCTestCase {

    func test_unavailableToAvailable_posts() {
        XCTAssertTrue(AIAvailabilityWatcher.shouldPost(
            previous: .unavailable(.appleIntelligenceOff), current: .available),
            "Apple Intelligence coming back on is exactly the case this exists for")
    }

    func test_availableToUnavailable_posts() {
        XCTAssertTrue(AIAvailabilityWatcher.shouldPost(
            previous: .available, current: .unavailable(.appleIntelligenceOff)),
            "losing availability (e.g. turned off again) is just as much a change")
    }

    func test_unchangedAvailable_doesNotPost() {
        XCTAssertFalse(AIAvailabilityWatcher.shouldPost(previous: .available, current: .available),
                       "an ordinary app-switch with nothing changed must cost nothing")
    }

    func test_unchangedUnavailableSameReason_doesNotPost() {
        XCTAssertFalse(AIAvailabilityWatcher.shouldPost(
            previous: .unavailable(.appleIntelligenceOff),
            current: .unavailable(.appleIntelligenceOff)),
            "same reason, still unavailable — nothing for anyone to re-check")
    }

    /// The *reason* changing (still unavailable, but why differs) is still
    /// worth a post: `AINudgePolicy` shows different copy per reason.
    func test_unavailableReasonChanges_posts() {
        XCTAssertTrue(AIAvailabilityWatcher.shouldPost(
            previous: .unavailable(.modelNotReady),
            current: .unavailable(.appleIntelligenceOff)),
            "the displayed copy differs per reason, so a reason change must post")
    }

    /// No prior observation yet (fresh process / fresh watcher). There is
    /// nothing to compare against, so this is not a "change" — and treating
    /// it as one would post on the very first `didBecomeActive` of every
    /// launch (macOS fires that during ordinary startup), which every
    /// existing caller already covers via its own open/initial-load path.
    /// The first observation establishes the baseline silently; only a real
    /// transition after that should post.
    func test_firstObservation_doesNotPost() {
        XCTAssertFalse(AIAvailabilityWatcher.shouldPost(previous: nil, current: .available),
                       "first-ever observation is a baseline, not a change")
        XCTAssertFalse(AIAvailabilityWatcher.shouldPost(
            previous: nil, current: .unavailable(.appleIntelligenceOff)),
            "first-ever observation is a baseline, not a change, regardless of what it reads")
    }
}
