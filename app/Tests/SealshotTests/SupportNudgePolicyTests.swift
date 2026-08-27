import XCTest
@testable import Sealshot

/// When the support reminder is allowed to appear.
///
/// This is the whole of the business model's manners, and it is the kind of rule
/// that is otherwise verified by running the app for thirty days and hoping. The
/// asymmetry to keep in mind while reading: a reminder that fails to appear
/// costs a sale, a reminder that appears too often costs a user.
final class SupportNudgePolicyTests: XCTestCase {

    private let now = UTCDay.parse("2026-09-01")!
    private func daysAgo(_ n: Int) -> Date { now.addingTimeInterval(-Double(n) * 86_400) }

    private func inputs(firstRunAt: Date? = nil,
                        captures: Int = 0,
                        lastAsked: Date? = nil,
                        supported: Bool = false) -> SupportNudgePolicy.Inputs {
        .init(firstRunAt: firstRunAt, captureCount: captures,
              lastAskedAt: lastAsked, isSupported: supported, now: now)
    }

    // MARK: The thing a license buys

    func test_supported_isNeverAsked_howeverOldOrBusyTheInstall() {
        XCTAssertFalse(SupportNudgePolicy.isDue(
            inputs(firstRunAt: daysAgo(900), captures: 10_000, supported: true)),
            "paying turns it off — that is the entire transaction")
    }

    // MARK: Earning the ask

    func test_newInstall_isNotAsked() {
        XCTAssertFalse(SupportNudgePolicy.isDue(inputs(firstRunAt: daysAgo(1), captures: 3)))
    }

    func test_theDayBeforeTheThreshold_isNotAsked() {
        XCTAssertFalse(SupportNudgePolicy.isDue(inputs(firstRunAt: daysAgo(29))))
    }

    func test_atThirtyDays_isAsked() {
        XCTAssertTrue(SupportNudgePolicy.isDue(inputs(firstRunAt: daysAgo(30))))
    }

    /// Heavy use counts as much as elapsed time: someone who took 100 captures
    /// in a fortnight has had the value, and waiting out the calendar would be
    /// pedantry.
    func test_heavyUseEarnsTheAskBeforeThirtyDays() {
        XCTAssertFalse(SupportNudgePolicy.isDue(inputs(firstRunAt: daysAgo(3), captures: 99)))
        XCTAssertTrue(SupportNudgePolicy.isDue(inputs(firstRunAt: daysAgo(3), captures: 100)))
    }

    /// A missing stamp reads as day zero, not as "infinitely old". Failing the
    /// other way would greet a fresh install — or anyone whose stamps were
    /// wiped — with a request for money on their first capture.
    func test_missingFirstRunStamp_failsQuiet() {
        XCTAssertFalse(SupportNudgePolicy.isDue(inputs(firstRunAt: nil, captures: 5)))
        XCTAssertTrue(SupportNudgePolicy.isDue(inputs(firstRunAt: nil, captures: 100)),
                      "use alone still earns it")
    }

    // MARK: Cadence

    func test_askedYesterday_isNotAskedAgain() {
        XCTAssertFalse(SupportNudgePolicy.isDue(
            inputs(firstRunAt: daysAgo(400), captures: 5_000, lastAsked: daysAgo(1))))
    }

    func test_thirteenDaysOn_stillWaits_fourteenAsks() {
        XCTAssertFalse(SupportNudgePolicy.isDue(
            inputs(firstRunAt: daysAgo(400), lastAsked: daysAgo(13))))
        XCTAssertTrue(SupportNudgePolicy.isDue(
            inputs(firstRunAt: daysAgo(400), lastAsked: daysAgo(14))))
    }

    /// A clock moved backwards (travel, a manual date change, a dead PRAM
    /// battery) makes `now - lastAsked` negative. That must not read as "long
    /// enough ago" and turn the reminder into a nag on every capture.
    func test_clockMovedBackwards_doesNotUnlockAnEarlyAsk() {
        let future = now.addingTimeInterval(30 * 86_400)
        XCTAssertFalse(SupportNudgePolicy.isDue(
            inputs(firstRunAt: daysAgo(400), lastAsked: future)))
    }

    // MARK: The honor flag

    /// "I've donated" is the honor system's entire mechanism, so its store
    /// behavior is worth pinning: set → acknowledged, withdraw → asked again.
    @MainActor func test_acknowledgement_setsAndWithdraws() {
        let suite = "SupportNudgePolicyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SupportNudgeStore(defaults: defaults)

        XCTAssertFalse(store.isAcknowledged)
        store.acknowledge(now: now)
        XCTAssertTrue(store.isAcknowledged)
        XCTAssertEqual(store.acknowledgedAt, now)
        store.withdrawAcknowledgement()
        XCTAssertFalse(store.isAcknowledged, "unticking the box brings the ask back")
    }

    /// The cadence gate sits AFTER the earned gate: a license that lapses does
    /// not get to skip the fortnight because the last ask was long ago… but it
    /// does come back, which is what keeps a renewal worth buying.
    func test_lapsedSupporter_isAskedAgainOnTheNormalCadence() {
        XCTAssertTrue(SupportNudgePolicy.isDue(
            inputs(firstRunAt: daysAgo(400), lastAsked: daysAgo(20), supported: false)))
    }
}
