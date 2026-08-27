import XCTest
@testable import Sealshot

@MainActor
final class CaptureDragPayloadTests: XCTestCase {

    func test_captureList_roundTrips() {
        let urls = [URL(fileURLWithPath: "/tmp/a.seal", isDirectory: false),
                    URL(fileURLWithPath: "/tmp/b c.seal", isDirectory: false)]
        let data = CaptureDragPayload.captureListData(for: urls)
        let decoded = CaptureDragPayload.captureURLs(fromListData: data)
        XCTAssertEqual(decoded.map(\.path), urls.map(\.path))
        // A `.seal` is a single-file container, so decoded URLs are file-form
        // — they must compare equal to directory-listing URLs.
        XCTAssertTrue(decoded.allSatisfy { !$0.hasDirectoryPath })
    }

    func test_captureList_garbageDecodesEmpty() {
        XCTAssertEqual(CaptureDragPayload.captureURLs(fromListData: Data("junk".utf8)), [])
    }

    /// Drop-to-import must ignore our own files: library `.seal` packages
    /// (dropping a tile back onto the grid) and drag temp renders.
    func test_importableDropURLs_filtersOwnFiles() {
        let save = URL(fileURLWithPath: "/Users/x/Pictures/Sealshot", isDirectory: true)
        let temp = URL(fileURLWithPath: "/var/tmp-drag", isDirectory: true)
        let external = URL(fileURLWithPath: "/Users/x/Downloads/photo.png")
        let ownSeal = save.appendingPathComponent("shot.seal", isDirectory: true)
        let dragTemp = temp.appendingPathComponent("abc/Name.png")
        let result = CaptureDragPayload.importableDropURLs(
            [external, ownSeal, dragTemp, save], saveFolder: save, tempDir: temp)
        XCTAssertEqual(result, [external])
    }

    func test_fileName_sanitizesAndDefaults() {
        let src = CaptureDragPayload.Source(
            url: URL(fileURLWithPath: "/tmp/x.seal"), displayName: "a/b: c", isVideo: false)
        XCTAssertEqual(CaptureDragPayload.fileName(for: src, type: .png), "a-b- c.png")
        let dot = CaptureDragPayload.Source(
            url: URL(fileURLWithPath: "/tmp/x.seal"), displayName: ".hidden", isVideo: false)
        XCTAssertEqual(CaptureDragPayload.fileName(for: dot, type: .png), "_hidden.png")
    }
}

// MARK: - The identity type on a real pasteboard

/// The Library's drag is AppKit (SwiftUI cannot drag a multi-selection), and the
/// in-app identity — the real `.seal` URLs a sidebar collection drop needs —
/// rides on the FIRST dragging item, an `NSFilePromiseProvider` subclass. These
/// pin that the type and its payload actually survive a pasteboard write, which
/// is the half of the drag the sidebar depends on.
@MainActor
final class CaptureDragIdentityPasteboardTests: XCTestCase {

    private func makeProvider(urls: [URL]) -> NSPasteboardWriting {
        let source = CaptureDragPayload.Source(
            url: urls[0], displayName: "Shot", isVideo: false)
        let data = CaptureDragPayload.captureListData(for: urls)
        return CaptureDragPayload.identityPromiseItem(
            for: source, session: nil, captureListData: data).provider
    }

    private func write(_ writer: NSPasteboardWriting, name: String) -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name(name))
        pb.clearContents()
        pb.writeObjects([writer])
        return pb
    }

    func test_identityType_isAdvertisedOnThePasteboard() {
        let urls = [URL(fileURLWithPath: "/tmp/a.seal", isDirectory: true)]
        let pb = write(makeProvider(urls: urls), name: "sealshot-test-advertise")
        let types = (pb.pasteboardItems?.first?.types ?? []).map(\.rawValue)
        XCTAssertTrue(types.contains(CaptureDragPayload.captureListTypeIdentifier),
                      "identity type missing; pasteboard offered: \(types)")
    }

    /// The whole selection has to survive, not just the grabbed tile.
    func test_identityData_roundTripsThroughThePasteboard() {
        let urls = [URL(fileURLWithPath: "/tmp/a.seal", isDirectory: true),
                    URL(fileURLWithPath: "/tmp/b.seal", isDirectory: true),
                    URL(fileURLWithPath: "/tmp/c.seal", isDirectory: true)]
        let pb = write(makeProvider(urls: urls), name: "sealshot-test-roundtrip")
        let type = NSPasteboard.PasteboardType(CaptureDragPayload.captureListTypeIdentifier)
        guard let data = pb.data(forType: type) else {
            return XCTFail("no identity data on the pasteboard")
        }
        XCTAssertEqual(CaptureDragPayload.captureURLs(fromListData: data).map(\.path),
                       urls.map(\.path))
    }

    /// The file promise has to stay intact alongside the identity — it is what
    /// Finder accepts, and a drag that loses it exports nothing.
    func test_filePromiseTypeSurvivesAlongsideTheIdentity() {
        let urls = [URL(fileURLWithPath: "/tmp/a.seal", isDirectory: true)]
        let pb = write(makeProvider(urls: urls), name: "sealshot-test-promise")
        let types = (pb.pasteboardItems?.first?.types ?? []).map(\.rawValue)
        XCTAssertTrue(types.contains("com.apple.NSFilePromiseItemMetaData"),
                      "file promise metadata missing; pasteboard offered: \(types)")
        XCTAssertTrue(types.contains("com.apple.pasteboard.promised-file-content-type"),
                      "promised content type missing; pasteboard offered: \(types)")
    }

    /// The item carries NO `public.file-url`: it is promise-only, which is why
    /// a SwiftUI `.onDrop` cannot see the identity. SwiftUI bridges a promise
    /// item into a provider for the promised FILE, and the custom own-process
    /// type does not survive that bridging — the reason the sidebar's drop
    /// target has to be AppKit, like the drag itself.
    func test_theDragItemIsPromiseOnly_notAFileURL() {
        let urls = [URL(fileURLWithPath: "/tmp/a.seal", isDirectory: true)]
        let pb = write(makeProvider(urls: urls), name: "sealshot-test-nofileurl")
        let types = (pb.pasteboardItems?.first?.types ?? []).map(\.rawValue)
        XCTAssertFalse(types.contains("public.file-url"))
    }
}

// MARK: - Promise vs plain file URL

/// The Library went promise-ONLY when multi-file export arrived, which silently
/// broke every drop target that cannot resolve a file promise — Terminal path
/// insert, canvas insert, anything reading only `public.file-url`. Finder kept
/// working (it does support promises), so the loss was invisible. These pin the
/// policy that brings the Library back in line with the recent strip.
@MainActor
final class CaptureDragWriterPolicyTests: XCTestCase {

    func test_singleEagerlyRenderableItem_usesAPlainFileURL() {
        XCTAssertFalse(CaptureDragPayload.needsPromises(count: 1, anyRequiresPromise: false))
    }

    /// Multi stays promises: every write lands post-drop where the progress
    /// sheet can count it, and writers must be homogeneous.
    func test_multiSelection_usesPromises() {
        XCTAssertTrue(CaptureDragPayload.needsPromises(count: 2, anyRequiresPromise: false))
        XCTAssertTrue(CaptureDragPayload.needsPromises(count: 9, anyRequiresPromise: false))
    }

    /// Encrypted video cannot be rendered eagerly at all.
    func test_anythingNeedingAPromise_forcesPromisesEvenForOneItem() {
        XCTAssertTrue(CaptureDragPayload.needsPromises(count: 1, anyRequiresPromise: true))
    }

    // MARK: The single-item writer serves both worlds

    private func singleItem(urls: [URL]) -> NSPasteboardItem {
        CaptureDragPayload.identityURLItem(
            fileURL: URL(fileURLWithPath: "/tmp/render/Shot.png"),
            captureListData: CaptureDragPayload.captureListData(for: urls))
    }

    func test_singleItemCarriesAFileURL_forTerminalAndTheCanvas() {
        let item = singleItem(urls: [URL(fileURLWithPath: "/tmp/a.seal", isDirectory: true)])
        let pb = NSPasteboard(name: NSPasteboard.Name("sealshot-test-eager-url"))
        pb.clearContents()
        pb.writeObjects([item])
        let types = (pb.pasteboardItems?.first?.types ?? []).map(\.rawValue)
        XCTAssertTrue(types.contains("public.file-url"),
                      "no file URL — Terminal has nothing to insert; offered: \(types)")
    }

    /// …and still the identity, or fixing Terminal would break the sidebar drop.
    func test_singleItemAlsoCarriesTheIdentity_forSidebarDrops() {
        let urls = [URL(fileURLWithPath: "/tmp/a.seal", isDirectory: true)]
        let item = singleItem(urls: urls)
        let pb = NSPasteboard(name: NSPasteboard.Name("sealshot-test-eager-identity"))
        pb.clearContents()
        pb.writeObjects([item])
        let type = NSPasteboard.PasteboardType(CaptureDragPayload.captureListTypeIdentifier)
        guard let data = pb.data(forType: type) else {
            return XCTFail("identity missing from the single-item drag")
        }
        XCTAssertEqual(CaptureDragPayload.captureURLs(fromListData: data).map(\.path),
                       urls.map(\.path))
    }
}
