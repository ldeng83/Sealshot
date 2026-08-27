import XCTest
@testable import Sealshot

final class KeystoreTests: XCTestCase {
    var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keystore-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testWriteReadRoundTrip() throws {
        let identity = IdentityKey.generate()
        let code = RecoveryKey.generateCode()
        let gen = KeyGeneration.make(publicKey: identity.publicKey)
        let keystore = try Keystore.create(identity: identity, recoveryCode: code, generation: gen)
        try keystore.write(toFolder: dir)

        let loaded = try XCTUnwrap(Keystore.read(fromFolder: dir))
        XCTAssertEqual(loaded.publicKeyRaw, identity.publicKey.rawRepresentation)
        XCTAssertEqual(loaded.generation, gen, "keystore carries the generation")
        let recovered = try RecoveryKey.recover(escrow: loaded.escrow, code: code)
        XCTAssertEqual(recovered.rawRepresentation, identity.rawRepresentation)
        // v3: the sealed recovery code re-reveals with the identity, not without.
        XCTAssertEqual(loaded.recoveryCode(unwrappingWith: identity), code)
        XCTAssertNil(loaded.recoveryCode(unwrappingWith: IdentityKey.generate()),
                     "wrong identity can't reveal the code")
    }

    func testReadRejectsV1Keystore() throws {
        // A legacy v1 keystore (no `generation`) must decode as nil, not crash.
        let v1 = """
        {"version":1,"publicKeyRaw":"AA==","escrow":{"salt":"AA==","sealed":"AA==","iterations":600000}}
        """
        try Data(v1.utf8).write(to: dir.appendingPathComponent("keystore.json"))
        XCTAssertNil(Keystore.read(fromFolder: dir))
    }

    func testReadMissingReturnsNil() {
        XCTAssertNil(Keystore.read(fromFolder: dir))
    }

    func testReadCorruptReturnsNil() throws {
        try Data("not json".utf8).write(to: dir.appendingPathComponent("keystore.json"))
        XCTAssertNil(Keystore.read(fromFolder: dir))
    }
}
