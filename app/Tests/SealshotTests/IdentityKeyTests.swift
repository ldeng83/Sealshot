import XCTest
import CryptoKit
@testable import Sealshot

final class IdentityKeyTests: XCTestCase {
    func testWrapUnwrapContentKey() throws {
        let identity = IdentityKey.generate()
        let content = SymmetricKey(size: .bits256)
        let gen = KeyGeneration.make(publicKey: identity.publicKey)
        let capsule = try identity.publicKey.wrap(contentKey: content, generation: gen)
        let unwrapped = try identity.unwrap(capsule: capsule)
        XCTAssertEqual(content.withUnsafeBytes { Data($0) },
                       unwrapped.withUnsafeBytes { Data($0) })
    }

    func testWrapNeedsOnlyPublicKey() throws {
        let identity = IdentityKey.generate()
        let restored = try IdentityPublicKey(rawRepresentation: identity.publicKey.rawRepresentation)
        let capsule = try restored.wrap(contentKey: SymmetricKey(size: .bits256),
                                        generation: .make(publicKey: restored))
        XCTAssertNoThrow(try identity.unwrap(capsule: capsule))
    }

    func testWrongIdentityCannotUnwrap() throws {
        let pub = IdentityKey.generate().publicKey
        let capsule = try pub.wrap(contentKey: SymmetricKey(size: .bits256),
                                   generation: .make(publicKey: pub))
        XCTAssertThrowsError(try IdentityKey.generate().unwrap(capsule: capsule))
    }

    func testCapsuleCodecRoundTrip() throws {
        let identity = IdentityKey.generate()
        let capsule = try identity.publicKey.wrap(contentKey: SymmetricKey(size: .bits256),
                                                  generation: .make(publicKey: identity.publicKey))
        let decoded = try JSONDecoder().decode(KeyCapsule.self,
                                               from: JSONEncoder().encode(capsule))
        XCTAssertNoThrow(try identity.unwrap(capsule: decoded))
    }

    func testPrivateKeyRawRoundTrip() throws {
        let identity = IdentityKey.generate()
        let restored = try IdentityKey(rawRepresentation: identity.rawRepresentation)
        let capsule = try identity.publicKey.wrap(contentKey: SymmetricKey(size: .bits256),
                                                  generation: .make(publicKey: identity.publicKey))
        XCTAssertNoThrow(try restored.unwrap(capsule: capsule))
    }
}
