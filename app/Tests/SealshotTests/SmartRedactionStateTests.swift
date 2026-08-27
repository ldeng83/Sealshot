import XCTest
import AppKit
@testable import Sealshot

@MainActor
final class SmartRedactionStateTests: XCTestCase {

    private func makeImage(width: Int = 200, height: Int = 200) -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 4 * width, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return ctx.makeImage()!
    }

    private func makeState() -> EditorState {
        EditorState(sourceImage: makeImage(), sourceURL: nil)
    }

    private func detection(_ category: SensitiveCategory = .email,
                           rects: [CGRect] = [CGRect(x: 10, y: 10, width: 60, height: 14)]) -> Detection {
        Detection(category: category, snippet: "x@y.io", confidence: 0.9, rects: rects)
    }

    // MARK: - Scan lifecycle

    func testInitialScanState_isIdle() {
        XCTAssertEqual(makeState().redactionScan, .idle)
    }

    func testIsActive_trueWhileScanningOrReviewing() {
        // The toolbar pill stays lit for the whole active mode — the scan AND
        // its review panel — not just the scan phase.
        XCTAssertFalse(RedactionScanState.idle.isActive)
        XCTAssertFalse(RedactionScanState.empty.isActive)
        XCTAssertTrue(RedactionScanState.scanning.isActive)
        XCTAssertTrue(RedactionScanState.found([]).isActive)
    }

    func testPresentProposals_foundKeepsAllByDefault() {
        let state = makeState()
        state.presentRedactionProposals([detection(), detection(.phone)])
        guard case .found(let proposals) = state.redactionScan else {
            return XCTFail("expected .found, got \(state.redactionScan)")
        }
        XCTAssertEqual(proposals.count, 2)
        XCTAssertTrue(proposals.allSatisfy(\.isKept))
    }

    func testPresentProposals_lowConfidenceStartsUnchecked() {
        let state = makeState()
        let lowConf = Detection(category: .personName, snippet: "Jane",
                                confidence: 0.45,
                                rects: [CGRect(x: 0, y: 0, width: 30, height: 12)])
        state.presentRedactionProposals([detection(.email), lowConf])
        guard case .found(let proposals) = state.redactionScan else { return XCTFail() }
        let kept = Dictionary(uniqueKeysWithValues:
            proposals.map { ($0.detection.category, $0.isKept) })
        XCTAssertEqual(kept[.email], true, "0.9 confidence is kept by default")
        XCTAssertEqual(kept[.personName], false, "0.45 confidence starts unchecked")
    }

    func testPresentProposals_emptyDetections() {
        let state = makeState()
        state.presentRedactionProposals([])
        XCTAssertEqual(state.redactionScan, .empty)
    }

    func testToggleProposal_flipsKeep() {
        let state = makeState()
        let d = detection()
        state.presentRedactionProposals([d])
        state.toggleRedactionProposal(d.id)
        guard case .found(let proposals) = state.redactionScan else { return XCTFail() }
        XCTAssertFalse(proposals[0].isKept)
        state.toggleRedactionProposal(d.id)
        guard case .found(let again) = state.redactionScan else { return XCTFail() }
        XCTAssertTrue(again[0].isKept)
    }

    func testCancel_returnsToIdleWithoutAnnotations() {
        let state = makeState()
        let h = TimelineTestHarness(state)
        state.presentRedactionProposals([detection()])
        state.cancelRedactionScan()
        XCTAssertEqual(state.redactionScan, .idle)
        XCTAssertEqual(state.annotations, [])
        XCTAssertFalse(h.canUndo)
    }

    // MARK: - Apply

    func testApply_createsSolidBlurAnnotationsForKeptProposals() {
        let state = makeState()
        let kept = detection(rects: [CGRect(x: 10, y: 10, width: 60, height: 14)])
        let skipped = detection(.phone, rects: [CGRect(x: 10, y: 50, width: 60, height: 14)])
        state.presentRedactionProposals([kept, skipped])
        state.toggleRedactionProposal(skipped.id)

        state.applyKeptRedactionProposals()

        XCTAssertEqual(state.annotations.count, 1)
        guard case .blur(.rect(let rect)) = state.annotations[0].geometry else {
            return XCTFail("expected rect blur, got \(state.annotations[0].geometry)")
        }
        XCTAssertEqual(rect, CGRect(x: 10, y: 10, width: 60, height: 14))
        XCTAssertEqual(state.annotations[0].style.blurMode, .solid)
        XCTAssertEqual(state.redactionScan, .idle)
    }

    func testApply_multiRectDetectionCreatesOneAnnotationPerRect() {
        let state = makeState()
        let d = detection(rects: [CGRect(x: 0, y: 0, width: 50, height: 10),
                                  CGRect(x: 0, y: 30, width: 80, height: 10)])
        state.presentRedactionProposals([d])
        state.applyKeptRedactionProposals()
        XCTAssertEqual(state.annotations.count, 2)
    }

    func testApply_isOneUndoStep() {
        let state = makeState()
        let h = TimelineTestHarness(state)
        state.presentRedactionProposals([detection(), detection(.phone, rects: [CGRect(x: 0, y: 50, width: 40, height: 10)])])
        state.applyKeptRedactionProposals()
        XCTAssertEqual(state.annotations.count, 2)
        XCTAssertTrue(h.canUndo)

        h.undo()
        XCTAssertEqual(state.annotations, [], "one undo must remove all applied redactions")
    }

    func testApply_withAllSkipped_isNoOp() {
        let state = makeState()
        let h = TimelineTestHarness(state)
        let d = detection()
        state.presentRedactionProposals([d])
        state.toggleRedactionProposal(d.id)
        state.applyKeptRedactionProposals()
        XCTAssertEqual(state.annotations, [])
        XCTAssertFalse(h.canUndo, "no annotations created → no undo checkpoint")
        XCTAssertEqual(state.redactionScan, .idle)
    }

    func testApply_readOnlyState_isNoOp() {
        let state = makeState()
        let h = TimelineTestHarness(state)
        state.isReadOnly = true
        state.presentRedactionProposals([detection()])
        state.applyKeptRedactionProposals()
        XCTAssertEqual(state.annotations, [])
        XCTAssertFalse(h.canUndo)
    }

    // MARK: - Invalidation (proposal coords are space-bound; re-scan is cheap)

    func testCommitCrop_discardsProposals() {
        let state = makeState()
        state.presentRedactionProposals([detection()])
        state.pendingCrop = CGRect(x: 10, y: 10, width: 100, height: 100)
        state.commitCrop()
        XCTAssertEqual(state.redactionScan, .idle)
    }

    func testUndoRedo_discardProposals() {
        let state = makeState()
        let h = TimelineTestHarness(state)
        state.recordUndoCheckpoint()
        state.annotations = [Annotation(geometry: .rectangle(rect: CGRect(x: 0, y: 0, width: 10, height: 10)),
                                        style: Style(strokeColor: SerializableColor(.red), strokeWidth: 2))]
        state.presentRedactionProposals([detection()])
        h.undo()
        XCTAssertEqual(state.redactionScan, .idle)

        state.presentRedactionProposals([detection()])
        h.redo()
        XCTAssertEqual(state.redactionScan, .idle)
    }
}
