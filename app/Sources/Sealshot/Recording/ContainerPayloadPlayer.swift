import AVFoundation
import Foundation

/// Playback for a PLAINTEXT recording stored inside a `.seal` container.
///
/// AVFoundation can open a file, not an entry inside one, and extracting the
/// payload first would mean copying gigabytes every time a recording is
/// opened. Container entries are stored uncompressed and contiguous, so the
/// bytes are simply a byte RANGE of the container — which is exactly what a
/// resource loader serves.
///
/// The encrypted case already works this way (`SealedRecordingPlayer`, whose
/// loader decrypts chunks on demand); this is the same shape with no crypto in
/// the path, so both recording kinds stream rather than extract.
final class ContainerPayloadResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
    private let location: VideoPayloadLocation
    private let contentType: String
    /// Serial: one FileHandle, and AVFoundation will ask concurrently.
    let queue = DispatchQueue(label: "com.seal-shot.container-payload.loader")
    private let handle: FileHandle
    /// Bounds memory per response, matching the encrypted loader.
    private static let responseCap = 1 << 20

    init(location: VideoPayloadLocation, contentType: String) throws {
        self.location = location
        self.contentType = contentType
        self.handle = try FileHandle(forReadingFrom: location.fileURL)
        super.init()
    }

    deinit { try? handle.close() }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource
                        request: AVAssetResourceLoadingRequest) -> Bool {
        if let info = request.contentInformationRequest {
            info.contentType = contentType
            info.contentLength = location.length
            info.isByteRangeAccessSupported = true
        }
        guard let dataRequest = request.dataRequest else {
            request.finishLoading()
            return true
        }
        do {
            // Offsets are relative to the PAYLOAD; the container's own offset
            // is added on every read, never leaked to the player.
            let end = dataRequest.requestsAllDataToEndOfResource
                ? location.length
                : min(dataRequest.requestedOffset + Int64(dataRequest.requestedLength),
                      location.length)
            var pos = dataRequest.currentOffset
            while pos < end {
                let want = Int(min(Int64(Self.responseCap), end - pos))
                try handle.seek(toOffset: UInt64(location.offset + pos))
                guard let chunk = try handle.read(upToCount: want), !chunk.isEmpty else { break }
                dataRequest.respond(with: chunk)
                pos += Int64(chunk.count)
                if chunk.count < want { break }
            }
            request.finishLoading()
        } catch {
            request.finishLoading(with: error)
        }
        return true
    }
}

/// An `AVURLAsset` that plays a plaintext payload out of a container.
enum ContainerPayloadPlayer {
    /// Retained by the caller for as long as the asset is in use: a resource
    /// loader's delegate is held WEAKLY, and a deallocated one stalls playback
    /// silently rather than erroring.
    static func asset(for location: VideoPayloadLocation,
                      contentType: String,
                      named name: String) throws -> (AVURLAsset, ContainerPayloadResourceLoader) {
        let loader = try ContainerPayloadResourceLoader(location: location,
                                                        contentType: contentType)
        // A custom scheme is what forces AVFoundation through the loader.
        var comps = URLComponents()
        comps.scheme = "sealpayload"
        comps.host = "recording"
        comps.path = "/" + name
        let asset = AVURLAsset(url: comps.url!)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        return (asset, loader)
    }
}
