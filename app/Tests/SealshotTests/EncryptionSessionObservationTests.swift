import XCTest
import Observation
@testable import Sealshot

@MainActor
final class EncryptionSessionObservationTests: XCTestCase {
    private func makeSession() -> (EncryptionSession, InMemoryIdentityStore) {
        let store = InMemoryIdentityStore()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("obs-\(UUID().uuidString)", isDirectory: true)
        let s = EncryptionSession(identityStore: store, capsuleFolder: dir,
                                  defaults: UserDefaults(suiteName: "obs-\(UUID().uuidString)")!)
        return (s, store)
    }

    func testUnlockTriggersObservation() async throws {
        let (s, store) = makeSession()
        s.isEnabled = true
        try store.save(.generate())
        nonisolated(unsafe) var observed = false
        withObservationTracking { _ = s.isUnlocked } onChange: { observed = true }
        _ = try await s.unlock()
        XCTAssertTrue(observed)
    }

    func testLockPostsNotification() async throws {
        let (s, store) = makeSession()
        s.isEnabled = true
        try store.save(.generate())
        _ = try await s.unlock()
        let expectation = expectation(forNotification: .encryptionLockStateDidChange, object: nil)
        s.lock()
        await fulfillment(of: [expectation], timeout: 1)
    }

    func testUnlockPostsNotification() async throws {
        let (s, store) = makeSession()
        s.isEnabled = true
        try store.save(.generate())
        let expectation = expectation(forNotification: .encryptionLockStateDidChange, object: nil)
        _ = try await s.unlock()
        await fulfillment(of: [expectation], timeout: 1)
    }
}
