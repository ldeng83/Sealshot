import AppKit
import CoreGraphics
import XCTest
@testable import Sealshot

/// The tapered arrow's pure geometry: which end is wide, how wide, and the
/// quads the shaft fills — including dashed shafts, which become tapered
/// trapezoids rather than uniform dashes.
final class TaperedShaftGeometryTests: XCTestCase {

    // MARK: Orientation — the user-chosen rules

    func testSingleHeadAtEnd_isWideAtTheEnd() {
        let w = taperedWidths(nominalWidth: 10, startCap: .none, endCap: .filled)
        XCTAssertGreaterThan(w.atEnd, w.atStart)
    }

    func testSingleHeadAtStart_isWideAtTheStart() {
        let w = taperedWidths(nominalWidth: 10, startCap: .filled, endCap: .none)
        XCTAssertGreaterThan(w.atStart, w.atEnd)
    }

    /// Double-headed: wide at the START, narrow at the end — the user's rule.
    func testDoubleHeaded_isWideAtTheStart() {
        let w = taperedWidths(nominalWidth: 10, startCap: .filled, endCap: .filled)
        XCTAssertGreaterThan(w.atStart, w.atEnd)
    }

    func testNoCaps_isWideAtTheStart() {
        let w = taperedWidths(nominalWidth: 10, startCap: .none, endCap: .none)
        XCTAssertGreaterThan(w.atStart, w.atEnd)
    }

    /// Any non-none cap counts as the head end — a dot tail with a filled head
    /// must still put the wide side at the head... but per the rule, only an
    /// end-only cap flips the taper; mixed caps keep the wide start.
    func testMixedCaps_keepTheWideStart() {
        let w = taperedWidths(nominalWidth: 10, startCap: .dot, endCap: .filled)
        XCTAssertGreaterThan(w.atStart, w.atEnd)
    }

    // MARK: Proportions

    func testWideEndScalesWithNominalWidth_narrowIsFraction() {
        let w = taperedWidths(nominalWidth: 10, startCap: .none, endCap: .filled)
        XCTAssertEqual(w.atEnd, 15, accuracy: 0.001)          // 1.5×
        XCTAssertEqual(w.atStart, 4.5, accuracy: 0.001)        // 30% of wide
    }

    func testNarrowEnd_hasAFloorSoThinArrowsDontVanish() {
        let w = taperedWidths(nominalWidth: 1, startCap: .none, endCap: .filled)
        XCTAssertGreaterThanOrEqual(w.atStart, 1.5)
    }

    // MARK: Shaft quads

    private let start = CGPoint(x: 0, y: 0)
    private let end = CGPoint(x: 100, y: 0)

    func testSolidShaft_isOneTrapezoidWithInterpolatedWidths() throws {
        let quads = taperedShaftQuads(from: start, to: end,
                                      widthAtStart: 4, widthAtEnd: 12,
                                      insetStart: 0, insetEnd: 0, dash: nil)
        let q = try XCTUnwrap(quads.first)
        XCTAssertEqual(quads.count, 1)
        // Horizontal axis: half-widths land on ±y. Start ±2, end ±6.
        XCTAssertEqual(q[0].y, 2, accuracy: 0.001)   // start, +side
        XCTAssertEqual(q[1].y, 6, accuracy: 0.001)   // end, +side
        XCTAssertEqual(q[2].y, -6, accuracy: 0.001)  // end, -side
        XCTAssertEqual(q[3].y, -2, accuracy: 0.001)  // start, -side
    }

    func testInsets_trimLengthWithoutChangingTheProfile() throws {
        let quads = taperedShaftQuads(from: start, to: end,
                                      widthAtStart: 4, widthAtEnd: 12,
                                      insetStart: 10, insetEnd: 20, dash: nil)
        let q = try XCTUnwrap(quads.first)
        XCTAssertEqual(q[0].x, 10, accuracy: 0.001)
        XCTAssertEqual(q[1].x, 80, accuracy: 0.001)
        // Width at x=10 interpolates over the FULL axis: 4 + (12-4)*0.1 = 4.8.
        XCTAssertEqual(q[0].y, 2.4, accuracy: 0.001)
    }

    func testDashedShaft_becomesMultipleTaperedTrapezoids() {
        let quads = taperedShaftQuads(from: start, to: end,
                                      widthAtStart: 4, widthAtEnd: 12,
                                      insetStart: 0, insetEnd: 0,
                                      dash: [10, 10])
        XCTAssertEqual(quads.count, 5, "100pt / (10 on + 10 off) = 5 on-runs")
        // Later dashes are wider than earlier ones — that IS the taper.
        let firstHalfWidth = quads.first![0].y
        let lastHalfWidth = abs(quads.last![1].y)
        XCTAssertGreaterThan(lastHalfWidth, firstHalfWidth)
    }

    func testDegenerateArrow_yieldsNoQuads() {
        XCTAssertTrue(taperedShaftQuads(from: start, to: start,
                                        widthAtStart: 4, widthAtEnd: 12,
                                        insetStart: 0, insetEnd: 0, dash: nil).isEmpty)
        XCTAssertTrue(taperedShaftQuads(from: start, to: end,
                                        widthAtStart: 4, widthAtEnd: 12,
                                        insetStart: 60, insetEnd: 60, dash: nil).isEmpty,
                      "insets that consume the whole shaft leave nothing to fill")
    }
}

/// Model-side behavior: persistence and creation defaults.
@MainActor
final class ShaftStylePersistenceTests: XCTestCase {

    private func makeState() -> EditorState {
        let context = CGContext(
            data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return EditorState(sourceImage: context.makeImage()!, sourceURL: nil)
    }

    func testLegacyStyleJSON_decodesToUniform() throws {
        let legacy = """
        {"strokeColor":{"r":1,"g":0,"b":0,"a":1},"strokeWidth":4,
         "opacity":1,"cornerRadius":0}
        """
        let style = try JSONDecoder().decode(Style.self, from: Data(legacy.utf8))
        XCTAssertEqual(style.shaftStyle, .uniform,
                       "files written before the field existed must render unchanged")
    }

    func testTaperedStyle_roundTrips() throws {
        var style = Style(strokeColor: SerializableColor(NSColor.red), strokeWidth: 4)
        style.shaftStyle = .tapered
        let decoded = try JSONDecoder().decode(Style.self,
                                               from: JSONEncoder().encode(style))
        XCTAssertEqual(decoded.shaftStyle, .tapered)
    }

    func testNewStraightArrows_defaultToTapered() {
        let state = makeState()
        state.selectedTool = .arrow
        XCTAssertEqual(strokeCreationStyle(state: state).shaftStyle, .tapered)
        XCTAssertEqual(state.arrowStartCap, .none)
        XCTAssertEqual(state.arrowEndCap, .filled,
                       "the default tapered arrow is single-headed")
    }

    /// Freehand arrows always render uniform — the user's rule — and lines
    /// never tapered.
    func testFreehandAndLine_neverCreateTapered() {
        let state = makeState()
        state.selectedTool = .penArrow
        XCTAssertEqual(strokeCreationStyle(state: state).shaftStyle, .uniform)
        state.selectedTool = .line
        XCTAssertEqual(strokeCreationStyle(state: state).shaftStyle, .uniform)
    }
}

/// Rendered output: a TRANSLUCENT tapered arrow must composite as one shape.
/// Filling the shaft and the head separately stacked alpha where they overlap,
/// showing a darker band at the head base (the reported bug).
@MainActor
final class TaperedArrowCompositingTests: XCTestCase {

    private func renderArrow(opacity: CGFloat) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 140, pixelsHigh: 40,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        drawConnector(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 130, y: 20),
                      width: 8, color: NSColor.red.withAlphaComponent(opacity),
                      dash: .solid, startCap: .none, endCap: .filled, shaft: .tapered)
        NSGraphicsContext.current?.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    func test_translucentArrow_hasUniformAlphaAcrossHeadAndShaft() throws {
        let rep = renderArrow(opacity: 0.5)
        // Head: tip at x=130, length max(14, 12·2.6)=31.2 → base ≈ 98.8.
        // Shaft inset 0.6·31.2 ≈ 18.7 → shaft reaches ≈ 111. Overlap ≈ 99…111.
        let junction = try XCTUnwrap(rep.colorAt(x: 105, y: 20), "junction pixel")
        let headOnly = try XCTUnwrap(rep.colorAt(x: 120, y: 20), "head interior pixel")
        let shaftOnly = try XCTUnwrap(rep.colorAt(x: 60, y: 20), "shaft pixel")

        XCTAssertGreaterThan(junction.alphaComponent, 0.1, "junction must be painted")
        XCTAssertEqual(junction.alphaComponent, headOnly.alphaComponent, accuracy: 0.02,
                       "head-base overlap must not stack alpha above the head interior")
        XCTAssertEqual(junction.alphaComponent, shaftOnly.alphaComponent, accuracy: 0.02,
                       "the whole silhouette must composite as one fill")
    }

    /// The overlap region must actually be inside both shapes for the test
    /// above to mean anything — an opaque render proves the pixels are painted.
    func test_opaqueArrow_paintsTheProbedPixels() throws {
        let rep = renderArrow(opacity: 1)
        for x in [60, 105, 120] {
            let c = try XCTUnwrap(rep.colorAt(x: x, y: 20))
            XCTAssertGreaterThan(c.alphaComponent, 0.9, "x=\(x) must be solid")
        }
    }
}
