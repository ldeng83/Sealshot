import XCTest
import CryptoKit
@testable import Sealshot

final class EntitlementStoreTests: XCTestCase {
    let key = Curve25519.Signing.PrivateKey()
    var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    @MainActor func makeStore(alwaysEntitled: Bool = false,
                              buildReleaseDate: Date? = nil) -> EntitlementStore {
        EntitlementStore(
            verifier: LicenseVerifier(publicKeys: [1: key.publicKey]),
            installClock: InstallClock(stores: [InMemoryStampStore()]),
            licenseDirectory: dir,
            blocklistCache: BlocklistCache(directory: dir),
            alwaysEntitled: alwaysEntitled,
            buildReleaseDate: buildReleaseDate)
    }

    func day(_ s: String) -> Date { UTCDay.parse(s)! }

    @MainActor func test_freshInstall_hasNoLicense_butIsFullyUsable() {
        let store = makeStore()
        XCTAssertEqual(store.state, .unlicensed)
        XCTAssertFalse(store.blocksCreation)
        XCTAssertFalse(store.isSupported, "no license means the reminder is still due")
    }

    @MainActor func test_activate_validFile_persists_acrossRelaunch() throws {
        let store = makeStore()
        let file = try LicenseFormatTests.makeLicenseFile(key: key)
        try store.activate(file)
        guard case .licensed(let p) = store.state else { return XCTFail("not licensed") }
        XCTAssertEqual(p.name, "Jane Doe")
        // "Relaunch": a fresh store over the same directory loads the saved license.
        guard case .licensed = makeStore().state else { return XCTFail("license not persisted") }
    }

    @MainActor func test_activate_invalid_throws_andStateUnchanged() throws {
        let store = makeStore()
        XCTAssertThrowsError(try store.activate("SEALSHOT1.garbage"))
        XCTAssertThrowsError(try store.activate(
            try LicenseFormatTests.makeLicenseFile(key: .init())))   // wrong signer
        XCTAssertEqual(store.state, .unlicensed)
    }

    @MainActor func test_activate_tamperedFile_textTampered_andStateUnchanged() throws {
        let store = makeStore()
        let file = try LicenseFormatTests.makeLicenseFile(key: key)
        let tampered = file.replacingOccurrences(of: "Licensed to:      Jane Doe",
                                                  with: "Licensed to:      Jane Roe")
        XCTAssertThrowsError(try store.activate(tampered)) { error in
            XCTAssertEqual(error as? LicenseError, .textTampered)
        }
        XCTAssertEqual(store.state, .unlicensed)
    }

    @MainActor func test_activate_revokedLicense_rejected_andBlocklistDropsActiveLicense() throws {
        let store = makeStore()
        let file = try LicenseFormatTests.makeLicenseFile(key: key)
        let payload = try LicenseVerifier(publicKeys: [1: key.publicKey]).verify(fileText: file)
        try store.activate(file)

        let sorted = [payload.id].map(\.uuidString).sorted().joined(separator: ",")
        let sig = try key.signature(for: Data(sorted.utf8))
        let list = Blocklist(v: 1, key: 1, revoked: [payload.id], updated: "2026-07-17",
                             sig: sig.base64EncodedString())
        store.apply(blocklist: list)
        XCTAssertEqual(store.state, .unlicensed, "revoked → no usable license")
        XCTAssertThrowsError(try store.activate(file), "re-activation also blocked")
    }

    @MainActor func test_removeLicense_returnsToUnlicensed() throws {
        let store = makeStore()
        try store.activate(try LicenseFormatTests.makeLicenseFile(key: key))
        store.removeLicense()
        XCTAssertEqual(store.state, .unlicensed)
    }

    @MainActor func test_alwaysEntitled_ignoresEverything() {
        let store = makeStore(alwaysEntitled: true)
        guard case .licensed = store.state else { return XCTFail() }
    }

    @MainActor func test_buildNewerThanWindow_isBuildNotCovered_butStillFullyUsable() throws {
        let store = makeStore(buildReleaseDate: day("2027-08-01"))
        try store.activate(try LicenseFormatTests.makeLicenseFile(key: key))
        guard case .buildNotCovered(let p) = store.state else {
            return XCTFail("expected buildNotCovered, got \(store.state)")
        }
        XCTAssertEqual(p.updatesThrough, "2027-07-17")
        // Past the update window the app keeps working in full — and with
        // renewals gone, the reminder stays off too: this person already paid.
        XCTAssertFalse(store.blocksCreation)
        XCTAssertTrue(store.isSupported)
        // Persists across "relaunch" exactly like a licensed state.
        guard case .buildNotCovered = makeStore(buildReleaseDate: day("2027-08-01")).state else {
            return XCTFail("state not re-derived from disk")
        }
    }

    @MainActor func test_buildInsideWindow_staysLicensed() throws {
        let store = makeStore(buildReleaseDate: day("2027-07-01"))
        try store.activate(try LicenseFormatTests.makeLicenseFile(key: key))
        guard case .licensed = store.state else { return XCTFail("got \(store.state)") }
        XCTAssertFalse(store.blocksCreation)
    }

    @MainActor func test_unstampedDevBuild_failsOpen_staysLicensed() throws {
        let store = makeStore(buildReleaseDate: nil)
        try store.activate(try LicenseFormatTests.makeLicenseFile(key: key))
        guard case .licensed = store.state else { return XCTFail("got \(store.state)") }
    }

    @MainActor
    func test_activationOutcomes() throws {
        let id = UUID()
        let store = makeStore()

        let original = try LicenseFormatTests.makeLicenseFile(
            key: key, id: id, issued: "2026-01-01", updatesThrough: "2027-01-01")
        guard case .installed(let first) = try store.activate(original) else {
            return XCTFail("a first license must install")
        }
        XCTAssertEqual(first.id, id)

        // Same file again → already installed, window unchanged.
        XCTAssertEqual(try store.activate(original), .alreadyInstalled)

        // Newer renewal, same id → installs.
        let renewal = try LicenseFormatTests.makeLicenseFile(
            key: key, id: id, issued: "2026-12-01", updatesThrough: "2028-01-01")
        guard case .installed = try store.activate(renewal) else {
            return XCTFail("a later updatesThrough must install")
        }

        // Older file for the same license → rejected, stored window untouched.
        guard case .olderRejected(let current, let offered) = try store.activate(original) else {
            return XCTFail("an earlier updatesThrough must be rejected")
        }
        XCTAssertEqual(current.updatesThrough, "2028-01-01")
        XCTAssertEqual(offered.updatesThrough, "2027-01-01")
        if case .licensed(let p) = store.state {
            XCTAssertEqual(p.updatesThrough, "2028-01-01", "a rejected file must not be stored")
        } else { XCTFail("expected still licensed") }

        // A different license id → asks, writes nothing.
        let other = try LicenseFormatTests.makeLicenseFile(
            key: key, name: "Sam Other", id: UUID(), updatesThrough: "2029-01-01")
        guard case .needsConfirmation = try store.activate(other) else {
            return XCTFail("a different license id must ask first")
        }
        if case .licensed(let p) = store.state {
            XCTAssertEqual(p.name, "Jane Doe", "needsConfirmation must not write")
        } else { XCTFail("expected still licensed") }

        // Confirming replaces it.
        XCTAssertEqual(try store.confirmActivation(other).name, "Sam Other")
    }

    @MainActor
    func test_unverifiableStoredFileIsTreatedAsAbsent() throws {
        let store = makeStore()
        // Write junk straight into the license directory the store reads from.
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "not a license at all".write(to: dir.appendingPathComponent("license.sealshotlicense"),
                                         atomically: true, encoding: .utf8)
        let fresh = try LicenseFormatTests.makeLicenseFile(key: key)
        guard case .installed = try store.activate(fresh) else {
            return XCTFail("a corrupt stored file must not block activation")
        }
    }

    /// A REVOKED stored license is treated as absent too — same reason as an
    /// unverifiable one, and `evaluate()` already ignores it. Otherwise a
    /// refunded customer who buys again is shown as unlicensed by the
    /// status card while the replacement license raises a destructive
    /// "This Mac is licensed to Jane Doe. Replace it with the license for
    /// Jane Doe?" dialog naming the very license the app claims not to have.
    @MainActor
    func test_revokedStoredLicenseIsTreatedAsAbsent() throws {
        let store = makeStore()
        let revokedFile = try LicenseFormatTests.makeLicenseFile(key: key)
        let revokedPayload = try LicenseVerifier(publicKeys: [1: key.publicKey])
            .verify(fileText: revokedFile)
        try store.activate(revokedFile)

        let sorted = [revokedPayload.id].map(\.uuidString).sorted().joined(separator: ",")
        let sig = try key.signature(for: Data(sorted.utf8))
        store.apply(blocklist: Blocklist(v: 1, key: 1, revoked: [revokedPayload.id],
                                         updated: "2026-07-17", sig: sig.base64EncodedString()))
        XCTAssertEqual(store.state, .unlicensed, "revoked → no live license")

        // The replacement (a different license id) must install outright, not
        // ask permission to replace a license the app is already ignoring.
        let replacement = try LicenseFormatTests.makeLicenseFile(key: key, id: UUID())
        guard case .installed = try store.activate(replacement) else {
            return XCTFail("a revoked stored license must not gate the replacement")
        }
        guard case .licensed = store.state else {
            return XCTFail("expected licensed, got \(store.state)")
        }
    }
}
