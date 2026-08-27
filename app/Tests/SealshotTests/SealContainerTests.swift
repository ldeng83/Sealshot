import XCTest
@testable import Sealshot

/// The single-file `.seal` container. This is the layer every capture's bytes
/// pass through, so the tests care about three things above all: a round trip
/// loses nothing, the archive is a REAL zip (any tool can open a plaintext
/// capture), and a manifest edit doesn't rewrite the payload.
final class SealContainerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SealContainerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func url(_ name: String) -> URL { root.appendingPathComponent(name) }

    private let manifest = Data(#"{"version":14}"#.utf8)

    // MARK: Round trip

    func testRoundTrip_returnsEveryEntryByteForByte() throws {
        let file = url("a.seal")
        let source = Data((0..<5_000).map { UInt8($0 % 251) })
        try SealContainer.write(entries: [
            ("source.png", source),
            ("thumbnail.png", Data("thumb".utf8)),
            ("manifest.json", manifest),
        ], to: file)

        let reader = try SealContainer.Reader(url: file)
        XCTAssertEqual(try reader.data("source.png"), source)
        XCTAssertEqual(try reader.data("thumbnail.png"), Data("thumb".utf8))
        XCTAssertEqual(try reader.data("manifest.json"), manifest)
        XCTAssertEqual(Set(reader.entries.map(\.name)),
                       ["source.png", "thumbnail.png", "manifest.json"])
    }

    func testRoundTrip_handlesEmptyAndBinaryEntries() throws {
        let file = url("b.seal")
        let binary = Data((0...255).map(UInt8.init))
        try SealContainer.write(entries: [
            ("empty.bin", Data()),
            ("binary.bin", binary),
            ("manifest.json", manifest),
        ], to: file)

        let reader = try SealContainer.Reader(url: file)
        XCTAssertEqual(try reader.data("empty.bin"), Data())
        XCTAssertEqual(try reader.data("binary.bin"), binary)
    }

    /// The manifest goes last whatever order the caller passes, because the
    /// cheap-tail-rewrite trick depends on it.
    func testManifest_isAlwaysTheLastEntry() throws {
        let file = url("c.seal")
        try SealContainer.write(entries: [
            ("manifest.json", manifest),
            ("source.png", Data("src".utf8)),
        ], to: file)
        let reader = try SealContainer.Reader(url: file)
        XCTAssertEqual(reader.entries.last?.name, "manifest.json")
    }

    // MARK: A real zip, not a lookalike

    /// A plaintext capture must open with ordinary tools — that is half the
    /// point of choosing zip over a private container.
    func testArchive_readsAsAZipWithTheSystemUnzip() throws {
        let file = url("d.seal")
        try SealContainer.write(entries: [
            ("source.png", Data("hello".utf8)),
            ("manifest.json", manifest),
        ], to: file)

        let out = root.appendingPathComponent("unzipped")
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-q", file.path, "-d", out.path]
        try unzip.run()
        unzip.waitUntilExit()
        XCTAssertEqual(unzip.terminationStatus, 0, "system unzip must accept the archive")
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("source.png")),
                       Data("hello".utf8))
    }

    // MARK: Streaming

    /// Entries are STORED, so a payload's bytes sit contiguously at a known
    /// offset — this is what keeps a multi-gigabyte recording streamable
    /// instead of needing extraction first.
    func testEntryBytes_areContiguousAtTheReportedOffset() throws {
        let file = url("e.seal")
        let payload = Data((0..<10_000).map { UInt8(($0 * 7) % 256) })
        try SealContainer.write(entries: [
            ("payload.bin", payload),
            ("manifest.json", manifest),
        ], to: file)

        let reader = try SealContainer.Reader(url: file)
        let entry = try XCTUnwrap(reader.entry("payload.bin"))
        XCTAssertEqual(entry.size, UInt64(payload.count))

        // Read a slice straight out of the middle of the file, the way the
        // recording player does, without going through the container at all.
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        try handle.seek(toOffset: entry.dataOffset + 4_096)
        let slice = try XCTUnwrap(handle.read(upToCount: 512))
        XCTAssertEqual(slice, payload[4_096..<4_608])
    }

    // MARK: Cheap metadata edits

    /// The reason the manifest is last: editing it must not rewrite payloads.
    func testRewritingManifest_leavesPayloadBytesUntouched() throws {
        let file = url("f.seal")
        let payload = Data((0..<200_000).map { UInt8($0 % 253) })
        try SealContainer.write(entries: [
            ("payload.bin", payload),
            ("thumbnail.png", Data("thumb".utf8)),
            ("manifest.json", manifest),
        ], to: file)
        let before = try XCTUnwrap(SealContainer.Reader(url: file).entry("payload.bin"))

        let edited = Data(#"{"version":14,"tags":["one","two","three"]}"#.utf8)
        try SealContainer.rewritingManifest(edited, in: file)

        let reader = try SealContainer.Reader(url: file)
        XCTAssertEqual(try reader.data("manifest.json"), edited)
        XCTAssertEqual(try reader.data("payload.bin"), payload, "payload survives verbatim")
        XCTAssertEqual(try reader.data("thumbnail.png"), Data("thumb".utf8))
        XCTAssertEqual(reader.entry("payload.bin")?.dataOffset, before.dataOffset,
                       "payload did not move — the edit only touched the tail")
    }

    /// Shrinking metadata is the same path; the archive must not keep a stale
    /// tail behind the new directory.
    func testRewritingManifest_handlesAShorterManifest() throws {
        let file = url("g.seal")
        try SealContainer.write(entries: [
            ("source.png", Data("src".utf8)),
            ("manifest.json", Data(#"{"version":14,"tags":["a","b","c","d","e"]}"#.utf8)),
        ], to: file)

        try SealContainer.rewritingManifest(Data("{}".utf8), in: file)
        let reader = try SealContainer.Reader(url: file)
        XCTAssertEqual(try reader.data("manifest.json"), Data("{}".utf8))
        XCTAssertEqual(try reader.data("source.png"), Data("src".utf8))
        XCTAssertEqual(reader.entries.count, 2, "no duplicate manifest entry left behind")
    }

    func testRewrittenArchive_isStillValidToTheSystemUnzip() throws {
        let file = url("h.seal")
        try SealContainer.write(entries: [
            ("source.png", Data("src".utf8)),
            ("manifest.json", manifest),
        ], to: file)
        try SealContainer.rewritingManifest(Data(#"{"version":14,"edited":true}"#.utf8), in: file)

        let test = Process()
        test.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        test.arguments = ["-tq", file.path]
        try test.run()
        test.waitUntilExit()
        XCTAssertEqual(test.terminationStatus, 0,
                       "a tail rewrite must leave a well-formed archive (CRCs included)")
    }

    /// The derived sidecar (Live Text / extraction caches) is written on its
    /// own, so it lives in the tail too — adding one to a package that never
    /// had it must not disturb the payload either.
    func testRewritingTail_addsTheDerivedSidecarWithoutMovingPayloads() throws {
        let file = url("t1.seal")
        let payload = Data((0..<50_000).map { UInt8($0 % 249) })
        try SealContainer.write(entries: [
            ("source.png", payload), ("manifest.json", manifest),
        ], to: file)
        let before = try XCTUnwrap(SealContainer.Reader(url: file).entry("source.png"))

        try SealContainer.rewritingTail(["derived.json": Data(#"{"liveText":[]}"#.utf8)], in: file)

        let reader = try SealContainer.Reader(url: file)
        XCTAssertEqual(try reader.data("derived.json"), Data(#"{"liveText":[]}"#.utf8))
        XCTAssertEqual(try reader.data("manifest.json"), manifest, "manifest carried forward")
        XCTAssertEqual(try reader.data("source.png"), payload)
        XCTAssertEqual(reader.entry("source.png")?.dataOffset, before.dataOffset)
    }

    /// A nil value removes a tail entry (dropping a stale cache).
    func testRewritingTail_removesAnEntryWhenGivenNil() throws {
        let file = url("t2.seal")
        try SealContainer.write(entries: [
            ("source.png", Data("src".utf8)),
            ("derived.json", Data("{}".utf8)),
            ("manifest.json", manifest),
        ], to: file)

        try SealContainer.rewritingTail(["derived.json": nil], in: file)
        let reader = try SealContainer.Reader(url: file)
        XCTAssertNil(reader.entry("derived.json"))
        XCTAssertEqual(try reader.data("manifest.json"), manifest)
        XCTAssertEqual(try reader.data("source.png"), Data("src".utf8))
    }

    /// Rewriting a PAYLOAD in place would corrupt every offset after it, so
    /// the API refuses rather than silently producing a broken archive.
    func testRewritingTail_refusesANonTailEntry() throws {
        let file = url("t3.seal")
        try SealContainer.write(entries: [
            ("source.png", Data("src".utf8)), ("manifest.json", manifest),
        ], to: file)
        XCTAssertThrowsError(try SealContainer.rewritingTail(["source.png": Data("x".utf8)],
                                                             in: file))
    }

    /// The STREAMING writer must produce byte-identical layout to the
    /// in-memory one — the video path uses it for gigabyte payloads.
    func testStreamingWrite_roundTripsAndMatchesOffsets() throws {
        let payload = Data((0..<80_000).map { UInt8(($0 * 13) % 251) })
        let scratch = url("payload-src.bin")
        try payload.write(to: scratch)

        let file = url("s1.seal")
        try SealContainer.write(sources: [
            ("payload", .file(scratch)),
            ("manifest.json", .data(manifest)),
        ], to: file)

        let reader = try SealContainer.Reader(url: file)
        XCTAssertEqual(try reader.data("payload"), payload)
        XCTAssertEqual(try reader.data("manifest.json"), manifest)

        // And the payload is readable straight from its offset.
        let entry = try XCTUnwrap(reader.entry("payload"))
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        try handle.seek(toOffset: entry.dataOffset)
        XCTAssertEqual(try handle.read(upToCount: 64), payload.prefix(64))

        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        check.arguments = ["-tq", file.path]
        try check.run(); check.waitUntilExit()
        XCTAssertEqual(check.terminationStatus, 0, "streamed archive must be well-formed")
    }

    // MARK: Format detection

    func testIsContainer_distinguishesFromTheLegacyDirectoryPackage() throws {
        let file = url("i.seal")
        try SealContainer.write(entries: [("manifest.json", manifest)], to: file)
        XCTAssertTrue(SealContainer.isContainer(file))

        let directory = url("legacy.seal")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try manifest.write(to: directory.appendingPathComponent("manifest.json"))
        XCTAssertFalse(SealContainer.isContainer(directory),
                       "a directory package is the OLD format, not a container")

        XCTAssertFalse(SealContainer.isContainer(url("missing.seal")))
    }

    func testReader_refusesSomethingThatIsNotAContainer() throws {
        let notAnArchive = url("j.seal")
        try Data("just some bytes".utf8).write(to: notAnArchive)
        XCTAssertThrowsError(try SealContainer.Reader(url: notAnArchive))
    }

    // MARK: Atomicity

    /// A failed write must never leave a half-file where a whole capture was.
    func testWrite_replacesAnExistingContainerAtomically() throws {
        let file = url("k.seal")
        try SealContainer.write(entries: [
            ("source.png", Data("first".utf8)), ("manifest.json", manifest),
        ], to: file)
        try SealContainer.write(entries: [
            ("source.png", Data("second".utf8)), ("manifest.json", manifest),
        ], to: file)

        let reader = try SealContainer.Reader(url: file)
        XCTAssertEqual(try reader.data("source.png"), Data("second".utf8))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(".tmp") }
        XCTAssertTrue(leftovers.isEmpty, "no temp files left behind: \(leftovers)")
    }
}
