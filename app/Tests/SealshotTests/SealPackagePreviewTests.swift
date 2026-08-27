import XCTest
@testable import Sealshot

/// The `.seal` reader the Quick Look extension uses. It runs in a separate,
/// sandboxed process with no crypto session and no keychain, so the rule it
/// must never break is: an ENCRYPTED package produces nothing. A preview is a
/// convenience; the encryption is the product.
///
/// (The type lives in the extension target. These tests compile a copy into
/// the test host — see `SealPackagePreview` below — so the contract is
/// pinned even though the appex itself has no test bundle.)
final class SealPackagePreviewTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SealPreviewTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makePackage(_ name: String, entries: [String: Data]) throws -> URL {
        let pkg = root.appendingPathComponent(name)
        try SealContainer.write(entries: entries.map { ($0.key, $0.value) }, to: pkg)
        return pkg
    }

    private let manifest = Data(#"{"version":13}"#.utf8)
    private let png = Data("fake-png-bytes".utf8)

    // MARK: The refusal that matters

    /// `lock.json` present = codec v5, every entry sealed. No preview, and no
    /// attempt to produce one.
    func testEncryptedPackage_yieldsNothing() throws {
        let pkg = try makePackage("locked.seal", entries: [
            "lock.json": Data(#"{"generation":3}"#.utf8),
            "manifest.json": Data("sealed-bytes-not-json".utf8),
            "thumbnail.png": Data("sealed-bytes".utf8),
        ])
        XCTAssertTrue(SealPackagePreview.isEncrypted(package: pkg))
        XCTAssertNil(SealPackagePreview.imageData(in: pkg, preferComposite: false))
        XCTAssertNil(SealPackagePreview.imageData(in: pkg, preferComposite: true))
    }

    /// A package this process cannot parse is treated as encrypted: refusing to
    /// render something unrecognised is the safe direction to fail.
    func testUnreadableManifest_countsAsEncrypted() throws {
        let pkg = try makePackage("garbled.seal", entries: [
            "manifest.json": Data("not json at all".utf8),
            "thumbnail.png": png,
        ])
        XCTAssertTrue(SealPackagePreview.isEncrypted(package: pkg))
        XCTAssertNil(SealPackagePreview.imageData(in: pkg, preferComposite: false))
    }

    func testMissingManifest_countsAsEncrypted() throws {
        let pkg = try makePackage("bare.seal", entries: ["thumbnail.png": png])
        XCTAssertTrue(SealPackagePreview.isEncrypted(package: pkg))
    }

    /// A legacy DIRECTORY package has no preview from out here either — the
    /// extension only knows containers, and the app converts in the
    /// background. Refusing beats rendering something half-understood.
    func testLegacyDirectoryPackage_yieldsNothing() throws {
        let pkg = root.appendingPathComponent("legacy.seal", isDirectory: true)
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        try manifest.write(to: pkg.appendingPathComponent("manifest.json"))
        try png.write(to: pkg.appendingPathComponent("thumbnail.png"))
        XCTAssertTrue(SealPackagePreview.isEncrypted(package: pkg))
        XCTAssertNil(SealPackagePreview.imageData(in: pkg, preferComposite: false))
    }

    // MARK: Plaintext packages

    func testPlaintextPackage_prefersTheThumbnailForIcons() throws {
        let pkg = try makePackage("plain.seal", entries: [
            "manifest.json": manifest,
            "thumbnail.png": Data("thumb".utf8),
            "composite.png": Data("composite".utf8),
        ])
        XCTAssertFalse(SealPackagePreview.isEncrypted(package: pkg))
        XCTAssertEqual(SealPackagePreview.imageData(in: pkg, preferComposite: false),
                       Data("thumb".utf8), "icons want the small one")
        XCTAssertEqual(SealPackagePreview.imageData(in: pkg, preferComposite: true),
                       Data("composite".utf8), "a preview panel wants the full render")
    }

    /// Older packages may lack one entry or the other; either serves.
    func testFallsBackToWhicheverEntryExists() throws {
        let onlyComposite = try makePackage("c.seal", entries: [
            "manifest.json": manifest, "composite.png": Data("composite".utf8),
        ])
        XCTAssertEqual(SealPackagePreview.imageData(in: onlyComposite, preferComposite: false),
                       Data("composite".utf8))

        let onlyThumb = try makePackage("t.seal", entries: [
            "manifest.json": manifest, "thumbnail.png": Data("thumb".utf8),
        ])
        XCTAssertEqual(SealPackagePreview.imageData(in: onlyThumb, preferComposite: true),
                       Data("thumb".utf8))
    }

    func testEmptyEntry_isNotOfferedAsAPreview() throws {
        let pkg = try makePackage("empty.seal", entries: [
            "manifest.json": manifest, "thumbnail.png": Data(),
        ])
        XCTAssertNil(SealPackagePreview.imageData(in: pkg, preferComposite: false))
    }

    func testPackageWithNoImageEntries_yieldsNothing() throws {
        let pkg = try makePackage("meta.seal", entries: ["manifest.json": manifest])
        XCTAssertNil(SealPackagePreview.imageData(in: pkg, preferComposite: false))
    }
}
