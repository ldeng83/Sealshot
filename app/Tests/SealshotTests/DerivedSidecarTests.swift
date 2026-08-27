import XCTest
import CoreGraphics
@testable import Sealshot

/// `derived.json` — the package's home for results that can always be computed
/// again: the Live Text layout today, extraction and redaction detections next.
///
/// The rule that keeps it safe to delete, rebuild, or drop on a key rotation is
/// that NOTHING authoritative lives here. Applied redactions are user editing
/// and stay in `annotations.json`; only the analyzer's detections would belong
/// in this file.
@MainActor
final class DerivedSidecarTests: XCTestCase {

    private func anchor(_ stamp: String = "2026-08-11T14:00:00Z",
                        bytes: Int = 1234) -> DerivedAnchor {
        DerivedAnchor(modifiedISO8601: stamp, sourceBytes: bytes)
    }

    // MARK: - Envelope

    func test_envelope_roundTripsASection() throws {
        var sidecar = DerivedSidecar()
        sidecar.setSection("textLayout", data: Data([1, 2, 3]))

        let decoded = try DerivedSidecar.decode(sidecar.encoded())
        XCTAssertEqual(decoded.section("textLayout"), Data([1, 2, 3]))
    }

    func test_envelope_keepsSectionsItDoesNotUnderstand() throws {
        // A newer build writes a section this one has never heard of. Re-saving
        // must not quietly delete it — the whole point of holding sections as
        // opaque blobs rather than decoding the file into known fields.
        var fromFuture = DerivedSidecar()
        fromFuture.setSection("somethingNew", data: Data([9, 9, 9]))
        let onDisk = fromFuture.encoded()

        var reopened = try DerivedSidecar.decode(onDisk)
        reopened.setSection("textLayout", data: Data([1]))

        let final = try DerivedSidecar.decode(reopened.encoded())
        XCTAssertEqual(final.section("somethingNew"), Data([9, 9, 9]),
                       "an unknown section must survive a round-trip through this build")
        XCTAssertEqual(final.section("textLayout"), Data([1]))
    }

    func test_envelope_missingSectionIsNil() throws {
        let decoded = try DerivedSidecar.decode(DerivedSidecar().encoded())
        XCTAssertNil(decoded.section("textLayout"))
    }

    func test_envelope_removingASection() throws {
        var sidecar = DerivedSidecar()
        sidecar.setSection("a", data: Data([1]))
        sidecar.setSection("b", data: Data([2]))
        sidecar.removeSection("a")

        let decoded = try DerivedSidecar.decode(sidecar.encoded())
        XCTAssertNil(decoded.section("a"))
        XCTAssertNotNil(decoded.section("b"))
    }

    // MARK: - Anchor

    func test_anchor_matchesOnlyTheSamePixels() {
        let a = anchor()
        XCTAssertTrue(a.matches(a))
        XCTAssertFalse(a.matches(anchor("2026-08-11T14:00:01Z")),
                       "a re-save changes modifiedISO8601, so the layout is stale")
        XCTAssertFalse(a.matches(anchor(bytes: 9999)),
                       "same second, different image — byte size is what separates them")
    }

    // MARK: - Text layout section

    private func layout() -> RecognizedTextLayout {
        RecognizedTextLayout(lines: [
            RecognizedLine(text: "Invoice",
                           box: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.05),
                           charBoxes: (0..<7).map {
                               CGRect(x: 0.1 + Double($0) * 0.04, y: 0.2, width: 0.04, height: 0.05)
                           },
                           quad: TextQuad(topLeft: CGPoint(x: 0.1, y: 0.2),
                                          topRight: CGPoint(x: 0.4, y: 0.21),
                                          bottomRight: CGPoint(x: 0.4, y: 0.26),
                                          bottomLeft: CGPoint(x: 0.1, y: 0.25))),
            RecognizedLine(text: "Total 42",
                           box: CGRect(x: 0.1, y: 0.3, width: 0.2, height: 0.05),
                           charBoxes: [], quad: nil),
        ])
    }

    func test_textLayoutSection_roundTripsGeometryAndText() throws {
        let section = TextLayoutSection(anchor: anchor(), base: .source, crop: nil,
                                        width: 800, height: 600, layout: layout())
        let decoded = try TextLayoutSection.decode(section.encoded())

        XCTAssertEqual(decoded.layout.lines.count, 2)
        XCTAssertEqual(decoded.layout.lines[0].text, "Invoice")
        XCTAssertEqual(decoded.layout.lines[0].charBoxes.count, 7)
        XCTAssertEqual(decoded.layout.lines[0].box.origin.x, 0.1, accuracy: 0.0001)
        XCTAssertNotNil(decoded.layout.lines[0].quad)
        XCTAssertEqual(decoded.layout.lines[0].quad?.topRight.y ?? 0, 0.21, accuracy: 0.0001)
        XCTAssertNil(decoded.layout.lines[1].quad, "a quad-less line must stay quad-less")
    }

    func test_textLayoutSection_rebuildsDerivedCharacters() throws {
        // `characters` exists for integer indexing and is derived from `text`;
        // encoding it would just be a second copy that can disagree.
        let section = TextLayoutSection(anchor: anchor(), base: .source, crop: nil,
                                        width: 800, height: 600, layout: layout())
        let decoded = try TextLayoutSection.decode(section.encoded())
        XCTAssertEqual(decoded.layout.lines[0].characters, Array("Invoice"))
    }

    func test_textLayoutSection_distinguishesEmptyFromAbsent() throws {
        // "This capture has no text" is worth persisting: without it every
        // launch pays a full recognition pass to learn nothing.
        let section = TextLayoutSection(anchor: anchor(), base: .source, crop: nil,
                                        width: 800, height: 600,
                                        layout: RecognizedTextLayout(lines: []))
        let decoded = try TextLayoutSection.decode(section.encoded())
        XCTAssertTrue(decoded.layout.lines.isEmpty)
    }

    func test_textLayoutSection_keepsBasesApart() throws {
        // The enhanced base is different pixels, so its layout is a different
        // record rather than an overwrite of the source one.
        let src = TextLayoutSection(anchor: anchor(), base: .source, crop: nil,
                                    width: 800, height: 600, layout: layout())
        let enh = TextLayoutSection(anchor: anchor(), base: .enhanced, crop: nil,
                                    width: 1600, height: 1200, layout: layout())
        XCTAssertNotEqual(src.recordKey, enh.recordKey)
    }

    func test_textLayoutSection_cropIsPartOfIdentity() throws {
        let full = TextLayoutSection(anchor: anchor(), base: .source, crop: nil,
                                     width: 800, height: 600, layout: layout())
        let cropped = TextLayoutSection(anchor: anchor(), base: .source,
                                        crop: CGRect(x: 0, y: 0, width: 0.5, height: 0.5),
                                        width: 800, height: 600, layout: layout())
        XCTAssertNotEqual(full.recordKey, cropped.recordKey)
    }

    func test_textLayoutSection_geometryStaysCompact() throws {
        // Flat single-precision arrays rather than nested objects of Doubles:
        // a text-heavy capture runs to thousands of char boxes, and the nested
        // form is roughly an order of magnitude larger.
        let manyLines = (0..<200).map { i in
            RecognizedLine(text: String(repeating: "x", count: 40),
                           box: CGRect(x: 0, y: Double(i) / 200, width: 1, height: 0.004),
                           charBoxes: (0..<40).map {
                               CGRect(x: Double($0) / 40, y: Double(i) / 200,
                                      width: 0.025, height: 0.004)
                           })
        }
        let section = TextLayoutSection(anchor: anchor(), base: .source, crop: nil,
                                        width: 2000, height: 1500,
                                        layout: RecognizedTextLayout(lines: manyLines))
        let size = section.encoded().count
        XCTAssertLessThan(size, 400_000,
                          "8000 char boxes encoded to \(size) bytes — geometry is not compact")
    }
}
