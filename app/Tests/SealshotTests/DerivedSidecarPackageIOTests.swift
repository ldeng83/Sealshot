import XCTest
import CryptoKit
import CoreGraphics
@testable import Sealshot

/// `derived.json` living inside the package, and the one way it can vanish.
///
/// `writeSealPackage` builds a FRESH `FileWrapper(directoryWithFileWrappers:)`
/// from the entries it knows about and writes it atomically over the package.
/// Anything it does not know about is therefore deleted by any save — an
/// autosave would silently wipe the sidecar. The carry-forward is what stops
/// that, and it is the fragile part of this design: every future entry-adding
/// change has to preserve it, so these tests exist to fail loudly rather than
/// leave someone discovering it from a user report.
@MainActor
final class DerivedSidecarPackageIOTests: XCTestCase {

    let identity = IdentityKey.generate()
    lazy var gen = KeyGeneration.make(publicKey: identity.publicKey)
    var crypto: SealPackageCryptoContext {
        SealPackageCryptoContext(publicKey: identity.publicKey, generation: gen, identity: identity)
    }
    var plain: SealPackageCryptoContext { SealPackageCryptoContext(publicKey: nil, identity: nil) }

    var url: URL!
    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("derived-io-\(UUID().uuidString).seal")
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: url) }

    private func makeImage() -> CGImage {
        let ctx = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    private func sidecar(_ payload: Data = Data([7, 7, 7])) -> DerivedSidecar {
        var s = DerivedSidecar()
        s.setSection(TextLayoutSection.name, data: payload)
        return s
    }

    private func write(_ ctx: SealPackageCryptoContext) throws {
        let img = makeImage()
        _ = try writeSealPackage(to: url, source: img, composite: img, annotations: [],
                                 crop: nil, crypto: ctx)
    }

    // MARK: - Round trip

    func test_readsBackWhatWasWritten_plaintext() throws {
        try write(plain)
        try writeDerivedSidecar(sidecar(), into: url, crypto: plain)

        let read = try XCTUnwrap(readDerivedSidecar(at: url, crypto: plain))
        XCTAssertEqual(read.section(TextLayoutSection.name), Data([7, 7, 7]))
    }

    func test_readsBackWhatWasWritten_encrypted() throws {
        try write(crypto)
        try writeDerivedSidecar(sidecar(), into: url, crypto: crypto)

        let read = try XCTUnwrap(readDerivedSidecar(at: url, crypto: crypto))
        XCTAssertEqual(read.section(TextLayoutSection.name), Data([7, 7, 7]))
    }

    func test_absentSidecarReadsAsNil() throws {
        try write(plain)
        XCTAssertNil(readDerivedSidecar(at: url, crypto: plain))
    }

    func test_sidecarIsSealedWhenThePackageIs() throws {
        // It holds the capture's full text, which is precisely what must not sit
        // in the clear once Enhanced Security is on.
        try write(crypto)
        try writeDerivedSidecar(sidecar(), into: url, crypto: crypto)

        let raw = try XCTUnwrap(sealEntryData("derived.json", at: url))
        XCTAssertNil(try? DerivedSidecar.decode(raw),
                     "a sealed sidecar must not be readable as plain JSON")
    }

    // MARK: - The carry-forward

    func test_resavingThePackageKeepsTheSidecar_plaintext() throws {
        try write(plain)
        try writeDerivedSidecar(sidecar(), into: url, crypto: plain)

        try write(plain)   // an ordinary save — e.g. an autosave after an edit

        let read = try XCTUnwrap(readDerivedSidecar(at: url, crypto: plain),
                                 "a save deleted the sidecar")
        XCTAssertEqual(read.section(TextLayoutSection.name), Data([7, 7, 7]))
    }

    func test_resavingThePackageKeepsTheSidecar_encrypted() throws {
        try write(crypto)
        try writeDerivedSidecar(sidecar(), into: url, crypto: crypto)

        try write(crypto)

        let read = try XCTUnwrap(readDerivedSidecar(at: url, crypto: crypto),
                                 "a save deleted the sidecar")
        XCTAssertEqual(read.section(TextLayoutSection.name), Data([7, 7, 7]))
    }

    func test_carryForwardSurvivesRepeatedSaves() throws {
        try write(plain)
        try writeDerivedSidecar(sidecar(), into: url, crypto: plain)
        for _ in 0..<3 { try write(plain) }

        XCTAssertNotNil(readDerivedSidecar(at: url, crypto: plain))
    }

    // MARK: - Anchoring

    func test_sidecarWriteLeavesTheManifestAlone() throws {
        // The anchor is the manifest's modifiedISO8601. If writing the sidecar
        // touched it, every section would invalidate itself the instant it was
        // stored.
        try write(plain)
        let before = try SealManifest.decodeJSON(
            from: try XCTUnwrap(sealEntryData("manifest.json", at: url)))

        try writeDerivedSidecar(sidecar(), into: url, crypto: plain)

        let after = try SealManifest.decodeJSON(
            from: try XCTUnwrap(sealEntryData("manifest.json", at: url)))
        XCTAssertEqual(before.modifiedISO8601, after.modifiedISO8601)
    }

    func test_sidecarWriteLeavesThePackageMtimeAlone() throws {
        // `LibraryIndexStore.reconcile` compares stored row mtimes against disk.
        // Letting a sidecar write bump it would make every capture look changed
        // and drag the whole library through a needless re-index.
        try write(plain)
        let before = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date

        try writeDerivedSidecar(sidecar(), into: url, crypto: plain)

        let after = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        XCTAssertEqual(before, after)
    }

    // MARK: - Unreadable is not fatal

    func test_unreadableSidecarIsIgnoredRatherThanThrowing() throws {
        // Derived data is always recomputable, so a corrupt or unopenable
        // sidecar must degrade to "recompute it" and never block opening a
        // capture.
        try write(plain)
        try SealContainer.rewritingTail(["derived.json": Data([0xFF, 0xFE, 0xFD])], in: url)

        XCTAssertNil(readDerivedSidecar(at: url, crypto: plain))
    }

    func test_corruptSidecarDoesNotBreakASave() throws {
        try write(plain)
        try SealContainer.rewritingTail(["derived.json": Data([0xFF, 0xFE, 0xFD])], in: url)

        XCTAssertNoThrow(try write(plain))
    }
}
