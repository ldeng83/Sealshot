import XCTest
@testable import Sealshot

final class ShareModelTests: XCTestCase {
    func testManifestCodableRoundTrip() throws {
        let m = ShareManifest(
            version: 1, note: "hi", includesOriginal: false,
            entries: [ShareManifestEntry(name: "a", kind: .image, uti: "public.png",
                                         title: "Shot", tags: ["x", "y"], segmentIndex: 1)])
        let data = try JSONEncoder().encode(m)
        XCTAssertEqual(try JSONDecoder().decode(ShareManifest.self, from: data), m)
    }

    func testPassphraseCapsuleCodableRoundTrip() throws {
        let c = ShareCapsule.passphrase(PassphraseCapsule(
            salt: Data([1, 2, 3]), iterations: 600_000, sealed: Data([9, 9]), hint: "pet"))
        let data = try JSONEncoder().encode(c)
        XCTAssertEqual(try JSONDecoder().decode(ShareCapsule.self, from: data), c)
    }

    func testIdentityCapsuleCodableRoundTrip() throws {
        let cap = KeyCapsule(generationID: UUID(), encapsulated: Data([1]), ciphertext: Data([2]))
        let c = ShareCapsule.identity(cap)
        let data = try JSONEncoder().encode(c)
        XCTAssertEqual(try JSONDecoder().decode(ShareCapsule.self, from: data), c)
    }

    func testUnknownCapsuleTypeDecodesToUnknown() throws {
        // A future "selfDecrypt" capsule a v1 reader has never seen.
        let json = Data(#"{"type":"selfDecrypt","blob":"AAAA"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(ShareCapsule.self, from: json), .unknown)
    }

    func testHeaderCodableRoundTrip() throws {
        let h = ShareHeader(version: 1, createdAt: Date(timeIntervalSince1970: 1000),
                            expiresAt: nil,
                            capsules: [.passphrase(PassphraseCapsule(
                                salt: Data([1, 2, 3]), iterations: 600_000, sealed: Data([9, 9]), hint: nil))])
        let data = try JSONEncoder().encode(h)
        XCTAssertEqual(try JSONDecoder().decode(ShareHeader.self, from: data), h)
    }

    func testManifest_collectionDescriptor_roundTrips() throws {
        let desc = ShareCollectionDescriptor(id: UUID(), name: "Q3 Bugs")
        let m = ShareManifest(version: 2, note: nil, includesOriginal: false,
                              entries: [], collection: desc)
        let data = try JSONEncoder().encode(m)
        let back = try JSONDecoder().decode(ShareManifest.self, from: data)
        XCTAssertEqual(back.collection, desc)
    }

    func testManifest_absentCollectionKey_decodesNil() throws {
        // A manifest JSON written before this field existed has no "collection" key.
        let json = #"{"version":1,"includesOriginal":false,"entries":[]}"#.data(using: .utf8)!
        let back = try JSONDecoder().decode(ShareManifest.self, from: json)
        XCTAssertNil(back.collection)
    }
}
