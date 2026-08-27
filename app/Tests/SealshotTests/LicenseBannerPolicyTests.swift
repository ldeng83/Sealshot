import XCTest
@testable import Sealshot

final class LicenseBannerPolicyTests: XCTestCase {

    // A licensed user well inside their window has nothing to be told.
    func test_licensedWellInsideTheWindow_showsNothing() {
        // `now` is pinned: with the default `Date()` this case would start
        // FAILING on 2026-12-02, the day 2027-01-01 falls inside the 30-day
        // lapsing window and the expected nil becomes a nudge.
        XCTAssertNil(LicenseBannerPolicy.banner(for: .licensed(LicensePayload(
            id: UUID(), name: "n", email: "e", licenseType: .individual,
            issued: "2026-01-01", updatesThrough: "2027-01-01", seats: 1)), dismissed: nil,
            now: UTCDay.parse("2026-01-15")!))
    }

    /// The banner is now only ever about a PAID license's update window.
    /// An unlicensed user gets no banner at all, however old the install:
    /// every feature works, so a bar across the top of their window would be
    /// pure advertising. The occasional `SupportNudge` is the whole of the ask,
    /// and this test is what stops a countdown creeping back in.
    func test_unlicensed_neverShowsABanner() {
        XCTAssertNil(LicenseBannerPolicy.banner(for: .unlicensed, dismissed: nil),
                     "an unlicensed user must produce no banner")
    }

    func test_buildNotCovered_alwaysShows_ignoresDismissal() {
        let payload = LicensePayload(id: UUID(), name: "n", email: "e", licenseType: .individual,
                                     issued: "2026-07-17", updatesThrough: "2027-07-17", seats: 1)
        let state = EntitlementStore.State.buildNotCovered(payload)
        let kind = LicenseBannerKind.buildNotCovered(updatesThrough: "2027-07-17")
        XCTAssertEqual(LicenseBannerPolicy.banner(for: state, dismissed: nil), kind)
        XCTAssertEqual(LicenseBannerPolicy.banner(for: state, dismissed: kind), kind,
                       "buildNotCovered is not dismissible")
    }

    func test_licensedWithinThirtyDaysOfLapseShowsNudge() {
        let payload = LicensePayload(id: UUID(), name: "J", email: "j@x.com",
                                     licenseType: .individual, issued: "2026-01-01",
                                     updatesThrough: "2026-08-20", seats: 1, textHash: "h")
        let now = UTCDay.parse("2026-08-01")!
        XCTAssertEqual(LicenseBannerPolicy.banner(for: .licensed(payload), dismissed: nil, now: now),
                       .updatesLapsingSoon(daysLeft: 19))
    }

    // Boundary: exactly 30 days out is still inside the window (guard is
    // `days <= updatesLapsingWindowDays`). Both fixture dates are
    // UTCDay.parse midnights, so the difference is an exact multiple of
    // 86_400 seconds — no truncation ambiguity.
    func test_licensedExactlyThirtyDaysOutShowsNudge() {
        let payload = LicensePayload(id: UUID(), name: "J", email: "j@x.com",
                                     licenseType: .individual, issued: "2026-01-01",
                                     updatesThrough: "2026-08-31", seats: 1, textHash: "h")
        let now = UTCDay.parse("2026-08-01")!
        XCTAssertEqual(LicenseBannerPolicy.banner(for: .licensed(payload), dismissed: nil, now: now),
                       .updatesLapsingSoon(daysLeft: 30))
    }

    // Boundary: 31 days out is one past the window — first day it should
    // NOT show.
    func test_licensedThirtyOneDaysOutShowsNothing() {
        let payload = LicensePayload(id: UUID(), name: "J", email: "j@x.com",
                                     licenseType: .individual, issued: "2026-01-01",
                                     updatesThrough: "2026-09-01", seats: 1, textHash: "h")
        let now = UTCDay.parse("2026-08-01")!
        XCTAssertNil(LicenseBannerPolicy.banner(for: .licensed(payload), dismissed: nil, now: now))
    }

    // Boundary: the final day (days == 0), also the singular-wording
    // trigger for the view layer.
    func test_licensedZeroDaysLeftShowsNudge() {
        let payload = LicensePayload(id: UUID(), name: "J", email: "j@x.com",
                                     licenseType: .individual, issued: "2026-01-01",
                                     updatesThrough: "2026-08-01", seats: 1, textHash: "h")
        let now = UTCDay.parse("2026-08-01")!
        XCTAssertEqual(LicenseBannerPolicy.banner(for: .licensed(payload), dismissed: nil, now: now),
                       .updatesLapsingSoon(daysLeft: 0))
    }

    func test_licensedWellBeforeLapseShowsNothing() {
        let payload = LicensePayload(id: UUID(), name: "J", email: "j@x.com",
                                     licenseType: .individual, issued: "2026-01-01",
                                     updatesThrough: "2027-08-20", seats: 1, textHash: "h")
        XCTAssertNil(LicenseBannerPolicy.banner(for: .licensed(payload), dismissed: nil,
                                              now: UTCDay.parse("2026-08-01")!))
    }

    func test_lapsedLicenseShowsNothingHere() {
        // Past the date, the build-not-covered banner is the right surface —
        // a license with a lapsed window still works on covered builds.
        let payload = LicensePayload(id: UUID(), name: "J", email: "j@x.com",
                                     licenseType: .individual, issued: "2026-01-01",
                                     updatesThrough: "2026-07-01", seats: 1, textHash: "h")
        XCTAssertNil(LicenseBannerPolicy.banner(for: .licensed(payload), dismissed: nil,
                                              now: UTCDay.parse("2026-08-01")!))
    }

    func test_nudgeIsDismissibleWithTheDayScopedRule() {
        let payload = LicensePayload(id: UUID(), name: "J", email: "j@x.com",
                                     licenseType: .individual, issued: "2026-01-01",
                                     updatesThrough: "2026-08-20", seats: 1, textHash: "h")
        let now = UTCDay.parse("2026-08-01")!
        XCTAssertNil(LicenseBannerPolicy.banner(for: .licensed(payload),
                                              dismissed: .updatesLapsingSoon(daysLeft: 19), now: now))
        // Ticking closer re-shows it.
        XCTAssertEqual(LicenseBannerPolicy.banner(for: .licensed(payload),
                                                dismissed: .updatesLapsingSoon(daysLeft: 25), now: now),
                       .updatesLapsingSoon(daysLeft: 19))
    }

    /// An empty `updatesThrough` is a PERMANENT license (and the MAS/dev
    /// path). There is no window, so there is never anything to nudge about.
    func test_permanentLicenseNeverNudges() {
        let payload = LicensePayload(id: UUID(), name: "App Store", email: "",
                                     licenseType: .individual, issued: "",
                                     updatesThrough: "", seats: 1, textHash: "")
        XCTAssertNil(LicenseBannerPolicy.banner(for: .licensed(payload), dismissed: nil, now: Date()))
    }
}
