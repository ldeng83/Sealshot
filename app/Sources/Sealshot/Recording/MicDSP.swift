import Foundation

/// Lightweight mic cleanup applied to canonical interleaved-stereo Float32
/// frames, in two stages:
///
///   1. **High-pass filter** — a first-order high-pass per channel that removes
///      DC offset and low-frequency rumble/AC hum (the steady low-end energy a
///      built-in laptop mic picks up from fans, desks, and mains).
///   2. **Noise gate** — an envelope-smoothed gate that attenuates the signal
///      toward silence whenever it falls below a threshold, killing the constant
///      hiss between words without chopping speech (attack/release smoothing
///      keeps it from chattering on transients).
///
/// Both stages are STATEFUL across calls (filter memory + gate gain), so a
/// single instance must serve a whole recording — feeding audio through fresh
/// instances per buffer would reset the filter and re-introduce artifacts.
/// This is a deliberate, dependable improvement over raw capture (not
/// Zoom-grade voice processing, which can't run alongside ScreenCaptureKit).
final class MicDSP {
    private let channels = Int(CanonicalAudio.format.channelCount)

    // High-pass: y[n] = a·(y[n-1] + x[n] - x[n-1]), per channel.
    private let hpAlpha: Float
    private var hpLastIn: [Float]
    private var hpLastOut: [Float]

    // Noise gate: a smoothed gain driven toward 1 (open) or 0 (closed) by the
    // post-high-pass envelope, with separate attack (opening) and release
    // (closing) time constants.
    private let gateThreshold: Float
    private let attackCoef: Float
    private let releaseCoef: Float
    private var gateGain: Float = 1

    /// - Parameters:
    ///   - sampleRate: frames per second of the input (canonical 44.1 kHz).
    ///   - highPassHz: high-pass corner frequency in Hz.
    ///   - gateThreshold: peak amplitude (0...1) below which the gate closes.
    ///     Pass 0 to keep the gate fully open (high-pass only).
    ///   - gateAttack: seconds for the gate to open on a loud signal.
    ///   - gateRelease: seconds for the gate to close on a quiet signal.
    init(sampleRate: Double = CanonicalAudio.format.sampleRate,
         highPassHz: Double = 80,
         gateThreshold: Float = 0.02,
         gateAttack: Double = 0.005,
         gateRelease: Double = 0.08) {
        let dt = 1.0 / sampleRate
        let rc = 1.0 / (2.0 * Double.pi * highPassHz)
        self.hpAlpha = Float(rc / (rc + dt))
        self.gateThreshold = gateThreshold
        self.attackCoef = Float(1 - exp(-1.0 / (max(gateAttack, dt) * sampleRate)))
        self.releaseCoef = Float(1 - exp(-1.0 / (max(gateRelease, dt) * sampleRate)))
        self.hpLastIn = Array(repeating: 0, count: channels)
        self.hpLastOut = Array(repeating: 0, count: channels)
    }

    /// Process one buffer of interleaved-stereo Float32 frames in place,
    /// returning the cleaned frames. Carries filter/gate state to the next call.
    func process(_ frames: [Float]) -> [Float] {
        guard frames.count >= channels else { return frames }
        var out = frames
        let frameCount = frames.count / channels
        for f in 0..<frameCount {
            let base = f * channels
            var peak: Float = 0
            // High-pass each channel, tracking the loudest post-filter sample.
            for c in 0..<channels {
                let x = frames[base + c]
                let y = hpAlpha * (hpLastOut[c] + x - hpLastIn[c])
                hpLastIn[c] = x
                hpLastOut[c] = y
                out[base + c] = y
                peak = max(peak, abs(y))
            }
            // Gate: ease the gain toward open/closed, then apply it.
            let target: Float = peak >= gateThreshold ? 1 : 0
            let coef = target > gateGain ? attackCoef : releaseCoef
            gateGain += (target - gateGain) * coef
            for c in 0..<channels { out[base + c] *= gateGain }
        }
        return out
    }
}
