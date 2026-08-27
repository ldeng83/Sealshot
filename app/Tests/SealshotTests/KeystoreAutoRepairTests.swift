import XCTest
@testable import Sealshot

/// The self-heal for an accidentally deleted keystore.json: whenever the
/// session is unlocked and the escrow file is missing, re-escrow the
/// in-memory identity under a FRESH recovery code and rewrite the file.
final class KeystoreAutoRepairTests: XCTestCase {
    var dir: URL!
    let identity = IdentityKey.generate()
    lazy var gen = KeyGeneration.make(publicKey: identity.publicKey)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keystore-repair-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testRepair_recreatesMissingKeystoreWithWorkingCode() throws {
        let code = try XCTUnwrap(KeystoreAutoRepair.repair(
            identity: identity, generation: gen, enabled: true, saveFolder: dir))

        let keystore = try XCTUnwrap(Keystore.read(fromFolder: dir))
        XCTAssertEqual(keystore.publicKeyRaw, identity.publicKey.rawRepresentation)
        XCTAssertEqual(keystore.generation, gen)
        // The returned code actually unlocks the new escrow.
        let recovered = try RecoveryKey.recover(escrow: keystore.escrow, code: code)
        XCTAssertEqual(recovered.rawRepresentation, identity.rawRepresentation)
        // And it re-reveals via the sealed copy, like "View recovery code".
        XCTAssertEqual(keystore.recoveryCode(unwrappingWith: identity), code)
    }

    func testRepair_noOpWhenKeystorePresent() throws {
        let original = try Keystore.create(
            identity: identity, recoveryCode: RecoveryKey.generateCode(), generation: gen)
        try original.write(toFolder: dir)

        XCTAssertNil(KeystoreAutoRepair.repair(
            identity: identity, generation: gen, enabled: true, saveFolder: dir),
            "an existing keystore must never be overwritten")
        let after = try XCTUnwrap(Keystore.read(fromFolder: dir))
        XCTAssertEqual(after.escrow.sealed, original.escrow.sealed, "file untouched")
    }

    func testRepair_noOpWhenDisabledOrLocked() {
        XCTAssertNil(KeystoreAutoRepair.repair(
            identity: identity, generation: gen, enabled: false, saveFolder: dir))
        XCTAssertNil(KeystoreAutoRepair.repair(
            identity: nil, generation: gen, enabled: true, saveFolder: dir),
            "locked session (no in-memory identity) can't re-escrow")
        XCTAssertNil(KeystoreAutoRepair.repair(
            identity: identity, generation: nil, enabled: true, saveFolder: dir))
        XCTAssertNil(Keystore.read(fromFolder: dir), "nothing written")
    }
}
