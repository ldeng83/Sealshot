import XCTest
import AppKit
import CoreGraphics
@testable import Sealshot

/// Autosave must do its heavy encode/encrypt/write OFF the main thread, while
/// still producing a correct `.seal` package and reporting completion on the
/// main thread. These lock in the background-save refactor's semantics.
@MainActor
final class EditorBackgroundAutosaveTests: XCTestCase {

    // Setting `config.saveFolder` persists to UserDefaults.standard (the app
    // domain, since these tests are hosted by the app). Snapshot and restore it
    // so a test's temp folder never leaks into the user's real save location.
    private static let saveFolderKey = "captureConfig.saveFolder"
    private var savedSaveFolder: Any?

    override func setUpWithError() throws {
        savedSaveFolder = UserDefaults.standard.object(forKey: Self.saveFolderKey)
    }
    override func tearDownWithError() throws {
        if let savedSaveFolder {
            UserDefaults.standard.set(savedSaveFolder, forKey: Self.saveFolderKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.saveFolderKey)
        }
    }

    private func solidImage(_ w: Int, _ h: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    private func tempFolderConfig() throws -> (CaptureConfig, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("autosave-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let config = CaptureConfig()
        config.saveFolder = dir
        return (config, dir)
    }

    func test_autosaveWritesSealPackageAndReportsURL() throws {
        let (config, dir) = try tempFolderConfig()
        defer { try? FileManager.default.removeItem(at: dir) }
        let saver = EditorSaveCoordinator(config: config)
        let state = EditorState(sourceImage: solidImage(120, 90), sourceURL: nil)
        state.markDirty()

        let done = expectation(description: "autosave completes")
        var resultURL: URL?
        saver.autosave(state: state) { result in
            if case .success(let url) = result { resultURL = url }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)

        let url = try XCTUnwrap(resultURL, "autosave did not report a URL")
        XCTAssertEqual(url.pathExtension, "seal")
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir))
        XCTAssertFalse(isDir.boolValue, "a .seal is a single-file container")
        XCTAssertTrue(SealContainer.isContainer(url))

        // The package must contain a valid, non-degenerate composite that
        // preserves the source's 4:3 aspect (exact pixel size scales with the
        // rendering display's backing factor, so assert aspect, not dimensions).
        // No crypto identity in tests → plaintext package → plain PNG entry.
        let pngData = try XCTUnwrap(sealEntryData("composite.png", at: url),
                                    "composite.png missing from package")
        let rep = try XCTUnwrap(NSBitmapImageRep(data: pngData))
        XCTAssertGreaterThanOrEqual(rep.pixelsWide, 120, "composite must be at least source resolution")
        XCTAssertEqual(Double(rep.pixelsWide) / Double(rep.pixelsHigh), 120.0 / 90.0, accuracy: 0.01,
                       "composite must preserve the source aspect ratio")
    }

    func test_autosaveOverwritesExistingPackageInPlace() throws {
        let (config, dir) = try tempFolderConfig()
        defer { try? FileManager.default.removeItem(at: dir) }
        let saver = EditorSaveCoordinator(config: config)
        let state = EditorState(sourceImage: solidImage(120, 90), sourceURL: nil)
        state.markDirty()

        // First save establishes the package + URL.
        let first = expectation(description: "first save")
        var firstURL: URL?
        saver.autosave(state: state) { r in
            if case .success(let u) = r { firstURL = u }
            first.fulfill()
        }
        wait(for: [first], timeout: 5)
        let url = try XCTUnwrap(firstURL)
        state.sourceURL = url

        // Second save with the same URL must overwrite in place (same path).
        let second = expectation(description: "second save")
        var secondURL: URL?
        saver.autosave(state: state) { r in
            if case .success(let u) = r { secondURL = u }
            second.fulfill()
        }
        wait(for: [second], timeout: 5)
        XCTAssertEqual(secondURL, url, "re-saving a .seal must overwrite in place, not fork a new file")
    }
}
