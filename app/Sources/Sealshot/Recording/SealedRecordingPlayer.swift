import AVFoundation
import CryptoKit
import Foundation

/// Serves a `.sealrec` container to AVPlayer by decrypting only the byte ranges
/// the player asks for — no plaintext ever hits disk. Registered on a custom
/// `sealrec://` scheme so AVFoundation routes loading through this delegate.
final class SealedRecordingResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
    private let reader: SealedChunkFile.Reader
    /// Serial queue: `reader` reads are serialized (one FileHandle).
    let queue = DispatchQueue(label: "com.seal-shot.sealrec.loader")
    private static let responseCap = 1 << 20   // 1 MiB per respond, bounds memory

    init(reader: SealedChunkFile.Reader) { self.reader = reader }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        if let info = request.contentInformationRequest {
            info.contentType = reader.originalUTI
            info.contentLength = reader.originalLength
            info.isByteRangeAccessSupported = true
        }
        guard let dataRequest = request.dataRequest else {
            request.finishLoading()
            return true
        }
        do {
            let end = dataRequest.requestsAllDataToEndOfResource
                ? reader.originalLength
                : min(dataRequest.requestedOffset + Int64(dataRequest.requestedLength), reader.originalLength)
            var pos = dataRequest.currentOffset
            while pos < end {
                let want = Int(min(Int64(Self.responseCap), end - pos))
                let chunk = try reader.read(offset: pos, length: want)
                if chunk.isEmpty { break }            // EOF
                dataRequest.respond(with: chunk)
                pos += Int64(chunk.count)
                if chunk.count < want { break }        // clamped at EOF
            }
            request.finishLoading()
        } catch {
            request.finishLoading(with: error)
        }
        return true
    }
}

/// Builds an `AVPlayer` that plays an encrypted `.sealrec` via the resource
/// loader. Owns (retains) the delegate for the player's lifetime — without this
/// the loader would be deallocated and playback would stall.
@MainActor
final class SealedRecordingPlayer {
    let player: AVPlayer
    private let loader: SealedRecordingResourceLoader

    /// A payload inside a container: same streaming path, shifted by the
    /// entry's offset. No extraction — a recording is gigabytes.
    convenience init(payload: VideoPayloadLocation, key: SymmetricKey) throws {
        try self.init(sealrecURL: payload.fileURL, key: key, baseOffset: payload.offset)
    }

    init(sealrecURL: URL, key: SymmetricKey, baseOffset: Int64 = 0) throws {
        let reader = try SealedChunkFile.Reader(url: sealrecURL, key: key,
                                                baseOffset: baseOffset)
        let loader = SealedRecordingResourceLoader(reader: reader)
        self.loader = loader
        // A custom scheme forces AVFoundation through the resource loader. The
        // path keeps the original name so the player has something to log.
        var comps = URLComponents()
        comps.scheme = "sealrec"
        comps.host = "recording"
        comps.path = "/" + sealrecURL.lastPathComponent
        let asset = AVURLAsset(url: comps.url!)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        self.player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
    }

    /// Load just the duration (seconds) of an encrypted recording via the same
    /// resource-loader path, without spinning up a full player. Returns nil if
    /// it can't be read. The loader is kept alive across the async load.
    static func duration(sealrecURL: URL, key: SymmetricKey) async -> Double? {
        guard let reader = try? SealedChunkFile.Reader(url: sealrecURL, key: key) else { return nil }
        let loader = SealedRecordingResourceLoader(reader: reader)
        var comps = URLComponents()
        comps.scheme = "sealrec"
        comps.host = "recording"
        comps.path = "/" + sealrecURL.lastPathComponent
        guard let url = comps.url else { return nil }
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        let seconds = (try? await asset.load(.duration))?.seconds
        withExtendedLifetime(loader) {}
        guard let seconds, seconds.isFinite, seconds > 0 else { return nil }
        return seconds
    }
}
