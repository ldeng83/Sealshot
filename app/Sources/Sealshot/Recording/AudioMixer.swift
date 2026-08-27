import Foundation
import AVFoundation
import CoreMedia

/// Pure audio sample math for mixing two mono/interleaved Float32 streams.
/// The live mixer (added with microphone support) builds on this core.
enum AudioMix {
    /// Sum two sample arrays, padding the shorter with silence, clipping to
    /// [-1, 1]. Mixing is additive; clipping prevents overflow distortion.
    static func sum(_ a: [Float], _ b: [Float]) -> [Float] {
        let n = max(a.count, b.count)
        guard n > 0 else { return [] }
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            out[i] = min(1, max(-1, x + y))
        }
        return out
    }

    /// Remove and return up to `count` frames from the front of `queue`. Used to
    /// consume buffered mic frames in lockstep with each system buffer, so mic
    /// audio is never re-summed (echo) and the mix matches the system length.
    static func drain(_ queue: inout [Float], upTo count: Int) -> [Float] {
        let take = min(max(0, count), queue.count)
        defer { queue.removeFirst(take) }
        return Array(queue.prefix(take))
    }

    /// Drop the oldest frames so `queue` holds at most `maxCount` — bounds mic
    /// latency if the mic outruns the (emission-driving) system stream.
    static func capFront(_ queue: inout [Float], maxCount: Int) {
        if queue.count > maxCount { queue.removeFirst(queue.count - maxCount) }
    }
}

/// Canonical PCM format used for mixing: Float32, 48 kHz, stereo, interleaved.
/// 48 kHz matches the NATIVE rate that both ScreenCaptureKit system audio and
/// the mic deliver (verified: SCStream ignores a 44.1 kHz request and hands
/// back 48 kHz), so nothing is resampled on the way in. Downsampling to 44.1
/// kHz previously forced a non-integer 48→44.1 resample on every buffer, whose
/// per-buffer restarts added audible "compression-like" grit — most on the
/// system channel in the mixed path. Both streams convert to this before
/// summation, then hand off to the AAC writer input (also 48 kHz).
enum CanonicalAudio {
    static let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
        channels: 2, interleaved: true)!
}

/// Mixes system + mic into a single audio stream. The system stream drives
/// emission (it's the steadier clock); the most recent mic frames are summed
/// into each system buffer. When only one source is present, that source
/// passes through unmixed.
///
/// UNVERIFIED: live PCM mixing needs on-device smoke testing (record with
/// system + mic, confirm both are audible in one track). The pure summation
/// core (`AudioMix.sum`) is unit-tested; the conversion glue is not.
final class LiveAudioMixer {
    private let hasSystem: Bool
    private let hasMic: Bool
    /// Buffered mic frames awaiting a system buffer to be summed into. Drained
    /// in lockstep with the system stream; capped to bound added latency.
    private var micQueue: [Float] = []
    /// ~1s of canonical stereo audio (interleaved Float32) at 48 kHz. If the mic
    /// outruns the system stream past this, drop the oldest rather than build
    /// latency.
    private static let maxMicBacklog = 48_000 * 2
    /// One persistent resampler for the whole recording → no per-buffer
    /// resampler restarts (which add audible artifacts).
    private let micConverter = MicCanonicalConverter()
    /// High-pass + noise-gate cleanup applied to mic frames. Nil disables it
    /// (used by tests that assert raw mixing math). Stateful → one instance.
    private let micDSP: MicDSP?
    /// WebRTC APM voice processor. When non-nil it OWNS the mic-frame source
    /// (raw mic → canonical, with high-pass + noise suppression + AGC) and
    /// SUPERSEDES `micDSP` — APM already does that cleanup, so micDSP is skipped.
    /// Nil (the default) keeps today's micConverter + micDSP path. The toggle
    /// (Task B4) chooses which to inject. Stateful → one instance per recording.
    private let voiceProcessor: MicVoiceProcessor?
    /// True when WebRTC APM voice processing is active for this recording.
    /// Exposed for tests to observe the factory's routing decision.
    var isVoiceProcessingActive: Bool { voiceProcessor != nil }

    var emit: ((CMSampleBuffer) -> Void)?

    init(hasSystem: Bool, hasMic: Bool, micDSP: MicDSP? = MicDSP(),
         voiceProcessor: MicVoiceProcessor? = nil) {
        self.hasSystem = hasSystem
        self.hasMic = hasMic
        self.micDSP = micDSP
        self.voiceProcessor = voiceProcessor
    }

    /// Persistent native→canonical converter for the system stream in the mixed
    /// path, so the conversion keeps its state across buffers instead of a fresh
    /// converter per buffer (the old `floatFrames` static did the latter). At
    /// 48 kHz canonical this is a no-resample format copy, but persistence still
    /// avoids per-buffer converter allocation. Reuses the same class as the mic.
    private let systemConverter = MicCanonicalConverter()

    func ingestSystem(_ sb: CMSampleBuffer) {
        guard hasSystem else { return }
        guard hasMic else { emit?(sb); return }   // system-only: pass through
        guard let sysFrames = systemConverter.canonicalFrames(from: sb) else { emit?(sb); return }
        // Consume only as many mic frames as this system buffer covers, so mic
        // audio is summed once (no echo) and the output matches the system
        // length (no desync). Leftover mic frames wait for the next buffer.
        let micChunk = AudioMix.drain(&micQueue, upTo: sysFrames.count)
        let mixed = AudioMix.sum(sysFrames, micChunk)
        if let out = CMSampleBufferAudio.make(frames: mixed,
                                              pts: CMSampleBufferGetPresentationTimeStamp(sb)) {
            emit?(out)
        } else {
            emit?(sb)
        }
    }

    func ingestMic(_ sb: CMSampleBuffer) {
        guard hasMic else { return }
        let frames: [Float]
        if let voiceProcessor {
            // APM owns the mic-frame source: it returns canonical frames already
            // cleaned (high-pass + noise suppression + AGC), so micDSP is skipped
            // (APM supersedes it). [] means APM is still buffering toward a full
            // 10 ms frame — nothing to emit/queue this call.
            frames = voiceProcessor.process(sb)
            if frames.isEmpty { return }
        } else {
            guard var raw = micConverter.canonicalFrames(from: sb) else { return }
            // Clean the raw mic (high-pass + noise gate) before mixing/emitting.
            if let micDSP { raw = micDSP.process(raw) }
            frames = raw
        }
        if !hasSystem {
            // Mic-only: emit the canonical 44.1 kHz stereo frames. The AAC writer
            // input is stereo/44.1 kHz and SILENTLY DROPS a raw mono/48 kHz mic
            // buffer — which made mic-only recordings completely silent. (The
            // persistent converter above is what produces the canonical format;
            // system-only passes through because SCStream audio is already
            // canonical.)
            if let out = CMSampleBufferAudio.make(
                frames: frames, pts: CMSampleBufferGetPresentationTimeStamp(sb)) {
                emit?(out)
            }
            return
        }
        micQueue.append(contentsOf: frames)
        AudioMix.capFront(&micQueue, maxCount: Self.maxMicBacklog)
    }
}

extension LiveAudioMixer {
    /// Build the mixer for a recording's audio config. Voice processing (WebRTC
    /// APM: high-pass + noise suppression + AGC) is used when noise reduction is
    /// on AND the mic is captured; otherwise the lightweight micDSP path.
    static func make(hasSystem: Bool, hasMic: Bool, reduceNoise: Bool) -> LiveAudioMixer {
        let useVoiceProcessing = reduceNoise && hasMic
        return LiveAudioMixer(
            hasSystem: hasSystem, hasMic: hasMic,
            micDSP: useVoiceProcessing ? nil : MicDSP(),
            voiceProcessor: useVoiceProcessing
                ? MicVoiceProcessor(noiseSuppression: true, gainControl: true)
                : nil)
    }
}

/// Converts raw microphone CMSampleBuffers (whatever the hardware format is) to
/// canonical interleaved-stereo Float32 frames using ONE persistent
/// `AVAudioConverter`, so sample-rate conversion keeps its filter state across
/// buffers. (Creating a fresh converter per buffer restarts the resampler each
/// time and adds audible artifacts.) Rebuilds only if the source format changes
/// mid-stream.
final class MicCanonicalConverter {
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?

    /// Convert a mic sample buffer to canonical (44.1 kHz stereo Float32
    /// interleaved) frames. Nil if conversion fails.
    func canonicalFrames(from sb: CMSampleBuffer) -> [Float]? {
        guard let src = CMSampleBufferAudio.sourcePCMBuffer(sb), src.frameLength > 0 else { return nil }
        if sourceFormat != src.format || converter == nil {
            converter = AVAudioConverter(from: src.format, to: CanonicalAudio.format)
            sourceFormat = src.format
        }
        guard let converter else { return nil }
        let ratio = CanonicalAudio.format.sampleRate / src.format.sampleRate
        let capacity = AVAudioFrameCount(Double(src.frameLength) * ratio) + 2048
        guard let out = AVAudioPCMBuffer(pcmFormat: CanonicalAudio.format, frameCapacity: capacity) else { return nil }
        var error: NSError?
        var fed = false
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if fed { outStatus.pointee = .noDataNow; return nil }
            fed = true; outStatus.pointee = .haveData; return src
        }
        guard status != .error, out.frameLength > 0, let chans = out.floatChannelData else { return nil }
        let count = Int(out.frameLength) * Int(CanonicalAudio.format.channelCount)
        return Array(UnsafeBufferPointer(start: chans[0], count: count))
    }
}

/// CMSampleBuffer ↔ Float32 helpers for audio, against `CanonicalAudio.format`.
enum CMSampleBufferAudio {
    /// Read a sample buffer's audio into an AVAudioPCMBuffer in its NATIVE
    /// format (no conversion). Returns nil if the buffer can't be read.
    static func sourcePCMBuffer(_ sb: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let fmtDesc = CMSampleBufferGetFormatDescription(sb),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc)
        else { return nil }
        var asbd = asbdPtr.pointee
        guard let srcFormat = AVAudioFormat(streamDescription: &asbd) else { return nil }
        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sb))
        guard frameCount > 0,
              let srcBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frameCount)
        else { return nil }
        srcBuffer.frameLength = frameCount
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sb, at: 0, frameCount: Int32(frameCount),
            into: srcBuffer.mutableAudioBufferList) == noErr else { return nil }
        return srcBuffer
    }

    /// Read a sample buffer's audio as interleaved Float32 frames in the
    /// canonical format. Returns nil if conversion fails.
    static func floatFrames(_ sb: CMSampleBuffer) -> [Float]? {
        guard let srcBuffer = sourcePCMBuffer(sb) else { return nil }
        let frameCount = srcBuffer.frameLength
        guard let converter = AVAudioConverter(from: srcBuffer.format, to: CanonicalAudio.format),
              let dst = AVAudioPCMBuffer(pcmFormat: CanonicalAudio.format,
                                         frameCapacity: frameCount) else { return nil }
        var error: NSError?
        var fed = false
        let status = converter.convert(to: dst, error: &error) { _, outStatus in
            if fed { outStatus.pointee = .noDataNow; return nil }
            fed = true; outStatus.pointee = .haveData; return srcBuffer
        }
        guard status != .error, let chans = dst.floatChannelData else { return nil }
        // Canonical format is interleaved stereo → one channel pointer with
        // 2*frames values.
        let count = Int(dst.frameLength) * Int(CanonicalAudio.format.channelCount)
        return Array(UnsafeBufferPointer(start: chans[0], count: count))
    }

    /// Wrap interleaved Float32 frames back into a CMSampleBuffer at `pts`.
    static func make(frames: [Float], pts: CMTime) -> CMSampleBuffer? {
        let channels = Int(CanonicalAudio.format.channelCount)
        guard channels > 0, !frames.isEmpty else { return nil }
        let frameCount = AVAudioFrameCount(frames.count / channels)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: CanonicalAudio.format,
                                            frameCapacity: frameCount),
              let dst = buffer.floatChannelData else { return nil }
        buffer.frameLength = frameCount
        frames.withUnsafeBufferPointer { src in
            dst[0].update(from: src.baseAddress!, count: frames.count)
        }
        return sampleBuffer(from: buffer, pts: pts)
    }

    private static func sampleBuffer(from pcm: AVAudioPCMBuffer, pts: CMTime) -> CMSampleBuffer? {
        var format = pcm.format.streamDescription.pointee
        var formatDesc: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,
              asbd: &format, layoutSize: 0, layout: nil, magicCookieSize: 0,
              magicCookie: nil, extensions: nil, formatDescriptionOut: &formatDesc) == noErr,
              let formatDesc else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(pcm.format.sampleRate)),
            presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil,
              dataReady: false, makeDataReadyCallback: nil, refcon: nil,
              formatDescription: formatDesc, sampleCount: CMItemCount(pcm.frameLength),
              sampleTimingEntryCount: 1, sampleTimingArray: &timing,
              sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sb) == noErr,
              let sb else { return nil }
        guard CMSampleBufferSetDataBufferFromAudioBufferList(sb,
              blockBufferAllocator: kCFAllocatorDefault,
              blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0,
              bufferList: pcm.mutableAudioBufferList) == noErr else { return nil }
        return sb
    }
}
