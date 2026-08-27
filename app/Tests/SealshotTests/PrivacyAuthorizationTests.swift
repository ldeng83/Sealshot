import XCTest
@testable import Sealshot

@MainActor
final class PrivacyAuthorizationTests: XCTestCase {
    /// A mutable clock so expiry is deterministic without real sleeps.
    private final class Clock { var t = Date(timeIntervalSince1970: 1_000) }

    func testNotAuthorizedUntilGranted() {
        let auth = PrivacyAuthorization(validity: 300, now: { Date() })
        XCTAssertFalse(auth.isAuthorized)
    }

    func testGrantAuthorizesWithinWindow() {
        let clock = Clock()
        let auth = PrivacyAuthorization(validity: 300, now: { clock.t })
        auth.grant()
        XCTAssertTrue(auth.isAuthorized)
        clock.t = clock.t.addingTimeInterval(299)
        XCTAssertTrue(auth.isAuthorized, "still inside the validity window")
    }

    func testAuthorizationExpiresAfterWindow() {
        let clock = Clock()
        let auth = PrivacyAuthorization(validity: 300, now: { clock.t })
        auth.grant()
        clock.t = clock.t.addingTimeInterval(301)
        XCTAssertFalse(auth.isAuthorized, "past the validity window — must fail closed")
    }

    func testRevokeDropsAuthorizationImmediately() {
        let clock = Clock()
        let auth = PrivacyAuthorization(validity: 300, now: { clock.t })
        auth.grant()
        XCTAssertTrue(auth.isAuthorized)
        auth.revoke()
        XCTAssertFalse(auth.isAuthorized, "leaving the page must relock immediately")
    }
}
