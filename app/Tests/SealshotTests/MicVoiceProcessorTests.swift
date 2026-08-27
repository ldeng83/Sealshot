import XCTest
import AVFoundation
import CoreMedia
@testable import Sealshot

final class MicVoiceProcessorTests: XCTestCase {
    /// Raw mono mic CMSampleBuffer: Float32, mono, at `sampleRate`.
    private func monoMic(sampleRate: Double = 48_000, frames: Int, fill: (Int) -> Float) -> CMSampleBuffer {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: true)!
        let pcm = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames))!
        pcm.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames { pcm.floatChannelData![0][i] = fill(i) }
        var asbd = fmt.streamDescription.pointee
        var fd: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fd)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil,
            refcon: nil, formatDescription: fd!, sampleCount: frames, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sb)
        CMSampleBufferSetDataBufferFromAudioBufferList(sb!, blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil, flags: 0, bufferList: pcm.mutableAudioBufferList)
        return sb!
    }

    func test_buffersUntilAFullAPMFrame_thenEmitsCanonicalStereo() {
        let proc = MicVoiceProcessor(noiseSuppression: false, gainControl: false)
        // 300 mono samples @48k (<480) → nothing emitted yet.
        XCTAssertTrue(proc.process(monoMic(frames: 300) { _ in 0.2 }).isEmpty)
        // Another 300 → ≥480 buffered → at least one APM frame → canonical output.
        let out = proc.process(monoMic(frames: 300) { _ in 0.2 })
        XCTAssertFalse(out.isEmpty, "should emit once a full 10ms APM frame is available")
        XCTAssertEqual(out.count % 2, 0, "canonical output is interleaved stereo")
    }

    /// Verifies that the total number of canonical stereo frames emitted across
    /// many irregular-sized process() calls is conserved — i.e. no ongoing
    /// per-call sample loss from resampler tail truncation.
    ///
    /// We feed N = 96 000 mono samples @48 kHz (≈ 2 s) in irregular chunk sizes
    /// (137, 480, 53, 991, … repeated in a cycle) so the converter is exercised
    /// many times with non-aligned boundaries. The expected output count follows
    /// the CANONICAL rate (48 kHz native since the resample-grit fix, so a 1:1
    /// pass): N * canonical/48000 stereo frames.
    ///
    /// Tolerance reasoning:
    ///   • Converter priming latency (polyphase filter delay): ≤ 200 samples
    ///   • Up-to-479 samples still queued in `pending` (unbuffered tail): ≤ 480
    ///   • One APM frame worth of output not yet emitted: 480
    ///   • Total one-time slack ≈ 1 160 → use abs < 2 000 (≈ 45 ms)
    ///
    /// If the resampler tail is silently dropped on each convert call the error
    /// would SCALE with the number of chunks (≈ 175) — far beyond 2 000 — which
    /// would expose the bug and cause this assertion to fail.
    func test_sampleConservation_acrossOddSizedChunks() {
        let proc = MicVoiceProcessor(noiseSuppression: false, gainControl: false)

        // Build a chunk list whose total is exactly 96 000 samples.
        // Irregular base pattern repeats; the last chunk is trimmed to hit 96 000.
        let pattern = [137, 480, 53, 991, 480, 200, 737, 480, 1024, 300,
                       480, 800, 53, 480, 991, 137, 480, 300, 480, 200]
        let target = 96_000
        var chunks: [Int] = []
        var total = 0
        var idx = 0
        while total < target {
            let n = min(pattern[idx % pattern.count], target - total)
            chunks.append(n)
            total += n
            idx += 1
        }
        XCTAssertEqual(total, target, "chunk generation must hit exactly \(target)")

        var totalFloatsReturned = 0
        for n in chunks {
            let buf = monoMic(frames: n) { _ in Float(0.1) }
            totalFloatsReturned += proc.process(buf).count
        }

        // Canonical is interleaved stereo → each stereo frame = 2 floats.
        let emittedStereoFrames = totalFloatsReturned / 2
        let expected = Int(Double(target) * CanonicalAudio.format.sampleRate / 48_000.0)
        let tolerance = 2000 // ≈ 45 ms; see comment above — must NOT grow with chunk count
        XCTAssertLessThan(
            abs(emittedStereoFrames - expected), tolerance,
            "emitted \(emittedStereoFrames) stereo frames, expected ~\(expected) ± \(tolerance); " +
            "error=\(emittedStereoFrames - expected) over \(chunks.count) chunks"
        )
    }

    func test_noiseSuppression_lowersEnergy() {
        let proc = MicVoiceProcessor(noiseSuppression: true, gainControl: false)
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func noise(_ : Int) -> Float {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int(seed >> 40) % 2000 - 1000) / 1000.0 * 0.5
        }
        var inE = 0.0, outE = 0.0
        for _ in 0..<40 {
            let buf = monoMic(frames: 480, fill: noise)
            inE += (CMSampleBufferAudio.floatFrames(buf) ?? []).reduce(0) { $0 + Double($1*$1) }
            outE += proc.process(buf).reduce(0) { $0 + Double($1*$1) }
        }
        XCTAssertGreaterThan(inE, 0)
        XCTAssertLessThan(outE, inE * 0.9, "NS should reduce steady-noise energy")
    }
}
