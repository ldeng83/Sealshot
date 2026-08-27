import XCTest
@testable import Sealshot

final class InMemoryIdentityStoreTests: XCTestCase {
    func testStoreAndRetrieve() async throws {
        let store = InMemoryIdentityStore()
        let identity = IdentityKey.generate()
        try store.save(identity)
        let loaded = try await store.load()
        XCTAssertEqual(loaded?.rawRepresentation, identity.rawRepresentation)
    }

    func testLoadEmptyReturnsNil() async throws {
        let v = try await InMemoryIdentityStore().load()
        XCTAssertNil(v)
    }

    func testDeleteRemoves() async throws {
        let store = InMemoryIdentityStore()
        try store.save(.generate())
        try store.delete()
        let v = try await store.load()
        XCTAssertNil(v)
    }

    func testHasStoredIdentity_tracksSaveAndDelete() throws {
        let store = InMemoryIdentityStore()
        XCTAssertFalse(store.hasStoredIdentity())
        try store.save(.generate())
        XCTAssertTrue(store.hasStoredIdentity())
        try store.delete()
        XCTAssertFalse(store.hasStoredIdentity())
    }
}
