import XCTest
import CryptoKit
@testable import Sealshot

final class PassphraseKDFTests: XCTestCase {
    func testDeriveIsDeterministicForSameInputs() throws {
        let salt = Data(repeating: 7, count: PassphraseKDF.saltSize)
        let a = try PassphraseKDF.derive(passphrase: "correct horse", salt: salt, iterations: 600_000)
        let b = try PassphraseKDF.derive(passphrase: "correct horse", salt: salt, iterations: 600_000)
        XCTAssertEqual(a.withUnsafeBytes { Data($0) }, b.withUnsafeBytes { Data($0) })
    }

    func testDifferentSaltProducesDifferentKey() throws {
        let a = try PassphraseKDF.derive(passphrase: "pw", salt: Data(repeating: 1, count: 16), iterations: 600_000)
        let b = try PassphraseKDF.derive(passphrase: "pw", salt: Data(repeating: 2, count: 16), iterations: 600_000)
        XCTAssertNotEqual(a.withUnsafeBytes { Data($0) }, b.withUnsafeBytes { Data($0) })
    }

    func testEmptyPassphraseThrows() {
        XCTAssertThrowsError(try PassphraseKDF.derive(passphrase: "", salt: Data(repeating: 1, count: 16), iterations: 600_000)) { error in
            guard case PassphraseKDF.Error.emptyPassphrase = error else {
                return XCTFail("expected emptyPassphrase, got \(error)")
            }
        }
    }

    func testMakeSaltLength() {
        XCTAssertEqual(PassphraseKDF.makeSalt().count, PassphraseKDF.saltSize)
    }
}
