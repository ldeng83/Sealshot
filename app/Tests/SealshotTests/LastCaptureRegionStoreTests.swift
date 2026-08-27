import AppKit
import XCTest
@testable import Sealshot

/// The remembered capture area. These tests are mostly about REFUSING to
/// resolve — a stored rect is a promise about pixels the user cannot see when
/// they press the shortcut, so every way the desk can change since it was
/// stored has to end in "ask again", not in a best guess.
@MainActor
final class LastCaptureRegionStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "LastCaptureRegionStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func region(_ rect: CGRect, _ id: String = "display-1")
    -> LastCaptureRegionStore.StoredRegion {
        .init(rect: rect, displayID: id)
    }

    // MARK: Persistence

    func testRecord_roundTrips() {
        let store = LastCaptureRegionStore(defaults: defaults)
        XCTAssertNil(store.stored, "nothing remembered to begin with")

        let stored = region(CGRect(x: 100, y: 200, width: 640, height: 480))
        store.record(stored)
        XCTAssertEqual(store.stored, stored)
    }

    func testRecord_replacesThePreviousArea() {
        let store = LastCaptureRegionStore(defaults: defaults)
        store.record(region(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let newer = region(CGRect(x: 5, y: 6, width: 7, height: 8), "display-2")
        store.record(newer)
        XCTAssertEqual(store.stored, newer, "only the LAST area is remembered")
    }

    func testClear_forgetsIt() {
        let store = LastCaptureRegionStore(defaults: defaults)
        store.record(region(CGRect(x: 1, y: 2, width: 3, height: 4)))
        store.clear()
        XCTAssertNil(store.stored)
    }

    /// A malformed value must decode to nil, not to a zero rect — a zero rect
    /// is indistinguishable from a real stored area and would capture nothing
    /// while looking like a hit.
    func testMalformedStorage_decodesToNothing() {
        for junk in ["", "nonsense", "1 2 3 display-1", "a b c d display-1",
                     "1 2 3 4", "1 2 3 4 "] {
            defaults.set(junk, forKey: "LastCaptureRegion")
            XCTAssertNil(LastCaptureRegionStore(defaults: defaults).stored,
                         "\"\(junk)\" must not decode")
        }
    }

    /// An empty rect would be a capture of nothing.
    func testDegenerateRect_decodesToNothing() {
        defaults.set("10 10 0 480 display-1", forKey: "LastCaptureRegion")
        XCTAssertNil(LastCaptureRegionStore(defaults: defaults).stored)
    }

    /// Display UUIDs contain dashes but never spaces, so the space-separated
    /// encoding survives them.
    func testDisplayIDsWithDashes_surviveEncoding() {
        let store = LastCaptureRegionStore(defaults: defaults)
        let stored = region(CGRect(x: 1, y: 2, width: 3, height: 4),
                            "37D8832A-2D66-02CA-B9F7-8F30A301B230")
        store.record(stored)
        XCTAssertEqual(store.stored, stored)
    }

    // MARK: Resolving against the screens that exist NOW

    /// `resolve` takes the screen list and an id function so the desk can be
    /// simulated — the real one has whatever monitors are plugged in today.
    private func resolve(_ stored: LastCaptureRegionStore.StoredRegion?,
                         screens: [NSScreen],
                         ids: [String?]) -> SelectedRegion? {
        var map: [ObjectIdentifier: String?] = [:]
        for (screen, id) in zip(screens, ids) { map[ObjectIdentifier(screen)] = id }
        return LastCaptureRegionStore.resolve(stored, screens: screens) {
            map[ObjectIdentifier($0)] ?? nil
        }
    }

    func testResolve_returnsTheAreaWhenItsDisplayIsStillThere() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let inside = CGRect(x: screen.frame.minX + 50, y: screen.frame.minY + 50,
                            width: 200, height: 100)
        let resolved = resolve(region(inside, "here"), screens: [screen], ids: ["here"])
        XCTAssertEqual(resolved?.globalRect, inside)
        XCTAssertEqual(resolved?.screen, screen)
    }

    func testResolve_refusesWhenNothingWasRemembered() {
        XCTAssertNil(resolve(nil, screens: NSScreen.screens,
                             ids: NSScreen.screens.map { _ in "x" }))
    }

    /// The unplugged-monitor case: the area is fine, its display is gone.
    /// Nothing on the remaining screens is a substitute for it.
    func testResolve_refusesWhenTheDisplayIsGone() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let inside = CGRect(x: screen.frame.minX + 10, y: screen.frame.minY + 10,
                            width: 100, height: 100)
        XCTAssertNil(resolve(region(inside, "unplugged"),
                             screens: [screen], ids: ["still-here"]),
                     "a region from a missing display must not be re-homed")
    }

    /// The resolution-change case: same display, but the area no longer fits
    /// on it. Half a capture of the wrong thing is still the wrong thing.
    func testResolve_refusesAnAreaThatNoLongerFitsItsDisplay() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let hangingOff = CGRect(x: screen.frame.maxX - 50, y: screen.frame.minY + 10,
                                width: 400, height: 100)
        XCTAssertNil(resolve(region(hangingOff, "here"), screens: [screen], ids: ["here"]),
                     "partly off its screen is a refusal, not a clamp")
    }

    /// A screen with no identity at all can't be matched against a stored id.
    func testResolve_refusesWhenTheScreenHasNoIdentity() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let inside = CGRect(x: screen.frame.minX + 10, y: screen.frame.minY + 10,
                            width: 100, height: 100)
        XCTAssertNil(resolve(region(inside, "here"), screens: [screen], ids: [nil]))
    }
}
