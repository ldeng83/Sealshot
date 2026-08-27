import XCTest
@testable import Sealshot

@MainActor
final class ThumbnailStoreTests: XCTestCase {

    /// Thread-safe decode counter (the store decodes on detached tasks).
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func increment() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    private func tempPNG() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThumbnailStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("a.png")
        let ctx = CGContext(data: nil, width: 10, height: 10, bitsPerComponent: 8,
                            bytesPerRow: 40, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
        try rep.representation(using: .png, properties: [:])!.write(to: url)
        return url
    }

    func test_secondRequestHitsCache() async throws {
        let url = try tempPNG()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let counter = Counter()
        let store = ThumbnailStore(loader: { u, crypto in
            counter.increment()
            return captureThumbnailImage(for: u, crypto: crypto)
        })
        let first = await store.thumbnail(for: url)
        let second = await store.thumbnail(for: url)
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertEqual(counter.value, 1, "second request must be served from cache")
    }

    func test_failedLoadIsNotCachedAsImage() async {
        let store = ThumbnailStore(loader: { _, _ in nil })
        let image = await store.thumbnail(for: URL(fileURLWithPath: "/nope.png"))
        XCTAssertNil(image)
    }

    func test_cacheKey_changesWithMtime() {
        let url = URL(fileURLWithPath: "/shots/a.seal")
        let a = ThumbnailStore.cacheKey(for: url, mtime: Date(timeIntervalSince1970: 1))
        let b = ThumbnailStore.cacheKey(for: url, mtime: Date(timeIntervalSince1970: 2))
        XCTAssertNotEqual(a, b)
    }
}
