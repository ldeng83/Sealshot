import XCTest
@testable import WebRTCAPM

final class WebRTCAPMTests: XCTestCase {

    /// Deterministic LCG (Numerical Recipes constants) so the test is reproducible.
    private struct LCG {
        var state: UInt64
        mutating func next() -> UInt32 {
            state = 1664525 &* state &+ 1013904223
            return UInt32(truncatingIfNeeded: state >> 16)
        }
        /// White noise sample in roughly [-amplitude, amplitude].
        mutating func nextSample(amplitude: Int16) -> Int16 {
            let r = Int(next() % UInt32(2 * Int(amplitude) + 1)) - Int(amplitude)
            return Int16(r)
        }
    }

    func testCreateAndFrameLength() {
        let apm = WebRTCAPM(sampleRate: 48000,
                            channels: 1,
                            noiseSuppression: true,
                            gainControl: false,
                            echoCancellation: false)
        XCTAssertNotNil(apm)
        XCTAssertEqual(apm?.frameLength, 480)
    }

    func testInvalidParametersReturnNil() {
        // Unsupported sample rate (44.1 kHz is not in {8000,16000,32000,48000}).
        XCTAssertNil(WebRTCAPM(sampleRate: 44_100,
                               channels: 1,
                               noiseSuppression: true,
                               gainControl: false,
                               echoCancellation: false))
        // Invalid channel count.
        XCTAssertNil(WebRTCAPM(sampleRate: 48_000,
                               channels: 0,
                               noiseSuppression: true,
                               gainControl: false,
                               echoCancellation: false))
    }

    func testProcessCaptureWrongLengthIsNoOp() {
        guard let apm = WebRTCAPM(sampleRate: 48_000,
                                  channels: 1,
                                  noiseSuppression: true,
                                  gainControl: false,
                                  echoCancellation: false) else {
            return XCTFail("APM should be created")
        }
        XCTAssertEqual(apm.frameLength, 480)

        // Wrong-length frame (100 != 480): must not crash and must be untouched.
        let original = (0..<100).map { Int16($0) }
        var frame = original
        apm.processCapture(&frame)
        XCTAssertEqual(frame, original, "wrong-length frame must be left unchanged")
    }

    func testNoiseSuppressionReducesEnergy() {
        guard let apm = WebRTCAPM(sampleRate: 48000,
                                  channels: 1,
                                  noiseSuppression: true,
                                  gainControl: false,
                                  echoCancellation: false) else {
            return XCTFail("APM should be created")
        }
        XCTAssertEqual(apm.frameLength, 480)

        var rng = LCG(state: 0x1234_5678)
        let frameCount = 20
        var totalInput = 0.0
        var totalOutput = 0.0

        for _ in 0..<frameCount {
            // Steady white noise: NS should attenuate this over time.
            var frame = (0..<apm.frameLength).map { _ in rng.nextSample(amplitude: 4000) }

            for s in frame { totalInput += Double(s) * Double(s) }
            apm.processCapture(&frame)
            for s in frame { totalOutput += Double(s) * Double(s) }
        }

        XCTAssertGreaterThan(totalInput, 0, "input must carry energy")
        // NS reduces steady noise; averaged over frames the output energy should
        // be meaningfully below the input energy.
        XCTAssertLessThan(totalOutput, totalInput * 0.9,
                          "NS-on output energy (\(totalOutput)) should be well below input (\(totalInput))")
    }
}
