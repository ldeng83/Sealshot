import XCTest
@testable import Sealshot

@MainActor
final class RelockIdleTests: XCTestCase {
    /// `idleSeconds` is the injected system-wide HID idle time (seconds since
    /// the last keyboard/mouse input anywhere on the Mac), and `busy` is the
    /// injected capture/recording-in-flight flag.
    private func make(minutes: Int,
                      idleSeconds: @escaping () -> TimeInterval,
                      busy: @escaping () -> Bool = { false },
                      enabled: @escaping () -> Bool = { true },
                      locked: @escaping () -> Void = {}) -> RelockController {
        let d = UserDefaults(suiteName: "idle-\(UUID().uuidString)")!
        let pref = IdleLockPreference(defaults: d)
        pref.minutes = minutes
        return RelockController(isEnabledAndUnlocked: enabled, lock: locked,
                                idlePref: pref, isBusy: busy,
                                systemIdleSeconds: idleSeconds)
    }

    func testNoLockWhenIdleDisabled() {
        // minutes == 0 disables idle-lock regardless of how long the Mac is idle.
        let c = make(minutes: 0, idleSeconds: { 99_999 },
                     locked: { XCTFail("must not lock") })
        XCTAssertFalse(c.shouldLockForIdle())
    }

    func testLocksAfterIdleExceedsInterval() {
        var idle: TimeInterval = 0
        let c = make(minutes: 5, idleSeconds: { idle })
        idle = 4 * 60
        XCTAssertFalse(c.shouldLockForIdle()) // 4 min < 5
        idle = 5 * 60
        XCTAssertTrue(c.shouldLockForIdle())  // 5 min ≥ 5
    }

    func testRecentSystemInputPreventsLock() {
        // System-wide input just happened (small idle) → not idle, even past
        // the threshold in wall-clock terms.
        let c = make(minutes: 1, idleSeconds: { 31 })
        XCTAssertFalse(c.shouldLockForIdle())
    }

    func testNoLockWhenNotEnabledAndUnlocked() {
        let c = make(minutes: 1, idleSeconds: { 999 }, enabled: { false })
        XCTAssertFalse(c.shouldLockForIdle())
    }

    func testNoLockWhileCapturingOrRecording() {
        // Long past the idle threshold, but a capture/recording is in flight —
        // defer the lock rather than interrupt it.
        let c = make(minutes: 1, idleSeconds: { 600 }, busy: { true },
                     locked: { XCTFail("must not lock mid-capture") })
        XCTAssertFalse(c.shouldLockForIdle())
    }

    func testTickLocksWhenIdle() {
        var locked = false
        let c = make(minutes: 1, idleSeconds: { 120 }, locked: { locked = true })
        c.idleTick()                          // the timer's callback, called directly
        XCTAssertTrue(locked)
    }
}
