import XCTest
import CryptoKit
@testable import Sealshot

final class ShareCapsuleCrypterTests: XCTestCase {
    func testPassphraseRoundTrip() throws {
        let cek = SymmetricKey(size: .bits256)
        let cap = try ShareCapsuleCrypter.wrap(cek: cek, passphrase: "open sesame", hint: "phrase")
        let out = try XCTUnwrap(ShareCapsuleCrypter.unwrap(cap, passphrase: "open sesame"))
        XCTAssertEqual(out.rawData, cek.rawData)
        XCTAssertEqual(cap.hint, "phrase")
    }

    func testWrongPassphraseReturnsNil() throws {
        let cek = SymmetricKey(size: .bits256)
        let cap = try ShareCapsuleCrypter.wrap(cek: cek, passphrase: "right", hint: nil)
        XCTAssertNil(ShareCapsuleCrypter.unwrap(cap, passphrase: "wrong"))
    }

    func testIdentityRoundTrip() throws {
        let cek = SymmetricKey(size: .bits256)
        let id = IdentityKey.generate()
        let gen = KeyGeneration.make(publicKey: id.publicKey)
        let cap = try ShareCapsuleCrypter.wrap(cek: cek, recipient: id.publicKey, generation: gen)
        let out = try XCTUnwrap(ShareCapsuleCrypter.unwrap(cap, identity: id))
        XCTAssertEqual(out.rawData, cek.rawData)
    }

    func testIdentityWrongKeyReturnsNil() throws {
        let cek = SymmetricKey(size: .bits256)
        let id = IdentityKey.generate()
        let gen = KeyGeneration.make(publicKey: id.publicKey)
        let cap = try ShareCapsuleCrypter.wrap(cek: cek, recipient: id.publicKey, generation: gen)
        XCTAssertNil(ShareCapsuleCrypter.unwrap(cap, identity: IdentityKey.generate()))
    }
}
