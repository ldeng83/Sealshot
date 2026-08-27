import XCTest
import AVFoundation
@testable import Sealshot

/// MicDSP cleans raw mic audio in the canonical interleaved-stereo Float32
/// domain: a high-pass filter (kills low rumble/AC hum) followed by an
/// envelope-smoothed noise gate (attenuates steady hiss between words). Both
/// stages are stateful across calls, so one instance serves a whole recording.
final class MicDSPTests: XCTestCase {
    private let channels = Int(CanonicalAudio.format.channelCount)   // 2
    private let rate = CanonicalAudio.format.sampleRate              // 48_000

    /// Interleaved stereo frames where both channels hold `value`.
    private func dc(_ value: Float, frames: Int) -> [Float] {
        Array(repeating: value, count: frames * channels)
    }

    /// Interleaved stereo full-rate alternating ±`amp` — a near-Nyquist signal
    /// the high-pass should pass almost untouched.
    private func nyquist(_ amp: Float, frames: Int) -> [Float] {
        var out = [Float](repeating: 0, count: frames * channels)
        for f in 0..<frames {
            let v: Float = (f % 2 == 0) ? amp : -amp
            for c in 0..<channels { out[f * channels + c] = v }
        }
        return out
    }

    /// Peak absolute amplitude over the last `frames` frames.
    private func tailPeak(_ samples: [Float], frames: Int) -> Float {
        Array(samples.suffix(frames * channels)).map(abs).max() ?? 0
    }

    func test_highPass_attenuatesDC() {
        // Gate fully open (threshold 0) so this isolates the high-pass.
        let dsp = MicDSP(gateThreshold: 0)
        let out = dsp.process(dc(0.5, frames: 4410))   // 0.1s of DC
        XCTAssertEqual(out.count, 4410 * channels)
        XCTAssertLessThan(tailPeak(out, frames: 100), 0.01,
                          "steady DC should decay toward zero through the high-pass")
    }

    func test_highPass_passesHighFrequencies() {
        let dsp = MicDSP(gateThreshold: 0)
        let out = dsp.process(nyquist(0.5, frames: 4410))
        XCTAssertGreaterThan(tailPeak(out, frames: 100), 0.45,
                             "a near-Nyquist tone should pass the high-pass nearly unchanged")
    }

    func test_noiseGate_closesOnQuietSignalBelowThreshold() {
        // Near-Nyquist (survives the high-pass) but quieter than the gate
        // threshold → the gate should clamp it toward silence.
        let dsp = MicDSP(gateThreshold: 0.05, gateRelease: 0.02)
        let out = dsp.process(nyquist(0.01, frames: 8820))   // 0.2s, amp < threshold
        XCTAssertLessThan(tailPeak(out, frames: 100), 0.002,
                          "a signal below the gate threshold should be attenuated to near silence")
    }

    func test_noiseGate_passesLoudSignalAboveThreshold() {
        let dsp = MicDSP(gateThreshold: 0.05, gateAttack: 0.002)
        let out = dsp.process(nyquist(0.5, frames: 4410))
        XCTAssertGreaterThan(tailPeak(out, frames: 100), 0.45,
                             "a signal above the gate threshold should pass through")
    }

    func test_stateCarriesAcrossCalls() {
        // Feeding DC in two calls must behave like one continuous stream: by the
        // second call the high-pass has already settled, so output stays low.
        let dsp = MicDSP(gateThreshold: 0)
        _ = dsp.process(dc(0.5, frames: 4410))
        let out = dsp.process(dc(0.5, frames: 441))
        XCTAssertLessThan(tailPeak(out, frames: 100), 0.01,
                          "high-pass state must persist across process() calls")
    }

    func test_emptyInput_returnsEmpty() {
        XCTAssertEqual(MicDSP().process([]).count, 0)
    }
}
