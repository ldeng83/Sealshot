import XCTest
import CoreGraphics
@testable import Sealshot

final class DETRDecoderTests: XCTestCase {

    // One query strongly classified as table (index 0) with a centered box.
    func test_decode_singleTableBox_cxcywhToXyxy() {
        let logits = [[10.0 as Float, 0, 0]]          // class 0 dominates → softmax≈1
        let boxes  = [[0.5 as Float, 0.5, 0.4, 0.2]]  // cx,cy,w,h
        let rects = DETRDecoder.decode(logits: logits, boxes: boxes,
                                       tableClassIndices: [0, 1],
                                       scoreThreshold: 0.7, iouThreshold: 0.3)
        XCTAssertEqual(rects.count, 1)
        XCTAssertEqual(rects[0].minX, 0.3, accuracy: 1e-5)
        XCTAssertEqual(rects[0].minY, 0.4, accuracy: 1e-5)
        XCTAssertEqual(rects[0].width, 0.4, accuracy: 1e-5)
        XCTAssertEqual(rects[0].height, 0.2, accuracy: 1e-5)
    }

    // The no-object class (index 2) wins → dropped.
    func test_decode_noObjectClass_dropped() {
        let logits = [[0.0 as Float, 0, 10]]
        let boxes  = [[0.5 as Float, 0.5, 0.4, 0.2]]
        let rects = DETRDecoder.decode(logits: logits, boxes: boxes,
                                       tableClassIndices: [0, 1],
                                       scoreThreshold: 0.7, iouThreshold: 0.3)
        XCTAssertTrue(rects.isEmpty)
    }

    // Two near-identical table boxes → NMS keeps the higher-scoring one.
    func test_decode_nmsSuppressesOverlap() {
        let logits = [[5.0 as Float, 0, 0], [10.0 as Float, 0, 0]]
        let boxes  = [[0.5 as Float, 0.5, 0.4, 0.2], [0.51, 0.5, 0.4, 0.2]]
        let rects = DETRDecoder.decode(logits: logits, boxes: boxes,
                                       tableClassIndices: [0, 1],
                                       scoreThreshold: 0.7, iouThreshold: 0.3)
        XCTAssertEqual(rects.count, 1)
        XCTAssertEqual(rects[0].midX, 0.51, accuracy: 1e-5)  // the higher-score box
    }
}
