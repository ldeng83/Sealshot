import XCTest
import AVFoundation
import CoreMedia
@testable import Sealshot

/// MicCanonicalConverter converts raw mic CMSampleBuffers (whatever the
/// hardware format is) to canonical 48 kHz stereo Float32 frames using ONE
/// persistent AVAudioConverter, so any converter/resampler state is kept across
/// buffers (a fresh converter per buffer restarts the resampler → artifacts).
final class MicCanonicalConverterTests: XCTestCase {
    /// A RAW mic-style CMSampleBuffer: Float32, mono, at `sampleRate`, filled
    /// with a sine tone (non-silent).
    private func toneBuffer(sampleRate: Double, frames: Int, pts: CMTime) -> CMSampleBuffer {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                channels: 1, interleaved: true)!
        let pcm = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames))!
        pcm.frameLength = AVAudioFrameCount(frames)
        let ch = pcm.floatChannelData![0]
        for i in 0..<frames { ch[i] = sin(Float(i) * 0.1) * 0.5 }

        var asbd = fmt.streamDescription.pointee
        var fd: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fd)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil,
            refcon: nil, formatDescription: fd!, sampleCount: frames, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sb)
        CMSampleBufferSetDataBufferFromAudioBufferList(sb!, blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil, flags: 0, bufferList: pcm.mutableAudioBufferList)
        return sb!
    }

    func test_convertsMono48kToCanonicalStereoFrames_nonSilent() {
        let conv = MicCanonicalConverter()
        let frames = conv.canonicalFrames(
            from: toneBuffer(sampleRate: 48_000, frames: 4800, pts: CMTime(value: 0, timescale: 48_000)))
        let out = try? XCTUnwrap(frames)
        XCTAssertNotNil(out)
        XCTAssertEqual(out!.count % 2, 0, "canonical output is interleaved stereo")
        // Canonical is now 48 kHz, so 48k mono → 48k stereo is a no-resample
        // mono→stereo copy: ~4800 frames × 2 channels ≈ 9600 interleaved values.
        XCTAssertGreaterThan(out!.count, 8000, "should carry roughly a buffer's worth of stereo frames")
        XCTAssertTrue(out!.contains { abs($0) > 1e-3 }, "converted audio must carry the tone, not silence")
    }

    func test_reusesConverterAcrossBuffers() {
        let conv = MicCanonicalConverter()
        let a = conv.canonicalFrames(
            from: toneBuffer(sampleRate: 48_000, frames: 1024, pts: CMTime(value: 0, timescale: 48_000)))
        let b = conv.canonicalFrames(
            from: toneBuffer(sampleRate: 48_000, frames: 1024, pts: CMTime(value: 1024, timescale: 48_000)))
        XCTAssertNotNil(a)
        XCTAssertNotNil(b)
        XCTAssertTrue(b!.contains { abs($0) > 1e-3 })
    }
}
