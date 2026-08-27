import XCTest
@testable import Sealshot

final class KeyGenerationTests: XCTestCase {
    func testFingerprintIsStableForSameKey() {
        let pub = IdentityKey.generate().publicKey
        XCTAssertEqual(KeyGeneration.fingerprint(of: pub), KeyGeneration.fingerprint(of: pub))
    }

    func testFingerprintDiffersForDifferentKeys() {
        let a = IdentityKey.generate().publicKey
        let b = IdentityKey.generate().publicKey
        XCTAssertNotEqual(KeyGeneration.fingerprint(of: a), KeyGeneration.fingerprint(of: b))
    }

    func testFingerprintIs32LowercaseHexChars() {
        let fp = KeyGeneration.fingerprint(of: IdentityKey.generate().publicKey)
        XCTAssertEqual(fp.count, 32)
        XCTAssertTrue(fp.allSatisfy { "0123456789abcdef".contains($0) },
                      "fingerprint must be lowercase hex")
    }

    func testMakeStampsFingerprintWithDistinctIDsPerProvisioning() {
        let pub = IdentityKey.generate().publicKey
        let g1 = KeyGeneration.make(publicKey: pub)
        let g2 = KeyGeneration.make(publicKey: pub)
        XCTAssertEqual(g1.fingerprint, g2.fingerprint, "same key → same fingerprint")
        XCTAssertNotEqual(g1.id, g2.id, "each provisioning is a distinct generation")
    }

    func testMakeUsesInjectedIDAndDate() {
        let id = UUID()
        let when = Date(timeIntervalSince1970: 42)
        let g = KeyGeneration.make(publicKey: IdentityKey.generate().publicKey, id: id, createdAt: when)
        XCTAssertEqual(g.id, id)
        XCTAssertEqual(g.createdAt, when)
    }
}
