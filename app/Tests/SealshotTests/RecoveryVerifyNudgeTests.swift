import XCTest
@testable import Sealshot

/// Policy matrix for the periodic "verify your recovery code" nudge: due
/// when never verified, or verified >30 days ago, UNLESS snoozed within the
/// last 7 days (a snooze always wins over staleness while it's fresh).
final class RecoveryVerifyNudgeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000_000)

    func testNeverVerifiedIsDue() {
        XCTAssertTrue(RecoveryVerifyNudge.isDue(lastVerified: nil, lastSnoozed: nil, now: now))
    }

    func testVerifiedRecentlyIsNotDue() {
        let verified = now.addingTimeInterval(-29 * 86_400)
        XCTAssertFalse(RecoveryVerifyNudge.isDue(lastVerified: verified, lastSnoozed: nil, now: now))
    }

    func testVerifiedOver30DaysAgoIsDue() {
        let verified = now.addingTimeInterval(-31 * 86_400)
        XCTAssertTrue(RecoveryVerifyNudge.isDue(lastVerified: verified, lastSnoozed: nil, now: now))
    }

    func testStaleButSnoozedRecentlyIsNotDue() {
        let verified = now.addingTimeInterval(-31 * 86_400)
        let snoozed = now.addingTimeInterval(-3 * 86_400)
        XCTAssertFalse(RecoveryVerifyNudge.isDue(lastVerified: verified, lastSnoozed: snoozed, now: now))
    }

    func testStaleAndSnoozeExpiredIsDue() {
        let verified = now.addingTimeInterval(-31 * 86_400)
        let snoozed = now.addingTimeInterval(-8 * 86_400)
        XCTAssertTrue(RecoveryVerifyNudge.isDue(lastVerified: verified, lastSnoozed: snoozed, now: now))
    }

    func testVerifiedRecentlyWithOldSnoozeIsNotDue() {
        // A stale snooze must not resurrect the nudge once verification is fresh.
        let verified = now.addingTimeInterval(-10 * 86_400)
        let snoozed = now.addingTimeInterval(-100 * 86_400)
        XCTAssertFalse(RecoveryVerifyNudge.isDue(lastVerified: verified, lastSnoozed: snoozed, now: now))
    }

    // MARK: - The date shown in the sheet

    /// The sheet tells the user when the next check falls. That date must come
    /// from the same constant `isDue` uses, or the promise drifts from the
    /// behavior.
    func testNextCheckDateIsOneIntervalOut() {
        XCTAssertEqual(RecoveryVerifyNudge.nextCheckDate(from: now),
                       now.addingTimeInterval(RecoveryVerifyNudge.dueInterval))
    }

    func testNextCheckDateIsExactlyWhenTheNudgeComesBack() {
        let next = RecoveryVerifyNudge.nextCheckDate(from: now)
        // One second before the promised date it must still be quiet…
        XCTAssertFalse(RecoveryVerifyNudge.isDue(lastVerified: now, lastSnoozed: nil,
                                                 now: next.addingTimeInterval(-1)))
        // …and after it, due. Otherwise the sheet's stated date is a lie.
        XCTAssertTrue(RecoveryVerifyNudge.isDue(lastVerified: now, lastSnoozed: nil,
                                                now: next.addingTimeInterval(1)))
    }

    // MARK: - Rotation resets the clock

    /// Generating a new recovery code or replacing the key ends in the
    /// ceremony sheet, whose Done button stamps verification — a brand-new
    /// code must not read as "never verified" and nag immediately. This pins
    /// the stamping mechanism that button calls.
    @MainActor
    func testStampingVerificationSilencesTheNudgeForAFullInterval() {
        let defaults = UserDefaults(suiteName: "nudge-\(UUID().uuidString)")!
        RecoveryVerifyNudgeController.stampVerifiedNow(now: now, defaults: defaults)

        let controller = RecoveryVerifyNudgeController(defaults: defaults)
        let stamped = try! XCTUnwrap(controller.lastVerified)
        XCTAssertEqual(stamped.timeIntervalSince1970, now.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertFalse(RecoveryVerifyNudge.isDue(lastVerified: stamped, lastSnoozed: nil,
                                                 now: now.addingTimeInterval(29 * 86_400)))
        XCTAssertTrue(RecoveryVerifyNudge.isDue(lastVerified: stamped, lastSnoozed: nil,
                                                now: now.addingTimeInterval(31 * 86_400)))
    }
}
