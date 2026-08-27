import XCTest
@testable import Sealshot

/// `SupportNudgePolicy` decides WHEN the reminder is due; this is the other
/// half — whether the moment it comes due in is a decent one to use.
///
/// Those rules used to live inside a `DispatchQueue.main.asyncAfter` block and
/// read `NSApp` and a global coordinator directly, which made them untestable
/// and therefore unpinned. They are the code that decides whether a request for
/// money lands on top of someone's work, so they are worth pinning: every one
/// of the three vetoes is a way the reminder could become the interruption the
/// whole design exists to avoid.
@MainActor
final class SupportNudgeMomentTests: XCTestCase {

    func test_aQuietMomentIsTheOnlyOneThatPresents() {
        XCTAssertTrue(SupportNudge.shouldPresentNow(isBusy: false, isLocked: false, hasModal: false))
    }

    /// Mid-capture is precisely the interruption the settle delay exists to
    /// avoid — and the delay is long enough for the user to have started
    /// something new since the reminder came due.
    func test_busyVetoes() {
        XCTAssertFalse(SupportNudge.shouldPresentNow(isBusy: true, isLocked: false, hasModal: false))
    }

    /// Locked means the user is being asked for Touch ID. Asking for money on
    /// top of that is asking two things at once, and the wrong one first.
    func test_lockedVetoes() {
        XCTAssertFalse(SupportNudge.shouldPresentNow(isBusy: false, isLocked: true, hasModal: false))
    }

    /// Something else already owns the screen. Whatever it is, it is more
    /// urgent than this.
    func test_existingModalVetoes() {
        XCTAssertFalse(SupportNudge.shouldPresentNow(isBusy: false, isLocked: false, hasModal: true))
    }

    /// Any veto is enough on its own — the rule is an AND of three clear
    /// conditions, not a score.
    func test_anyVetoIsEnough() {
        for (busy, locked, modal) in [(true, true, false), (true, false, true),
                                      (false, true, true), (true, true, true)] {
            XCTAssertFalse(SupportNudge.shouldPresentNow(isBusy: busy, isLocked: locked,
                                                         hasModal: modal),
                           "busy=\(busy) locked=\(locked) modal=\(modal) must not present")
        }
    }
}
