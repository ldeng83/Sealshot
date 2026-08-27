import XCTest
@testable import Sealshot

final class AudioMixTests: XCTestCase {
    func test_sum_mixesAndClipsToUnitRange() {
        let a: [Float] = [0.5, -0.5, 0.9]
        let b: [Float] = [0.5,  0.4, 0.9]
        assertFloatArray(AudioMix.sum(a, b), [1.0, -0.1, 1.0], accuracy: 0.0001)  // 1.8 clipped to 1.0
    }
    func test_sum_unevenLengths_padsShorterWithSilence() {
        assertFloatArray(AudioMix.sum([0.2, 0.2], [0.1]), [0.3, 0.2], accuracy: 0.0001)
    }
    func test_sum_emptyInputs() {
        XCTAssertEqual(AudioMix.sum([], []), [])
    }

    // MARK: - Mic queue draining (lockstep consume, no echo, bounded latency)

    func test_drain_takesPrefixAndShrinksQueue() {
        var q: [Float] = [1, 2, 3, 4, 5]
        XCTAssertEqual(AudioMix.drain(&q, upTo: 2), [1, 2])
        XCTAssertEqual(q, [3, 4, 5])
    }

    func test_drain_overRequest_takesAll() {
        var q: [Float] = [1, 2]
        XCTAssertEqual(AudioMix.drain(&q, upTo: 10), [1, 2])
        XCTAssertEqual(q, [])
    }

    func test_drain_emptyQueue_returnsEmpty() {
        var q: [Float] = []
        XCTAssertEqual(AudioMix.drain(&q, upTo: 4), [])
    }

    func test_capFront_dropsOldestBeyondMax() {
        var q: [Float] = [1, 2, 3, 4, 5]
        AudioMix.capFront(&q, maxCount: 3)
        XCTAssertEqual(q, [3, 4, 5])  // oldest two dropped
    }

    func test_capFront_underMax_unchanged() {
        var q: [Float] = [1, 2]
        AudioMix.capFront(&q, maxCount: 5)
        XCTAssertEqual(q, [1, 2])
    }

    private func assertFloatArray(_ a: [Float], _ b: [Float], accuracy: Float,
                                  file: StaticString = #file, line: UInt = #line) {
        XCTAssertEqual(a.count, b.count, file: file, line: line)
        for (x, y) in zip(a, b) { XCTAssertEqual(x, y, accuracy: accuracy, file: file, line: line) }
    }
}
