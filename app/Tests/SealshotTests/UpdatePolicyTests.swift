import XCTest
import CryptoKit
@testable import Sealshot

final class UpdatePolicyTests: XCTestCase {
    func payload(updatesThrough: String) -> LicensePayload {
        LicensePayload(id: UUID(), name: "n", email: "e", licenseType: .individual,
                       issued: "2026-07-17", updatesThrough: updatesThrough, seats: 1)
    }
    func date(_ s: String) -> Date {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)!
    }

    func test_unlicensed_alwaysAllowed() {
        XCTAssertTrue(UpdatePolicy.allowsUpdate(publishedAt: date("2030-01-01"), state: .unlicensed))
    }

    /// A permanent license (empty `updatesThrough`) must never limit an update.
    /// This is the fail-open path the whole permanent-license design rests on:
    /// the field is unparseable, so every window check answers "no limit".
    func test_permanentLicense_allowsAnyFutureRelease() {
        let state = EntitlementStore.State.licensed(payload(updatesThrough: ""))
        XCTAssertTrue(UpdatePolicy.allowsUpdate(publishedAt: date("2099-01-01"), state: state))
    }

    func test_licensed_allowedThroughWindow_blockedAfter() {
        let state = EntitlementStore.State.licensed(payload(updatesThrough: "2027-07-17"))
        XCTAssertTrue(UpdatePolicy.allowsUpdate(publishedAt: date("2027-07-17"), state: state))  // inclusive
        XCTAssertTrue(UpdatePolicy.allowsUpdate(publishedAt: date("2026-12-01"), state: state))
        XCTAssertFalse(UpdatePolicy.allowsUpdate(publishedAt: date("2027-07-19"), state: state))
    }

    func test_missingDates_failOpen() {
        XCTAssertTrue(UpdatePolicy.allowsUpdate(publishedAt: nil,
            state: .licensed(payload(updatesThrough: "2027-07-17"))))
        XCTAssertTrue(UpdatePolicy.allowsUpdate(publishedAt: Date(),
            state: .licensed(payload(updatesThrough: "garbage"))))
    }

    func test_coversRunningBuild_insideWindow_inclusive_plusOneDaySlack() {
        let p = payload(updatesThrough: "2027-07-17")
        XCTAssertTrue(UpdatePolicy.coversRunningBuild(buildReleasedAt: date("2026-12-01"), payload: p))
        XCTAssertTrue(UpdatePolicy.coversRunningBuild(buildReleasedAt: date("2027-07-17"), payload: p))  // inclusive
        XCTAssertTrue(UpdatePolicy.coversRunningBuild(buildReleasedAt: date("2027-07-18"), payload: p))  // +1d slack
        XCTAssertFalse(UpdatePolicy.coversRunningBuild(buildReleasedAt: date("2027-07-19"), payload: p))
    }

    func test_coversRunningBuild_failsOpen_onMissingOrBadDates() {
        XCTAssertTrue(UpdatePolicy.coversRunningBuild(
            buildReleasedAt: nil, payload: payload(updatesThrough: "2027-07-17")))
        XCTAssertTrue(UpdatePolicy.coversRunningBuild(
            buildReleasedAt: date("2030-01-01"), payload: payload(updatesThrough: "")))
        XCTAssertTrue(UpdatePolicy.coversRunningBuild(
            buildReleasedAt: date("2030-01-01"), payload: payload(updatesThrough: "garbage")))
    }

    func test_buildNotCovered_sparkleUpdatesStillGatedByWindow() {
        let state = EntitlementStore.State.buildNotCovered(payload(updatesThrough: "2027-07-17"))
        XCTAssertTrue(UpdatePolicy.allowsUpdate(publishedAt: date("2027-07-01"), state: state))
        XCTAssertFalse(UpdatePolicy.allowsUpdate(publishedAt: date("2027-08-01"), state: state))
    }
}
