import XCTest
@testable import Sealshot

/// Converting legacy directory packages to containers. The rules that matter:
/// nothing is lost, encrypted captures are never decrypted to do it, a
/// package that won't convert is left intact rather than damaged, and the
/// library's sense of time is undisturbed.
@MainActor
final class SealFormatConverterTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConvertTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A legacy package: a directory of flat entries.
    @discardableResult
    private func makeLegacy(_ name: String, entries: [String: Data]) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for (entry, data) in entries { try data.write(to: url.appendingPathComponent(entry)) }
        return url
    }

    func testConvert_preservesEveryEntryByteForByte() throws {
        let source = Data((0..<9_000).map { UInt8($0 % 251) })
        let url = try makeLegacy("a.seal", entries: [
            "manifest.json": Data(#"{"version":14}"#.utf8),
            "source.png": source,
            "composite.png": Data("composite".utf8),
        ])

        try SealFormatConverter.convert(url)

        XCTAssertTrue(SealContainer.isContainer(url), "converted in place, same path")
        let reader = try SealContainer.Reader(url: url)
        XCTAssertEqual(try reader.data("source.png"), source)
        XCTAssertEqual(try reader.data("composite.png"), Data("composite".utf8))
        XCTAssertEqual(try reader.data("manifest.json"), Data(#"{"version":14}"#.utf8))
    }

    /// Sealed entries are carried across as opaque bytes: conversion never
    /// needs a key, so it works with the session locked and an encrypted
    /// capture is never in the clear on disk.
    func testConvert_carriesSealedEntriesWithoutDecrypting() throws {
        let sealed = Data([0xAA, 0xBB, 0xCC, 0xDD])
        let url = try makeLegacy("locked.seal", entries: [
            "lock.json": Data(#"{"capsule":"x"}"#.utf8),
            "manifest.json": sealed,
            "source.png": sealed,
        ])

        try SealFormatConverter.convert(url)
        let reader = try SealContainer.Reader(url: url)
        XCTAssertEqual(try reader.data("manifest.json"), sealed, "still sealed, byte for byte")
        XCTAssertNotNil(reader.entry("lock.json"))
    }

    /// The index compares stored mtimes against disk, and trashed items age by
    /// theirs — bumping every package would force a re-index and reset the
    /// trash retention clock.
    func testConvert_preservesModificationDate() throws {
        let url = try makeLegacy("dated.seal", entries: ["manifest.json": Data("{}".utf8)])
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: when], ofItemAtPath: url.path)

        try SealFormatConverter.convert(url)

        let after = try XCTUnwrap(FileManager.default.attributesOfItem(
            atPath: url.path)[.modificationDate] as? Date)
        // Within reconcile's 1ms tolerance, not "within a second": a coarser
        // restore makes every converted package look changed on every pass,
        // which is a re-index/notify/reload loop, not a rounding detail.
        XCTAssertEqual(after.timeIntervalSince1970, when.timeIntervalSince1970,
                       accuracy: 0.001)
    }

    /// Sub-second precision specifically: `FileManager.setAttributes` truncates
    /// the fraction, which is what caused the loop.
    func testConvert_preservesSubSecondModificationTime() throws {
        let url = try makeLegacy("frac.seal", entries: ["manifest.json": Data("{}".utf8)])
        let when = Date(timeIntervalSince1970: 1_700_000_000.123_456)
        var times = [timespec(tv_sec: 1_700_000_000, tv_nsec: 123_456_000),
                     timespec(tv_sec: 1_700_000_000, tv_nsec: 123_456_000)]
        XCTAssertEqual(utimensat(AT_FDCWD, url.path, &times, 0), 0)

        try SealFormatConverter.convert(url)

        var after = stat()
        XCTAssertEqual(stat(url.path, &after), 0)
        let restored = Double(after.st_mtimespec.tv_sec)
            + Double(after.st_mtimespec.tv_nsec) / 1_000_000_000
        XCTAssertEqual(restored, when.timeIntervalSince1970, accuracy: 0.001)
    }

    func testConvert_isIdempotent() throws {
        let url = try makeLegacy("twice.seal", entries: ["manifest.json": Data("{}".utf8)])
        try SealFormatConverter.convert(url)
        let before = try Data(contentsOf: url)
        try SealFormatConverter.convert(url)   // already a container: no-op
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    /// An empty or unreadable package is LEFT ALONE. Converting is
    /// housekeeping; it must never be the reason a capture is lost.
    func testConvert_refusesAnEmptyPackageAndLeavesItIntact() throws {
        let url = try makeLegacy("empty.seal", entries: [:])
        XCTAssertThrowsError(try SealFormatConverter.convert(url))
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue, "still the original package")
    }

    // MARK: What the sweep picks up

    func testPendingPackages_listsOnlyLegacyDirectories_newestFirst() throws {
        let old = try makeLegacy("old.seal", entries: ["manifest.json": Data("{}".utf8)])
        let new = try makeLegacy("new.seal", entries: ["manifest.json": Data("{}".utf8)])
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)],
            ofItemAtPath: old.path)
        // An already-converted capture, and a non-capture file.
        let container = root.appendingPathComponent("done.seal")
        try SealContainer.write(entries: [("manifest.json", Data("{}".utf8))], to: container)
        try Data("x".utf8).write(to: root.appendingPathComponent("notes.txt"))

        let pending = SealFormatConverter.pendingPackages(in: [root])
        XCTAssertEqual(pending.map(\.lastPathComponent), ["new.seal", "old.seal"],
                       "legacy only, newest first")
        _ = new
    }

    func testPendingPackages_isEmptyOnceEverythingIsConverted() throws {
        let url = try makeLegacy("a.seal", entries: ["manifest.json": Data("{}".utf8)])
        try SealFormatConverter.convert(url)
        XCTAssertTrue(SealFormatConverter.pendingPackages(in: [root]).isEmpty)
    }
}
