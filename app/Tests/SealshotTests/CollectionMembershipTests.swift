import XCTest
@testable import Sealshot

@MainActor
final class CollectionMembershipTests: XCTestCase {
    // Mirrors the package-creation helper from TestSealFactory: creates a
    // plaintext (unencrypted) temp .seal package using writeSealPackage +
    // SealMetadataStore.apply, exactly as other SealMetadataStore tests do.

    private func makeSeal() throws -> URL {
        let metadata = CaptureMetadata(
            generatedTitle: "Test Capture", userTitle: nil,
            tags: [], category: .other, confidence: 1.0,
            generatorVersion: 1, visualTagVersion: 0,
            summary: nil, summaryVersion: 0)
        let url = try TestSealFactory.makePlaintextSeal(metadata: metadata)
        return url
    }

    func test_setCollections_roundTrips() throws {
        let seal = try makeSeal()
        defer { try? FileManager.default.removeItem(at: seal) }
        let a = UUID(); let b = UUID()
        try SealMetadataStore.setCollections([a, b], to: seal)
        let manifest = try SealMetadataStore.readManifest(at: seal)
        XCTAssertEqual(Set(manifest.collectionIDs ?? []), [a, b])
    }

    func test_setWorkflow_preservesCollectionIDs() throws {
        let seal = try makeSeal()
        defer { try? FileManager.default.removeItem(at: seal) }
        let a = UUID()
        try SealMetadataStore.setCollections([a], to: seal)
        try SealMetadataStore.setWorkflow(isFavorite: true, to: seal)   // a different write path
        let manifest = try SealMetadataStore.readManifest(at: seal)
        XCTAssertEqual(manifest.isFavorite, true)
        XCTAssertEqual(manifest.collectionIDs ?? [], [a], "membership must survive a favorite toggle")
    }

    // Regression test: editor save path (writeSealPackage) must carry forward
    // collectionIDs. Before the Fix 1 patch the field defaulted to nil on
    // every re-save, silently wiping collection membership.
    func test_writeSealPackage_preservesCollectionIDs() throws {
        let seal = try makeSeal()
        defer { try? FileManager.default.removeItem(at: seal) }

        let a = UUID()
        try SealMetadataStore.setCollections([a], to: seal)

        // Re-save via the editor path (simulates autosave/explicit save).
        // Read back existing contents first — mirrors what the editor does.
        let crypto = SealPackageCryptoContext(publicKey: nil, identity: nil)
        let contents = try readSealPackage(at: seal, crypto: crypto)
        try writeSealPackage(
            to: seal,
            source: contents.source,
            composite: contents.composite,
            annotations: contents.annotations,
            crop: contents.crop,
            focus: contents.focus,
            enhanced: contents.enhanced,
            showingEnhanced: contents.showingEnhanced,
            crypto: crypto
        )

        let manifest = try SealMetadataStore.readManifest(at: seal)
        XCTAssertEqual(manifest.collectionIDs ?? [], [a],
                       "editor save (writeSealPackage) must preserve collection membership")
    }

    func test_setCollections_emptyClearsMembership() throws {
        let seal = try makeSeal()
        defer { try? FileManager.default.removeItem(at: seal) }
        try SealMetadataStore.setCollections([UUID()], to: seal)
        try SealMetadataStore.setCollections([], to: seal)
        let manifest = try SealMetadataStore.readManifest(at: seal)
        XCTAssertEqual(manifest.collectionIDs ?? [], [])
    }
}
