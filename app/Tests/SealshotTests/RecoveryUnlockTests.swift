import XCTest
@testable import Sealshot

/// Verifying a recovery code to unlock the Privacy & Security page: proves
/// ownership against the local keystore without touching the Keychain or
/// session (this Mac already holds the identity).
@MainActor
final class RecoveryUnlockTests: XCTestCase {
    var saveFolder: URL!
    var realCode: String!

    override func setUpWithError() throws {
        saveFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("recunlock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: saveFolder, withIntermediateDirectories: true)
        let identity = IdentityKey.generate()
        realCode = RecoveryKey.generateCode()
        try Keystore.create(identity: identity, recoveryCode: realCode,
                            generation: .make(publicKey: identity.publicKey))
            .write(toFolder: saveFolder)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: saveFolder)
    }

    func testAvailableWhenKeystorePresent() {
        XCTAssertTrue(RecoveryUnlock.isAvailable(saveFolder: saveFolder))
    }

    func testUnavailableWithoutKeystore() throws {
        try FileManager.default.removeItem(at: saveFolder.appendingPathComponent(Keystore.filename))
        XCTAssertFalse(RecoveryUnlock.isAvailable(saveFolder: saveFolder))
    }

    func testCorrectCodeVerifies() async {
        let ok = await RecoveryUnlock.verify(code: realCode, saveFolder: saveFolder)
        XCTAssertTrue(ok)
    }

    func testWrongCodeFails() async {
        let ok = await RecoveryUnlock.verify(code: RecoveryKey.generateCode(), saveFolder: saveFolder)
        XCTAssertFalse(ok)
    }

    func testNormalizedCodeAccepted() async {
        // Lower-cased and dashes swapped for spaces — same normalization the
        // derivation applies, so it must still verify.
        let messy = realCode.lowercased().replacingOccurrences(of: "-", with: " ")
        let ok = await RecoveryUnlock.verify(code: messy, saveFolder: saveFolder)
        XCTAssertTrue(ok)
    }

    func testMissingKeystoreFailsVerification() async throws {
        try FileManager.default.removeItem(at: saveFolder.appendingPathComponent(Keystore.filename))
        let ok = await RecoveryUnlock.verify(code: realCode, saveFolder: saveFolder)
        XCTAssertFalse(ok)
    }
}
