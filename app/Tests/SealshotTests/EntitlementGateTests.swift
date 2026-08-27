import XCTest
@testable import Sealshot

/// Sealshot is free to use, so this file exists to pin the ABSENCE of a gate.
///
/// It used to assert the opposite — an expired trial blocked new captures — and
/// switch to free-with-a-reminder is exactly the kind of change that gets half
/// reverted later by someone restoring "just one" guard. Every state, including
/// the two that once blocked, must answer `false`.
final class EntitlementGateTests: XCTestCase {
    private func payload(updatesThrough: String = "2027-01-01") -> LicensePayload {
        LicensePayload(id: UUID(), name: "n", email: "e", licenseType: .individual,
                       issued: "2026-01-01", updatesThrough: updatesThrough, seats: 1)
    }

    func test_nothingBlocksCreation_inAnyState() {
        for state in [EntitlementStore.State.unlicensed,
                      .licensed(payload()),
                      .buildNotCovered(payload())] {
            XCTAssertFalse(EntitlementStore.blocksCreation(state: state),
                           "\(state) must not block captures — the app is free to use")
        }
    }

    /// Any valid license file counts as supported — the person paid, and with
    /// renewals gone there is nothing a lapsed window should cost them. The
    /// honor flag covers everyone else and is tested with the nudge store.
    func test_anyValidLicenseCountsAsSupported() {
        XCTAssertTrue(EntitlementStore.isSupported(state: .licensed(payload())))
        XCTAssertTrue(EntitlementStore.isSupported(state: .buildNotCovered(payload())))
        XCTAssertFalse(EntitlementStore.isSupported(state: .unlicensed))
    }
}
