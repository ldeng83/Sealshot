import XCTest
import CryptoKit
@testable import Sealshot

final class SealedBlobTests: XCTestCase {
    let key = SymmetricKey(size: .bits256)

    func testRoundTrip() throws {
        let plain = Data("hello sealshot".utf8)
        let blob = try SealedBlob.seal(plain, with: key)
        XCTAssertTrue(SealedBlob.isSealed(blob))
        XCTAssertEqual(try SealedBlob.open(blob, with: key), plain)
    }

    func testWrongKeyThrows() throws {
        let blob = try SealedBlob.seal(Data("secret".utf8), with: key)
        XCTAssertThrowsError(try SealedBlob.open(blob, with: SymmetricKey(size: .bits256)))
    }

    func testTamperedCiphertextThrows() throws {
        var blob = try SealedBlob.seal(Data("secret".utf8), with: key)
        blob[blob.count - 1] ^= 0xFF
        XCTAssertThrowsError(try SealedBlob.open(blob, with: key))
    }

    func testPlaintextIsNotSealed() {
        XCTAssertFalse(SealedBlob.isSealed(Data("{\"json\": true}".utf8)))
        XCTAssertFalse(SealedBlob.isSealed(Data()))
    }

    func testUnknownVersionThrows() throws {
        var blob = try SealedBlob.seal(Data("x".utf8), with: key)
        blob[4] = 99 // version byte
        XCTAssertThrowsError(try SealedBlob.open(blob, with: key))
    }
}
