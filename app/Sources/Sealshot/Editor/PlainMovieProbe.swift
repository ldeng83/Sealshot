import AVFoundation
import CoreGraphics

/// Reads the facts a plain `.mov`/`.mp4` recording can still tell us about
/// itself: how long it runs and how big its frames are.
///
/// A recording saved without the package wrapper has no manifest, so the Info
/// panel would otherwise show nothing at all — which reads as a bug rather
/// than as the documented trade-off. Everything here comes from the asset;
/// nothing is invented.
enum PlainMovieProbe {
    struct Result {
        let durationSeconds: Double?
        let pixelSize: CGSize?
    }

    /// Both values are optional and independent: a truncated or still-being-
    /// written file may answer one and not the other, and a partial answer
    /// beats an empty panel.
    static func read(_ url: URL) async -> Result {
        let asset = AVURLAsset(url: url)
        let duration = try? await asset.load(.duration).seconds
        var size: CGSize?
        if let track = try? await asset.loadTracks(withMediaType: .video).first {
            // The natural size ignores rotation; applying the preferred
            // transform is what makes a portrait recording report portrait
            // dimensions rather than its landscape storage size.
            if let natural = try? await track.load(.naturalSize),
               let transform = try? await track.load(.preferredTransform) {
                let oriented = natural.applying(transform)
                size = CGSize(width: abs(oriented.width), height: abs(oriented.height))
            }
        }
        return Result(
            durationSeconds: (duration?.isFinite == true && (duration ?? 0) > 0) ? duration : nil,
            pixelSize: size)
    }
}
