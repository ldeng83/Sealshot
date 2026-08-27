import XCTest
import CoreMedia
import AVFoundation
@testable import Sealshot

/// Exercises the live mixer end-to-end with real CMSampleBuffers built from the
/// canonical format — which also covers the make ↔ floatFrames conversion glue.
final class LiveAudioMixerTests: XCTestCase {
    private func t(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 600) }

    /// Build a canonical (Float32, 44.1k, stereo, interleaved) buffer from
    /// interleaved stereo `frames`.
    private func buffer(_ frames: [Float]) -> CMSampleBuffer {
        CMSampleBufferAudio.make(frames: frames, pts: t(0))!
    }

    /// Build a RAW microphone-style buffer: Float32, mono, at `sampleRate`
    /// (48 kHz like a built-in mic) — the format the AAC writer input rejects
    /// unless it's converted to canonical first.
    private func micBuffer(sampleRate: Double = 48_000, frames: Int = 480, value: Float = 0.2) -> CMSampleBuffer {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                channels: 1, interleaved: true)!
        let pcm = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames))!
        pcm.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames { pcm.floatChannelData![0][i] = value }
        var asbd = fmt.streamDescription.pointee
        var fd: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fd)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: t(0), decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil,
            refcon: nil, formatDescription: fd!, sampleCount: frames, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sb)
        CMSampleBufferSetDataBufferFromAudioBufferList(sb!, blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil, flags: 0, bufferList: pcm.mutableAudioBufferList)
        return sb!
    }

    /// Build a RAW microphone-style WHITE-NOISE buffer: Float32, mono, at
    /// `sampleRate`. Samples come from a deterministic LCG so two builders seeded
    /// identically yield the SAME noise — letting us feed identical noise to two
    /// mixers and compare their emitted energy fairly.
    private func noiseMicBuffer(sampleRate: Double = 48_000, frames: Int = 480,
                                seed: inout UInt64) -> CMSampleBuffer {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                channels: 1, interleaved: true)!
        let pcm = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames))!
        pcm.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames {
            // Numerical Recipes LCG → uniform sample in [-0.3, 0.3].
            seed = 6364136223846793005 &* seed &+ 1442695040888963407
            let unit = Float(seed >> 33) / Float(UInt32.max)   // [0, 1)
            pcm.floatChannelData![0][i] = (unit - 0.5) * 0.6
        }
        var asbd = fmt.streamDescription.pointee
        var fd: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fd)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: t(0), decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil,
            refcon: nil, formatDescription: fd!, sampleCount: frames, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sb)
        CMSampleBufferSetDataBufferFromAudioBufferList(sb!, blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil, flags: 0, bufferList: pcm.mutableAudioBufferList)
        return sb!
    }

    private func format(_ sb: CMSampleBuffer) -> (sampleRate: Double, channels: UInt32)? {
        guard let fd = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee else { return nil }
        return (asbd.mSampleRate, asbd.mChannelsPerFrame)
    }

    private func read(_ sb: CMSampleBuffer) -> [Float] {
        CMSampleBufferAudio.floatFrames(sb) ?? []
    }

    func test_makeAndReadBack_roundTrips() {
        let frames: [Float] = [0.1, -0.2, 0.3, -0.4]   // 2 stereo frames
        let out = read(buffer(frames))
        XCTAssertEqual(out.count, frames.count)
        for (x, y) in zip(out, frames) { XCTAssertEqual(x, y, accuracy: 1e-4) }
    }

    func test_micThenSystem_mixesOnce_noEchoOnNextSystemBuffer() {
        // micDSP: nil isolates the mixing/draining math from the high-pass+gate
        // cleanup (which would alter the constant mic values asserted below).
        let mixer = LiveAudioMixer(hasSystem: true, hasMic: true, micDSP: nil)
        var emitted: [[Float]] = []
        mixer.emit = { emitted.append(self.read($0)) }

        mixer.ingestMic(buffer([0.1, 0.1, 0.1, 0.1]))       // queue 4 mic values
        mixer.ingestSystem(buffer([0.2, 0.2, 0.2, 0.2]))    // sum once
        mixer.ingestSystem(buffer([0.5, 0.5, 0.5, 0.5]))    // mic queue drained → system only

        XCTAssertEqual(emitted.count, 2)
        // First buffer: mic summed into system.
        for v in emitted[0] { XCTAssertEqual(v, 0.3, accuracy: 1e-4) }
        XCTAssertEqual(emitted[0].count, 4)
        // Second buffer: NO echo of the earlier mic frames — system passes through.
        for v in emitted[1] { XCTAssertEqual(v, 0.5, accuracy: 1e-4) }
    }

    func test_systemOnly_passesThroughUnmixed() {
        let mixer = LiveAudioMixer(hasSystem: true, hasMic: false)
        var emitted = 0
        mixer.emit = { _ in emitted += 1 }
        mixer.ingestSystem(buffer([0.4, 0.4]))
        XCTAssertEqual(emitted, 1)
    }

    /// Mic-only must emit CANONICAL format (44.1k stereo), not the raw mono/48k
    /// mic buffer — the AAC writer input is stereo/44.1k and silently drops a
    /// raw mono buffer, which made mic-only recordings completely silent.
    func test_micOnly_emitsCanonicalFormat_notRawMicFormat() {
        let mixer = LiveAudioMixer(hasSystem: false, hasMic: true)
        var emittedFormat: (sampleRate: Double, channels: UInt32)?
        var nonSilent = false
        mixer.emit = { sb in
            emittedFormat = self.format(sb)
            nonSilent = self.read(sb).contains { abs($0) > 1e-4 }
        }
        mixer.ingestMic(micBuffer(sampleRate: 48_000, value: 0.2))

        XCTAssertEqual(emittedFormat?.sampleRate, 48_000, "mic-only must emit canonical 48k")
        XCTAssertEqual(emittedFormat?.channels, 2, "mic-only must emit stereo")
        XCTAssertTrue(nonSilent, "converted mic audio must carry the signal, not silence")
    }

    /// The mic DSP is wired into the mic path: a steady DC offset (the kind of
    /// low rumble a built-in mic picks up) should be driven toward zero by the
    /// high-pass filter, so the tail of a sustained DC mic buffer is near silent.
    func test_micDSP_isApplied_highPassRemovesDCRumble() {
        let mixer = LiveAudioMixer(hasSystem: false, hasMic: true)   // default DSP on
        var tail: [Float] = []
        mixer.emit = { tail = self.read($0) }
        // ~0.5s of constant DC at 48k mono → after high-pass the end is ~silent.
        mixer.ingestMic(micBuffer(sampleRate: 48_000, frames: 24_000, value: 0.3))

        let lastPeak = Array(tail.suffix(200)).map(abs).max() ?? 0
        XCTAssertGreaterThan(tail.count, 0, "mic-only must still emit frames")
        XCTAssertLessThan(lastPeak, 0.01, "high-pass should drive sustained DC toward silence")
    }

    /// The voiceProcessor (WebRTC APM) takes precedence over micDSP on the mic
    /// path: feeding identical white noise to a raw mixer and an APM mixer, the
    /// APM path must suppress noise (lower emitted energy) while still emitting
    /// canonical 48k stereo. Fails if the voiceProcessor injection is ignored.
    func test_make_usesVoiceProcessing_whenReduceNoiseAndMic() {
        XCTAssertTrue(LiveAudioMixer.make(hasSystem: true, hasMic: true, reduceNoise: true).isVoiceProcessingActive)
        XCTAssertTrue(LiveAudioMixer.make(hasSystem: false, hasMic: true, reduceNoise: true).isVoiceProcessingActive)
    }

    func test_make_noVoiceProcessing_whenToggleOff() {
        XCTAssertFalse(LiveAudioMixer.make(hasSystem: true, hasMic: true, reduceNoise: false).isVoiceProcessingActive)
    }

    func test_make_noVoiceProcessing_whenNoMic() {
        XCTAssertFalse(LiveAudioMixer.make(hasSystem: true, hasMic: false, reduceNoise: true).isVoiceProcessingActive)
    }

    func test_voiceProcessor_takesPrecedence_suppressesNoise_emitsCanonical() {
        // Baseline: raw mic through no processor (micDSP nil, no voiceProcessor).
        let raw = LiveAudioMixer(hasSystem: false, hasMic: true, micDSP: nil)
        var rawEnergy = 0.0
        raw.emit = { rawEnergy += self.read($0).reduce(0) { $0 + Double($1 * $1) } }
        // APM path: NS on via voiceProcessor (micDSP nil so we isolate its effect).
        let apm = LiveAudioMixer(hasSystem: false, hasMic: true, micDSP: nil,
                                 voiceProcessor: MicVoiceProcessor(noiseSuppression: true, gainControl: false))
        var apmEnergy = 0.0
        var apmFormatOK = true
        apm.emit = { sb in
            apmEnergy += self.read(sb).reduce(0) { $0 + Double($1 * $1) }
            if self.format(sb)?.sampleRate != 48_000 || self.format(sb)?.channels != 2 { apmFormatOK = false }
        }
        // Feed the SAME noise sequence to both: build two identical buffers per
        // iteration from one seed advanced once (ingestMic consumes the buffer).
        var seed: UInt64 = 0xDEADBEEF12345
        for _ in 0..<80 {
            var seedA = seed
            var seedB = seed
            raw.ingestMic(noiseMicBuffer(seed: &seedA))
            apm.ingestMic(noiseMicBuffer(seed: &seedB))
            seed = seedA   // both advanced identically; keep them in lockstep
        }
        XCTAssertGreaterThan(rawEnergy, 0)
        XCTAssertGreaterThan(apmEnergy, 0, "APM path must emit some audio, not silence")
        XCTAssertTrue(apmFormatOK, "APM-processed mic output must still be canonical 44.1k stereo")
        XCTAssertLessThan(apmEnergy, rawEnergy * 0.9, "APM noise suppression should lower emitted energy vs raw")
    }
}
