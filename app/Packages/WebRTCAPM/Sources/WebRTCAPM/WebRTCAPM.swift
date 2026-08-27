import CWebRTCAPM

/// Swift wrapper around the WebRTC Audio Processing Module (APM) C-ABI shim.
///
/// All audio is 16-bit signed interleaved PCM processed in 10 ms frames.
/// One frame holds `frameLength` samples (`sampleRate / 100 * channels`).
public final class WebRTCAPM {
    private let handle: OpaquePointer

    /// Number of interleaved Int16 samples in one 10 ms frame.
    public let frameLength: Int

    /// Create an APM instance.
    /// - Parameters:
    ///   - sampleRate: stream sample rate in Hz (8000/16000/32000/48000).
    ///   - channels: number of interleaved channels (1 = mono).
    ///   - noiseSuppression: enable noise suppression.
    ///   - gainControl: enable automatic gain control.
    ///   - echoCancellation: enable acoustic echo cancellation (needs a render
    ///     stream via `processRender` and a stream delay via `setStreamDelay`).
    /// - Returns: nil if the APM could not be created.
    public init?(sampleRate: Int,
                 channels: Int,
                 noiseSuppression: Bool,
                 gainControl: Bool,
                 echoCancellation: Bool) {
        guard let handle = cwebrtc_apm_create(Int32(sampleRate),
                                              Int32(channels),
                                              noiseSuppression,
                                              gainControl,
                                              echoCancellation) else {
            return nil
        }
        self.handle = handle
        self.frameLength = (sampleRate / 100) * channels
    }

    /// Process one 10 ms capture (microphone) frame in place.
    /// The frame must contain exactly `frameLength` samples.
    public func processCapture(_ frame: inout [Int16]) {
        guard frame.count == frameLength else { return }
        frame.withUnsafeMutableBufferPointer { buf in
            cwebrtc_apm_process_capture(handle, buf.baseAddress, Int32(buf.count))
        }
    }

    /// Process one 10 ms render (system-audio reference) frame for AEC.
    /// The frame must contain exactly `frameLength` samples.
    public func processRender(_ frame: [Int16]) {
        guard frame.count == frameLength else { return }
        frame.withUnsafeBufferPointer { buf in
            cwebrtc_apm_process_render(handle, buf.baseAddress, Int32(buf.count))
        }
    }

    /// Set the estimated render-to-capture delay (ms) used by the echo canceller.
    public func setStreamDelay(ms: Int) {
        cwebrtc_apm_set_stream_delay_ms(handle, Int32(ms))
    }

    deinit {
        cwebrtc_apm_destroy(handle)
    }
}
