import AppKit

/// In-memory cache of downsampled capture thumbnails, keyed by path + mtime so
/// a re-saved capture is re-decoded while stale entries simply age out of the
/// NSCache. Decoding runs off the main thread; bookkeeping (cache + in-flight
/// coalescing) stays on the main actor where the SwiftUI cards already live.
@MainActor
final class ThumbnailStore {

    static let shared = ThumbnailStore()

    /// Carries a freshly decoded NSImage from the detached decode task back to
    /// the main actor. The image is created off-main and not touched again
    /// until it lands here, so the transfer is safe even though NSImage itself
    /// isn't Sendable.
    private struct DecodedThumbnail: @unchecked Sendable {
        let image: NSImage?
    }

    private let cache = NSCache<NSString, NSImage>()
    private var inFlight: [NSString: Task<DecodedThumbnail, Never>] = [:]
    private let loader: @Sendable (URL, SealPackageCryptoContext) -> NSImage?

    init(countLimit: Int = 400,
         loader: @escaping @Sendable (URL, SealPackageCryptoContext) -> NSImage?
            = { captureThumbnailImage(for: $0, crypto: $1) }) {
        cache.countLimit = countLimit
        self.loader = loader
    }

    /// Cache key: standardized path + mtime epoch. mtime nil (stat failed)
    /// still yields a stable key so the file caches under "0".
    nonisolated static func cacheKey(for url: URL, mtime: Date?) -> NSString {
        "\(url.standardizedFileURL.path)#\(mtime?.timeIntervalSince1970 ?? 0)" as NSString
    }

    /// Cached thumbnail for `url`, decoding off-main on a miss. Concurrent
    /// requests for the same key coalesce onto one decode.
    func thumbnail(for url: URL) async -> NSImage? {
        let mtime = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
        let key = Self.cacheKey(for: url, mtime: mtime)
        if let hit = cache.object(forKey: key) { return hit }
        if let pending = inFlight[key] { return await pending.value.image }

        let loader = self.loader
        // Resolve the crypto context on the main actor (the session is
        // main-isolated) so the off-main decode can decrypt sealed thumbnails
        // when the session is unlocked.
        let crypto = SealPackageCryptoContext.current()
        let task = Task.detached(priority: .userInitiated) {
            DecodedThumbnail(image: loader(url, crypto))
        }
        inFlight[key] = task
        let image = await task.value.image
        inFlight[key] = nil
        if let image { cache.setObject(image, forKey: key) }
        return image
    }

    /// Drop all cached thumbnails. Called when the encryption session relocks
    /// so decrypted (sealed-capture) thumbnails don't linger in memory.
    func clear() {
        cache.removeAllObjects()
    }
}
