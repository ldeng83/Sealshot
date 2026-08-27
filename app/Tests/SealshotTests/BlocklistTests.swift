import XCTest
import CryptoKit
@testable import Sealshot

final class BlocklistTests: XCTestCase {
    let key = Curve25519.Signing.PrivateKey()

    func makeList(_ ids: [UUID]) throws -> Blocklist {
        let sorted = ids.map(\.uuidString).sorted().joined(separator: ",")
        let sig = try key.signature(for: Data(sorted.utf8))
        return Blocklist(v: 1, key: 1, revoked: ids, updated: "2026-07-17",
                         sig: sig.base64EncodedString())
    }

    func test_verify_valid_andRevokes() throws {
        let id = UUID()
        let list = try makeList([id, UUID()])
        let verifier = BlocklistVerifier(publicKeys: [1: key.publicKey])
        XCTAssertNoThrow(try verifier.verify(list))
        XCTAssertTrue(list.revokes(id))
        XCTAssertFalse(list.revokes(UUID()))
    }

    func test_verify_rejects_tamperedList_andUnknownKey() throws {
        var list = try makeList([UUID()])
        let verifier = BlocklistVerifier(publicKeys: [1: key.publicKey])
        list = Blocklist(v: 1, key: 1, revoked: list.revoked + [UUID()],   // added w/o re-signing
                         updated: list.updated, sig: list.sig)
        XCTAssertThrowsError(try verifier.verify(list))
        let unknown = Blocklist(v: 1, key: 5, revoked: [], updated: "2026-07-17", sig: "AA==")
        XCTAssertThrowsError(try BlocklistVerifier(publicKeys: [1: key.publicKey]).verify(unknown))
    }

    func test_cache_roundTrips() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cache = BlocklistCache(directory: dir)
        let list = try makeList([UUID()])
        cache.save(list)
        XCTAssertEqual(BlocklistCache(directory: dir).load(), list)
        XCTAssertNil(BlocklistCache(directory:
            FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)).load())
    }
}
