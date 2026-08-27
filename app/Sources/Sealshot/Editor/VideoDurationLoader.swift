import AVFoundation
import Foundation

/// Resolves (and caches) a recording's duration for the Library / strip badges.
/// Plain `.mov`/`.mp4` load via `AVURLAsset`; encrypted `.sealrec` go through
/// the sealed resource loader. Results are memoised per URL for the session so
/// repeated strip/Library refreshes don't re-decode.
@MainActor
enum VideoDurationLoader {

    private static var cache: [URL: Double] = [:]

    /// The cached duration in seconds, if already resolved — synchronous, for
    /// drawing without awaiting.
    static func cachedSeconds(for url: URL) -> Double? { cache[url.standardizedFileURL] }

    /// Resolve the duration in seconds (nil if unreadable), caching the result.
    @discardableResult
    static func seconds(for url: URL) async -> Double? {
        let key = url.standardizedFileURL
        if let hit = cache[key] { return hit }

        let resolved: Double?
        if url.pathExtension.lowercased() == RecordingsLibrary.encryptedExtension {
            if let contentKey = (try? EncryptionSession.shared.contentKey(for: .recordings)) ?? nil {
                resolved = await SealedRecordingPlayer.duration(sealrecURL: url, key: contentKey)
            } else {
                resolved = nil
            }
        } else {
            let asset = AVURLAsset(url: url)
            let secs = (try? await asset.load(.duration))?.seconds
            resolved = (secs?.isFinite == true && (secs ?? 0) > 0) ? secs : nil
        }
        if let resolved { cache[key] = resolved }
        return resolved
    }
}
