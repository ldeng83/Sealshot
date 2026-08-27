import XCTest
@testable import Sealshot

/// Identity store that reports whether the promptless load path was taken, and
/// can be emptied to model "the key isn't on this Mac".
private final class RecordingIdentityStore: IdentityStore {
    private let backing = InMemoryIdentityStore()
    private(set) var promptlessLoads = 0
    private(set) var gatedLoads = 0

    func save(_ identity: IdentityKey) throws { try backing.save(identity) }
    func load() async throws -> IdentityKey? {
        gatedLoads += 1
        return try await backing.load()
    }
    func loadWithoutUserPresence() throws -> IdentityKey? {
        promptlessLoads += 1
        return try backing.loadWithoutUserPresence()
    }
    func hasStoredIdentity() -> Bool { backing.hasStoredIdentity() }
    func delete() throws { try backing.delete() }
}

@MainActor
final class EncryptionSessionLaunchUnlockTests: XCTestCase {
    private var dir: URL!
    private var store: RecordingIdentityStore!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("launch-unlock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = RecordingIdentityStore()
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func makeSession() -> EncryptionSession {
        let s = EncryptionSession(identityStore: store, capsuleFolder: dir,
                                  defaults: UserDefaults(suiteName: "lu-\(UUID().uuidString)")!)
        s.isEnabled = true
        return s
    }

    func testUnlocksWithoutTheAuthGate() async throws {
        let identity = IdentityKey.generate()
        try store.save(identity)
        let s = makeSession()
        try s.provision(publicKey: identity.publicKey,
                        generation: KeyGeneration.make(publicKey: identity.publicKey))

        let ok = try s.unlockWithoutPresence()

        XCTAssertTrue(ok)
        XCTAssertTrue(s.isUnlocked)
        XCTAssertEqual(store.promptlessLoads, 1)
        XCTAssertEqual(store.gatedLoads, 0, "the launch path must not run the Touch ID gate")
        XCTAssertNotNil(try s.contentKey(for: .history), "a real unlock vends content keys")
    }

    /// Every lock-state observer (overlay teardown, OCR backfill restart,
    /// pending open-URL flush) hangs off this notification — a silent unlock
    /// that skipped it would leave the UI showing a lock screen over an
    /// unlocked session.
    func testPostsTheLockStateNotification() async throws {
        let identity = IdentityKey.generate()
        try store.save(identity)
        let s = makeSession()
        try s.provision(publicKey: identity.publicKey,
                        generation: KeyGeneration.make(publicKey: identity.publicKey))
        let posted = expectation(forNotification: .encryptionLockStateDidChange,
                                 object: nil, handler: nil)

        _ = try s.unlockWithoutPresence()

        await fulfillment(of: [posted], timeout: 1)
    }

    func testFailsClosedWhenTheKeyIsGone() async throws {
        let identity = IdentityKey.generate()
        try store.save(identity)
        let s = makeSession()
        try s.provision(publicKey: identity.publicKey,
                        generation: KeyGeneration.make(publicKey: identity.publicKey))
        try store.delete()

        let ok = try s.unlockWithoutPresence()

        XCTAssertFalse(ok)
        XCTAssertFalse(s.isUnlocked, "no key means locked, never half-unlocked")
    }

    func testAlreadyUnlockedIsANoOp() async throws {
        let identity = IdentityKey.generate()
        try store.save(identity)
        let s = makeSession()
        try s.provision(publicKey: identity.publicKey,
                        generation: KeyGeneration.make(publicKey: identity.publicKey))
        _ = try s.unlockWithoutPresence()

        let ok = try s.unlockWithoutPresence()

        XCTAssertTrue(ok)
        XCTAssertEqual(store.promptlessLoads, 1, "a second call must not re-read the key")
    }
}
