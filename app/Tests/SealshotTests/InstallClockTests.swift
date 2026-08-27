import XCTest
@testable import Sealshot

/// The install stamp is the only durable answer to "how long has this been
/// here?", and the support reminder waits on it. Nothing counts down any more —
/// what these tests pin is that the date survives.
final class InstallClockTests: XCTestCase {
    let day: TimeInterval = 86_400

    func makeClock(stores: [any InstallStampStore] = [InMemoryStampStore(), InMemoryStampStore()]) -> InstallClock {
        InstallClock(stores: stores)
    }

    func test_firstHeal_seedsTheInstallDate() {
        let clock = makeClock()
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertNil(clock.recordedStart, "nothing recorded before the first heal")
        XCTAssertEqual(clock.heal(now: now), now)
        XCTAssertEqual(clock.recordedStart, now)
    }

    /// Reading the date must never stamp anything: `SupportNudge` asks on every
    /// capture, and an asking-side-effect would rewrite `lastSeen` constantly.
    func test_recordedStart_doesNotWrite() {
        let store = InMemoryStampStore()
        let clock = makeClock(stores: [store])
        _ = clock.recordedStart
        XCTAssertNil(store.read(key: .installedAt))
        XCTAssertNil(store.read(key: .lastSeen))
    }

    func test_installDateHoldsAsTimePasses() {
        let clock = makeClock()
        let start = Date(timeIntervalSince1970: 1_000_000)
        _ = clock.heal(now: start)
        XCTAssertEqual(clock.heal(now: start.addingTimeInterval(3 * day + 60)), start)
        XCTAssertEqual(clock.heal(now: start.addingTimeInterval(400 * day)), start)
    }

    func test_earliestStampWins_andHeals_deletedStore() {
        let a = InMemoryStampStore(), b = InMemoryStampStore()
        let start = Date(timeIntervalSince1970: 1_000_000)
        _ = makeClock(stores: [a, b]).heal(now: start)
        a.wipe()                                                       // user deletes one hiding place
        let clock2 = makeClock(stores: [a, b])
        XCTAssertEqual(clock2.heal(now: start.addingTimeInterval(5 * day)), start,
                       "the surviving store still knows the real install date")
        XCTAssertNotNil(a.read(key: .installedAt), "healed back into the wiped store")
    }

    /// Setting the clock back must not make an old install look new — that is
    /// what would hand someone a fresh 30-day wait before the first reminder.
    func test_clockRollback_doesNotRewindTheInstallDate() {
        let a = InMemoryStampStore()
        let start = Date(timeIntervalSince1970: 1_000_000)
        let clock = makeClock(stores: [a])
        _ = clock.heal(now: start)
        _ = clock.heal(now: start.addingTimeInterval(10 * day))        // lastSeen = day 10
        XCTAssertEqual(clock.heal(now: start.addingTimeInterval(1 * day)), start)
    }

    /// A wiped install on a machine whose clock was pushed forward and back:
    /// the re-seed uses the clamped time, so it can't land in the past.
    func test_wipedEverything_reseedsFromTheClampedNow() {
        let a = InMemoryStampStore()
        let clock = makeClock(stores: [a])
        let start = Date(timeIntervalSince1970: 1_000_000)
        _ = clock.heal(now: start.addingTimeInterval(10 * day))
        a.forget(.installedAt)                             // only the install date is lost
        XCTAssertEqual(clock.heal(now: start), start.addingTimeInterval(10 * day),
                       "re-seeded from lastSeen, not from the rewound clock")
    }

    func test_fileStore_roundTrips() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = FileStampStore(directory: dir)
        let stamp = Date(timeIntervalSince1970: 1_234_567)
        store.write(stamp, key: .installedAt)
        XCTAssertEqual(FileStampStore(directory: dir).read(key: .installedAt), stamp)
    }

    func test_defaultsStore_roundTrips() {
        let defaults = UserDefaults(suiteName: "lic-\(UUID().uuidString)")!
        let store = DefaultsStampStore(defaults: defaults)
        let stamp = Date(timeIntervalSince1970: 7_654_321)
        store.write(stamp, key: .lastSeen)
        XCTAssertEqual(store.read(key: .lastSeen), stamp)
    }

    /// The stored names are what every existing install already has on disk.
    /// Changing one would read as a brand-new install to every user and restart
    /// the wait before the first support reminder, so they are pinned here
    /// rather than left to a rename-all.
    func test_storedKeyNamesAreFrozen() {
        XCTAssertEqual(InstallStampKey.installedAt.rawValue, "trialStart")
        XCTAssertEqual(InstallStampKey.lastSeen.rawValue, "lastSeen")

        let defaults = UserDefaults(suiteName: "lic-\(UUID().uuidString)")!
        DefaultsStampStore(defaults: defaults).write(Date(timeIntervalSince1970: 42),
                                                    key: .installedAt)
        XCTAssertEqual(defaults.double(forKey: "license.trialStart"), 42)
    }
}
