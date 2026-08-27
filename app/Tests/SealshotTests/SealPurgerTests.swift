import XCTest
import Darwin
@testable import Sealshot

final class SealPurgerTests: XCTestCase {

    private func makeURL(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/purger-test/\(name)")
    }

    func test_purgeCandidates_returnsFilesOlderThanCutoff() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)  // arbitrary fixed point
        let old1 = (makeURL("a.seal"), now.addingTimeInterval(-31 * 86_400))
        let old2 = (makeURL("b.seal"), now.addingTimeInterval(-90 * 86_400))
        let fresh = (makeURL("c.seal"), now.addingTimeInterval(-29 * 86_400))

        let result = SealPurger.purgeCandidates(
            [old1, old2, fresh],
            olderThan: 30,
            now: now
        )

        let names = Set(result.map { $0.lastPathComponent })
        XCTAssertEqual(names, ["a.seal", "b.seal"])
    }

    func test_purgeCandidates_emptyForAllFresh() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let fresh1 = (makeURL("a.seal"), now.addingTimeInterval(-1 * 86_400))
        let fresh2 = (makeURL("b.seal"), now)

        let result = SealPurger.purgeCandidates(
            [fresh1, fresh2],
            olderThan: 30,
            now: now
        )

        XCTAssertEqual(result.count, 0)
    }

    func test_purgeCandidates_cutoffIsInclusive() {
        // A file with mtime exactly 30 days ago should NOT be purged
        // (cutoff is "older than", strict less-than).
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let exactly30 = (makeURL("a.seal"), now.addingTimeInterval(-30 * 86_400))

        let result = SealPurger.purgeCandidates(
            [exactly30],
            olderThan: 30,
            now: now
        )

        XCTAssertEqual(result.count, 0)
    }
}

extension SealPurgerTests {
    /// The retention clock is the EXPLICIT deletedAt xattr, not the mtime:
    /// package rewrites (encryption toggles) refresh mtime and used to reset
    /// every trashed item's countdown.
    func test_purgeDeletedFolder_agesByDeletedAtXattr_notMtime() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("purge-xattr-\(UUID().uuidString)", isDirectory: true)
        let deleted = root.appendingPathComponent("Deleted", isDirectory: true)
        try FileManager.default.createDirectory(at: deleted, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let iso = ISO8601DateFormatter()
        let now = Date()

        func makeItem(_ name: String, mtime: Date, deletedAt: Date?) throws -> URL {
            let url = deleted.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data([1]).write(to: url.appendingPathComponent("manifest.json"))
            if let deletedAt {
                let v = iso.string(from: deletedAt)
                _ = v.withCString { setxattr(url.path, SealDeleter.deletedAtXattr, $0, strlen($0), 0, 0) }
            }
            try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
            return url
        }

        // Fresh mtime (rewritten by an encryption toggle) but trashed 3 days ago → PURGED.
        let staleTrash = try makeItem("stale.seal", mtime: now, deletedAt: now.addingTimeInterval(-3 * 86_400))
        // Old mtime but trashed minutes ago → KEPT.
        let freshTrash = try makeItem("fresh.seal", mtime: now.addingTimeInterval(-10 * 86_400), deletedAt: now.addingTimeInterval(-60))
        // Legacy item without the xattr → falls back to mtime (old → purged).
        let legacy = try makeItem("legacy.seal", mtime: now.addingTimeInterval(-10 * 86_400), deletedAt: nil)

        let removed = SealPurger.purgeDeletedFolder(in: root, olderThan: 1, now: now)

        XCTAssertEqual(removed, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleTrash.path), "stale trash purged despite fresh mtime")
        XCTAssertTrue(FileManager.default.fileExists(atPath: freshTrash.path), "freshly trashed kept despite old mtime")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path), "legacy falls back to mtime")
    }
}
