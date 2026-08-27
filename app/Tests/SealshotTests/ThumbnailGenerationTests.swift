import XCTest
import AppKit
@testable import Sealshot

/// Library thumbnails after the session unlocks.
///
/// Reported from the field: after logging in, every capture in the Library
/// showed a grey placeholder while the editor strip was fine. Launching at
/// login draws the grid before the user unlocks; a sealed capture's thumbnail
/// needs the session identity to decrypt and returns nil without it. The card
/// loads its thumbnail from `.task(id:)` keyed on path + mtime, neither of
/// which changes on unlock, so every card visible at that moment kept its
/// placeholder for the rest of the run — cards scrolled into view afterwards
/// loaded normally, which is why a couple of tiles further down looked right.
@MainActor
final class ThumbnailGenerationTests: XCTestCase {

    func testTaskID_changesWhenTheLockStateChanges() {
        let before = ThumbnailGeneration.shared.taskID("/tmp/a.seal#123")
        ThumbnailGeneration.shared.bumpForTesting()
        let after = ThumbnailGeneration.shared.taskID("/tmp/a.seal#123")
        XCTAssertNotEqual(before, after,
                          "the id has to change or SwiftUI will not re-run the task")
    }

    /// Distinct items stay distinct: the generation must not collapse two
    /// cards onto one id.
    func testTaskID_staysUniquePerItem() {
        let a = ThumbnailGeneration.shared.taskID("/tmp/a.seal#1")
        let b = ThumbnailGeneration.shared.taskID("/tmp/b.seal#1")
        XCTAssertNotEqual(a, b)
    }

    /// A real lock-state notification drives it, which is what makes unlocking
    /// retry without anything else being wired up.
    func testLockStateNotification_bumpsTheGeneration() async {
        let before = ThumbnailGeneration.shared.taskID("k")
        NotificationCenter.default.post(name: .encryptionLockStateDidChange, object: nil)
        // The observer runs on the main queue; let it drain.
        for _ in 0..<5 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertNotEqual(before, ThumbnailGeneration.shared.taskID("k"))
    }

    /// The store itself must not cache a failure: a retry after unlock has to
    /// actually re-decode rather than return the miss. (This is what makes the
    /// generation bump sufficient on its own.)
    func testThumbnailStore_doesNotCacheAFailedLoad() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("thumb-gen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("capture.seal")
        try Data("x".utf8).write(to: file)

        // First call fails (as a sealed package does while locked), second
        // succeeds (as it does once the identity is available).
        let attempts = Attempts()
        let store = ThumbnailStore(loader: { _, _ in
            attempts.increment() == 1 ? nil : NSImage(size: NSSize(width: 4, height: 4))
        })
        let first = await store.thumbnail(for: file)
        XCTAssertNil(first)
        let second = await store.thumbnail(for: file)
        XCTAssertNotNil(second, "a failed load must not be cached as a miss")
    }

    /// Counter shared with the off-main loader closure.
    private final class Attempts: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() -> Int {
            lock.lock(); defer { lock.unlock() }
            count += 1
            return count
        }
    }
}
