import AVFoundation
import CoreGraphics

/// Generates a still frame to represent a recording in the Recordings section.
enum RecordingThumbnail {
    /// A representative frame (~1s in, or the start for very short clips),
    /// downscaled to fit `maxPixel`. Uses the modern async generator (no
    /// deprecated `copyCGImage`). Returns nil if the asset has no decodable
    /// frame. Run off the main actor — decoding can take a beat.
    static func frame(for url: URL, maxPixel: CGFloat = 480) async -> CGImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        // Tolerate a window so we land on a real keyframe rather than failing.
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        let target = CMTime(seconds: 1, preferredTimescale: 600)
        return try? await generator.image(at: target).image
    }
}
