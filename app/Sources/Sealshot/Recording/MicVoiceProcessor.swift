import AVFoundation
import CoreMedia
import WebRTCAPM

/// Cleans a raw microphone stream with the WebRTC Audio Processing Module
/// (high-pass + noise suppression + automatic gain control), returning canonical
/// (44.1 kHz stereo interleaved Float32) frames ready for the mixer.
///
/// NOTE: APM also has an echo canceller, but it is NOT used here. Cancelling
/// speaker→mic bleed needs the system-audio reference and the mic aligned to a
/// few ms; macOS captures them through two independent engines (ScreenCaptureKit
/// + CoreAudio) whose clocks drift, so AEC3 never converges (measured: zero
/// cancellation). Production recorders (OBS, Loom, …) don't attempt this either —
/// they capture system audio digitally and rely on headphones for bleed.
///
/// APM only runs at 48 kHz on fixed 10 ms (480-sample) frames, so this owns the
/// rate dance: raw mic → 48 kHz mono (persistent resampler) → 480-sample APM
/// frames → 48 kHz mono cleaned → canonical 44.1 kHz stereo (persistent
/// resampler). All converters/buffers are stateful → ONE instance per recording.
/// If APM can't initialize, it falls back to passthrough so the mic still works.
final class MicVoiceProcessor {
    /// APM runs at 48 kHz mono — the only WebRTC-accepted rate near canonical.
    private static let apmSampleRate = 48_000.0
    /// 48 kHz mono Float32: the rate/layout APM (and its resamplers) work in.
    private static let apmFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: apmSampleRate,
        channels: 1, interleaved: true)!

    /// The processing module. Nil → passthrough (mic must keep working even if
    /// APM can't initialize).
    private let apm: WebRTCAPM?

    // Capture path -----------------------------------------------------------
    /// Raw mic (native format) → 48 kHz mono. Persistent so the resampler keeps
    /// its filter state across buffers (a fresh converter per call adds
    /// audible artifacts). Rebuilt only if the mic's source format changes.
    private var captureResampler: AVAudioConverter?
    private var captureSourceFormat: AVAudioFormat?
    /// 48 kHz mono samples awaiting a full 480-sample APM frame. The leftover
    /// <480 carries into the next call.
    private var pending: [Float] = []
    /// One reused APM frame buffer — sized to `frameLength`, no per-call alloc.
    private var apmFrame: [Int16]
    /// Cleaned 48 kHz mono samples → canonical 44.1 kHz stereo. Persistent for
    /// the same resampler-state reason as the capture side.
    private var canonicalResampler: AVAudioConverter?

    init(noiseSuppression: Bool, gainControl: Bool) {
        self.apm = WebRTCAPM(sampleRate: Int(Self.apmSampleRate), channels: 1,
                             noiseSuppression: noiseSuppression,
                             gainControl: gainControl,
                             echoCancellation: false)
        let frameLength = apm?.frameLength ?? 480
        self.apmFrame = Array(repeating: 0, count: frameLength)
    }

    /// Clean a raw mic sample buffer; returns canonical interleaved-stereo
    /// Float32 frames. May return [] while buffering toward a full 10 ms APM
    /// frame (the leftover <480 samples wait for the next call).
    func process(_ sb: CMSampleBuffer) -> [Float] {
        // No APM → passthrough: hand back canonical, unprocessed frames so the
        // mic still records.
        guard let apm else { return CMSampleBufferAudio.floatFrames(sb) ?? [] }
        guard let mono48k = resampleToAPM(sb) else { return [] }

        pending.append(contentsOf: mono48k)
        let frameLength = apm.frameLength
        guard frameLength > 0 else { return [] }

        // Process every full 10 ms frame; <480 leftover stays in `pending`.
        var cleaned48kMono: [Float] = []
        cleaned48kMono.reserveCapacity(pending.count)
        var offset = 0
        while pending.count - offset >= frameLength {
            for i in 0..<frameLength {
                let x = pending[offset + i]
                // Float[-1,1] → Int16.
                apmFrame[i] = Int16(max(-1, min(1, x)) * 32767)
            }
            apm.processCapture(&apmFrame)
            for i in 0..<frameLength {
                // Int16 → Float[-1,1].
                cleaned48kMono.append(Float(apmFrame[i]) / 32767)
            }
            offset += frameLength
        }
        if offset > 0 { pending.removeFirst(offset) }
        guard !cleaned48kMono.isEmpty else { return [] }

        return canonicalFrames(fromMono48k: cleaned48kMono) ?? []
    }

    // MARK: - Resampling

    /// Raw mic buffer (native format) → 48 kHz mono Float32 samples, via the
    /// persistent capture resampler (rebuilt only if the source format changes).
    private func resampleToAPM(_ sb: CMSampleBuffer) -> [Float]? {
        guard let src = CMSampleBufferAudio.sourcePCMBuffer(sb), src.frameLength > 0 else { return nil }
        if captureSourceFormat != src.format || captureResampler == nil {
            captureResampler = AVAudioConverter(from: src.format, to: Self.apmFormat)
            captureSourceFormat = src.format
        }
        return Self.monoSamples(from: src, using: captureResampler)
    }

    /// Cleaned 48 kHz mono samples → canonical (44.1 kHz stereo interleaved
    /// Float32) frames, via the persistent canonical resampler.
    private func canonicalFrames(fromMono48k mono: [Float]) -> [Float]? {
        guard !mono.isEmpty else { return [] }
        guard let input = AVAudioPCMBuffer(pcmFormat: Self.apmFormat,
                                           frameCapacity: AVAudioFrameCount(mono.count)),
              let chan = input.floatChannelData else { return nil }
        input.frameLength = AVAudioFrameCount(mono.count)
        mono.withUnsafeBufferPointer { chan[0].update(from: $0.baseAddress!, count: mono.count) }

        if canonicalResampler == nil {
            canonicalResampler = AVAudioConverter(from: Self.apmFormat, to: CanonicalAudio.format)
        }
        guard let converter = canonicalResampler else { return nil }
        let ratio = CanonicalAudio.format.sampleRate / Self.apmSampleRate
        let capacity = AVAudioFrameCount(Double(mono.count) * ratio) + 2048
        guard let out = AVAudioPCMBuffer(pcmFormat: CanonicalAudio.format, frameCapacity: capacity) else { return nil }
        var error: NSError?
        var fed = false
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if fed { outStatus.pointee = .noDataNow; return nil }
            fed = true; outStatus.pointee = .haveData; return input
        }
        guard status != .error, out.frameLength > 0, let chans = out.floatChannelData else { return nil }
        let count = Int(out.frameLength) * Int(CanonicalAudio.format.channelCount)
        return Array(UnsafeBufferPointer(start: chans[0], count: count))
    }

    /// Convert a native-format source buffer to 48 kHz mono Float32 samples
    /// using the supplied persistent converter (feed-one-buffer pattern).
    private static func monoSamples(from src: AVAudioPCMBuffer,
                                    using converter: AVAudioConverter?) -> [Float]? {
        guard let converter else { return nil }
        let ratio = apmSampleRate / src.format.sampleRate
        let capacity = AVAudioFrameCount(Double(src.frameLength) * ratio) + 2048
        guard let out = AVAudioPCMBuffer(pcmFormat: apmFormat, frameCapacity: capacity) else { return nil }
        var error: NSError?
        var fed = false
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if fed { outStatus.pointee = .noDataNow; return nil }
            fed = true; outStatus.pointee = .haveData; return src
        }
        guard status != .error, out.frameLength > 0, let chans = out.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: chans[0], count: Int(out.frameLength)))
    }
}
