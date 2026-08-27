import XCTest
@testable import Sealshot

/// Opening a `.seal` from outside the app — Finder's "Open With", a
/// double-click, a drop. Two rules: a capture already in the library is
/// OPENED (copying it would give the user two of the same capture), and one
/// from elsewhere is copied in first, honouring the scratch toggle.
@MainActor
final class AdoptCaptureTests: XCTestCase {
    private var saveFolder: URL!
    private var elsewhere: URL!

    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Adopt-\(UUID().uuidString)")
        saveFolder = root.appendingPathComponent("Library")
        elsewhere = root.appendingPathComponent("Downloads")
        for dir in [saveFolder!, elsewhere!] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: saveFolder.deletingLastPathComponent())
    }

    @discardableResult
    private func makeCapture(in folder: URL, named name: String) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try SealContainer.write(entries: [("manifest.json", Data(#"{"version":14}"#.utf8))], to: url)
        return url
    }

    /// The destination a capture is adopted INTO, which is the decision the
    /// scratch toggle governs.
    private func destination(addToLibrary: Bool) -> URL {
        ScratchCapture.destination(saveFolder: saveFolder, addToLibrary: addToLibrary)
    }

    func testScratchOff_adoptsIntoTheLibraryRoot() {
        XCTAssertEqual(destination(addToLibrary: true).standardizedFileURL.path,
                       saveFolder.standardizedFileURL.path)
    }

    func testScratchOn_adoptsIntoScratch() {
        let dest = destination(addToLibrary: false)
        XCTAssertEqual(dest.lastPathComponent, ScratchCapture.folderName)
        XCTAssertTrue(ScratchCapture.isScratch(dest.appendingPathComponent("a.seal")))
    }

    /// Adopting must never overwrite a capture that happens to share a name.
    func testAdoptedName_dedupesAgainstAnExistingCapture() throws {
        try makeCapture(in: saveFolder, named: "shot.seal")
        let name = CaptureConfig.uniqueName(base: "shot", ext: "seal") { candidate in
            FileManager.default.fileExists(
                atPath: saveFolder.appendingPathComponent(candidate).path)
        }
        XCTAssertNotEqual(name, "shot.seal")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: saveFolder.appendingPathComponent("shot.seal").path), "the original stands")
    }

    /// The reason for re-stamping: the strip, Recents and the Date sort all
    /// order by CAPTURE date, so an adopted capture keeping its original one
    /// is filed months back and never appears in the surfaces that show
    /// recent work.
    func testAdoptedCapture_isDatedNowAndLabelledImported() throws {
        let old = Date(timeIntervalSince1970: 1_600_000_000)   // years ago
        let url = saveFolder.appendingPathComponent("old.seal")
        let manifest = SealManifest(
            version: SealManifest.currentVersion,
            createdISO8601: ISO8601DateFormatter().string(from: old),
            modifiedISO8601: ISO8601DateFormatter().string(from: old),
            sourceSize: .init(width: 4, height: 4), sourceApp: nil,
            showingEnhanced: false, metadata: nil)
        try SealContainer.write(entries: [("manifest.json", try manifest.encodeJSON())], to: url)

        try SealMetadataStore.stampAsAdopted(at: url, kind: .importedImage)

        let after = try SealMetadataStore.readManifest(at: url)
        let created = try XCTUnwrap(ISO8601DateFormatter().date(from: after.createdISO8601))
        XCTAssertEqual(created.timeIntervalSinceNow, 0, accuracy: 5,
                       "an adopted capture is dated as of now, so it sorts newest")
        XCTAssertEqual(after.captureKind, .importedImage,
                       "the original capture time is overwritten, so the kind says why")
    }

    /// A rewrite must carry every other field forward — losing provenance or
    /// user metadata to re-date a capture would be a bad trade.
    func testStamping_preservesTheRestOfTheManifest() throws {
        let url = saveFolder.appendingPathComponent("keep.seal")
        let manifest = SealManifest(
            version: SealManifest.currentVersion,
            createdISO8601: ISO8601DateFormatter().string(from: Date()),
            modifiedISO8601: ISO8601DateFormatter().string(from: Date()),
            sourceSize: .init(width: 640, height: 480), sourceApp: "Safari",
            showingEnhanced: false, metadata: nil, ocrText: "find-me")
        try SealContainer.write(entries: [("manifest.json", try manifest.encodeJSON())], to: url)

        try SealMetadataStore.stampAsAdopted(at: url, kind: .importedImage)

        let after = try SealMetadataStore.readManifest(at: url)
        XCTAssertEqual(after.sourceApp, "Safari")
        XCTAssertEqual(after.ocrText, "find-me")
        XCTAssertEqual(after.sourceSize.width, 640)
    }

    /// A capture copied in is a real, readable capture at the far end — the
    /// copy carries the container verbatim.
    func testAdoptedCapture_isReadableAtTheDestination() throws {
        let source = try makeCapture(in: elsewhere, named: "outside.seal")
        let dest = saveFolder.appendingPathComponent("outside.seal")
        try FileManager.default.copyItem(at: source, to: dest)

        XCTAssertTrue(SealContainer.isContainer(dest))
        XCTAssertEqual(try SealContainer.Reader(url: dest).data("manifest.json"),
                       Data(#"{"version":14}"#.utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path),
                      "the original is copied, not moved — it isn't ours to remove")
    }
}
