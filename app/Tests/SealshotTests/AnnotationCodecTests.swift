import XCTest
@testable import Sealshot

final class AnnotationCodecTests: XCTestCase {

    func testRoundTrip_empty() throws {
        let data = try encodeAnnotations([], crop: nil)
        let decoded = try decodeAnnotations(from: data)
        XCTAssertEqual(decoded.annotations, [])
        XCTAssertNil(decoded.crop)
    }

    func testRoundTrip_arrowOnly() throws {
        let arrow = Annotation(
            geometry: .arrow(start: CGPoint(x: 5, y: 10), end: CGPoint(x: 50, y: 60)),
            style: Style(strokeColor: SerializableColor(r: 1, g: 0, b: 0, a: 1), strokeWidth: 3)
        )
        let data = try encodeAnnotations([arrow], crop: nil)
        let decoded = try decodeAnnotations(from: data)
        XCTAssertEqual(decoded.annotations, [arrow])
    }

    func testRoundTrip_rectangleOnly() throws {
        let rect = Annotation(
            geometry: .rectangle(rect: CGRect(x: 0, y: 0, width: 100, height: 80)),
            style: Style(strokeColor: SerializableColor(r: 0, g: 0, b: 1, a: 1), strokeWidth: 3)
        )
        let data = try encodeAnnotations([rect], crop: nil)
        let decoded = try decodeAnnotations(from: data)
        XCTAssertEqual(decoded.annotations, [rect])
    }

    func testRoundTrip_mixedList() throws {
        let arrow = Annotation(
            geometry: .arrow(start: .zero, end: CGPoint(x: 10, y: 10)),
            style: Style(strokeColor: SerializableColor(r: 1, g: 1, b: 0, a: 1), strokeWidth: 3)
        )
        let rect = Annotation(
            geometry: .rectangle(rect: CGRect(x: 5, y: 5, width: 20, height: 30)),
            style: Style(strokeColor: SerializableColor(r: 0, g: 1, b: 0, a: 1), strokeWidth: 3)
        )
        let data = try encodeAnnotations([arrow, rect], crop: nil)
        let decoded = try decodeAnnotations(from: data)
        XCTAssertEqual(decoded.annotations.count, 2)
        XCTAssertEqual(decoded.annotations[0], arrow)
        XCTAssertEqual(decoded.annotations[1], rect)
    }

    func testRoundTrip_withCrop() throws {
        let crop = CGRect(x: 10, y: 20, width: 100, height: 80)
        let data = try encodeAnnotations([], crop: crop)
        let decoded = try decodeAnnotations(from: data)
        XCTAssertEqual(decoded.crop, crop)
    }

    func testRoundTrip_withoutCrop() throws {
        let data = try encodeAnnotations([], crop: nil)
        let decoded = try decodeAnnotations(from: data)
        XCTAssertNil(decoded.crop)
    }

    // Genuine hand-written version-1 fixture (pre-geometry/style split).
    // The exact JSON shape was discovered by encoding through a local mirror of
    // the OLD model (LegacyKind / LegacyAnnotation / LegacyEnvelope) with
    // JSONEncoder outputFormatting [.sortedKeys], then pasting the result here.
    // CGPoint serialises as a two-element JSON array [x,y]; croppedRect:nil
    // omits the key entirely. The current decoder must migrate this to
    // geometry-preserved + default Style without touching any source file.
    func testDecode_v1Legacy_defaultsStyle() throws {
        // swiftlint:disable:next line_length
        let json = """
        {"annotations":[{"id":"00000000-0000-0000-0000-000000000001","kind":{"arrow":{"color":{"a":1,"b":0,"g":0,"r":1},"end":[50,60],"start":[5,10],"strokeWidth":3}}}],"version":1}
        """.data(using: .utf8)!

        let decoded = try decodeAnnotations(from: json)
        XCTAssertEqual(decoded.annotations.count, 1)
        let a = decoded.annotations[0]
        XCTAssertEqual(a.geometry, .arrow(start: CGPoint(x: 5, y: 10), end: CGPoint(x: 50, y: 60)))
        XCTAssertEqual(a.style.opacity, 1.0, accuracy: 0.0001)
        XCTAssertNil(a.style.fillColor)
        XCTAssertEqual(a.style.cornerRadius, 0)
        XCTAssertEqual(a.style.strokeWidth, 3)
    }

    func testRoundTrip_textBox() throws {
        let text = Annotation(
            geometry: .text(rect: CGRect(x: 10, y: 20, width: 160, height: 40),
                            runs: [TextRun(text: "Hello",
                                           color: SerializableColor(r: 0, g: 0, b: 0, a: 1),
                                           fontSize: 24, isBold: true)]),
            style: Style(strokeColor: SerializableColor(r: 0, g: 0, b: 0, a: 1),
                         strokeWidth: 0, fontSize: 24, isBold: true)
        )
        let data = try encodeAnnotations([text], crop: nil)
        let decoded = try decodeAnnotations(from: data)
        XCTAssertEqual(decoded.annotations, [text])
    }

    func testRoundTrip_textRuns_v3() throws {
        let t = Annotation(
            geometry: .text(rect: CGRect(x: 1, y: 2, width: 120, height: 40),
                            runs: [TextRun(text: "Hi ", color: SerializableColor(r: 1, g: 0, b: 0, a: 1), fontSize: 18, isBold: false),
                                   TextRun(text: "there", color: SerializableColor(r: 0, g: 0, b: 1, a: 1), fontSize: 24, isBold: true)]),
            style: Style(strokeColor: SerializableColor(r: 0, g: 0, b: 0, a: 1), strokeWidth: 0))
        let data = try encodeAnnotations([t], crop: nil)
        XCTAssertEqual(try decodeAnnotations(from: data).annotations, [t])
    }

    func testMigration_v2Text_toSingleRun() throws {
        // Build a v2 envelope programmatically via local mirror types so the JSON
        // matches Swift's synthesized shape exactly, then decode via decodeAnnotations.
        struct OldEnv: Encodable {
            struct Ann: Encodable { let id: UUID; let geometry: Geo; let style: Style }
            enum Geo: Encodable { case text(rect: CGRect, string: String)
                func encode(to encoder: Encoder) throws {
                    var c = encoder.container(keyedBy: CodingKeys.self)
                    switch self { case let .text(rect, string):
                        var n = c.nestedContainer(keyedBy: TextKeys.self, forKey: .text)
                        try n.encode(rect, forKey: .rect); try n.encode(string, forKey: .string) }
                }
                enum CodingKeys: String, CodingKey { case text }
                enum TextKeys: String, CodingKey { case rect, string }
            }
            let version: Int; let annotations: [Ann]; let croppedRect: CGRect?
        }
        let id = UUID()
        let env = OldEnv(version: 2, annotations: [.init(
            id: id, geometry: .text(rect: CGRect(x: 3, y: 4, width: 100, height: 20), string: "Legacy"),
            style: Style(strokeColor: SerializableColor(r: 1, g: 0, b: 0, a: 1), strokeWidth: 0,
                         fontSize: 28, isBold: true))], croppedRect: nil)
        let data = try JSONEncoder().encode(env)
        let decoded = try decodeAnnotations(from: data)
        XCTAssertEqual(decoded.annotations.count, 1)
        guard case let .text(rect, runs) = decoded.annotations[0].geometry else { return XCTFail("expected text") }
        XCTAssertEqual(rect, CGRect(x: 3, y: 4, width: 100, height: 20))
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].text, "Legacy")
        XCTAssertEqual(runs[0].fontSize, 28, accuracy: 0.01)
        XCTAssertTrue(runs[0].isBold)
        XCTAssertEqual(runs[0].color, SerializableColor(r: 1, g: 0, b: 0, a: 1))
    }

    func testRoundTrip_ellipse() throws {
        let e = Annotation(
            geometry: .ellipse(rect: CGRect(x: 5, y: 6, width: 40, height: 30)),
            style: Style(strokeColor: SerializableColor(r: 0, g: 1, b: 0, a: 1), strokeWidth: 3,
                         fillColor: SerializableColor(r: 0, g: 0, b: 1, a: 1))
        )
        let data = try encodeAnnotations([e], crop: nil)
        XCTAssertEqual(try decodeAnnotations(from: data).annotations, [e])
    }

    func testRoundTrip_line() throws {
        let l = Annotation(
            geometry: .line(start: CGPoint(x: 1, y: 2), end: CGPoint(x: 30, y: 40)),
            style: Style(strokeColor: SerializableColor(r: 1, g: 0, b: 0, a: 1), strokeWidth: 4))
        let data = try encodeAnnotations([l], crop: nil)
        XCTAssertEqual(try decodeAnnotations(from: data).annotations, [l])
    }

    func testRoundTrip_badge() throws {
        let b = Annotation(
            geometry: .badge(center: CGPoint(x: 20, y: 30), radius: 18),
            style: Style(strokeColor: SerializableColor(r: 1, g: 1, b: 1, a: 1), strokeWidth: 0,
                         fillColor: SerializableColor(r: 1, g: 0, b: 0, a: 1)))
        let data = try encodeAnnotations([b], crop: nil)
        XCTAssertEqual(try decodeAnnotations(from: data).annotations, [b])
    }

    func testMigration_v2Mixed_preservesNonTextShapes() throws {
        // Local v2 mirror that can encode a rectangle and a text annotation.
        struct OldEnv: Encodable {
            struct Ann: Encodable { let id: UUID; let geometry: Geo; let style: Style }
            enum Geo: Encodable {
                case rectangle(rect: CGRect)
                case text(rect: CGRect, string: String)
                func encode(to encoder: Encoder) throws {
                    var c = encoder.container(keyedBy: CodingKeys.self)
                    switch self {
                    case let .rectangle(rect):
                        var n = c.nestedContainer(keyedBy: RectKeys.self, forKey: .rectangle)
                        try n.encode(rect, forKey: .rect)
                    case let .text(rect, string):
                        var n = c.nestedContainer(keyedBy: TextKeys.self, forKey: .text)
                        try n.encode(rect, forKey: .rect); try n.encode(string, forKey: .string)
                    }
                }
                enum CodingKeys: String, CodingKey { case rectangle, text }
                enum RectKeys: String, CodingKey { case rect }
                enum TextKeys: String, CodingKey { case rect, string }
            }
            let version: Int; let annotations: [Ann]; let croppedRect: CGRect?
        }
        let rectID = UUID(), textID = UUID()
        let env = OldEnv(version: 2, annotations: [
            .init(id: rectID, geometry: .rectangle(rect: CGRect(x: 5, y: 6, width: 30, height: 40)),
                  style: Style(strokeColor: SerializableColor(r: 0, g: 1, b: 0, a: 1), strokeWidth: 3)),
            .init(id: textID, geometry: .text(rect: CGRect(x: 1, y: 1, width: 50, height: 20), string: "Hi"),
                  style: Style(strokeColor: SerializableColor(r: 0, g: 0, b: 0, a: 1), strokeWidth: 0)),
        ], croppedRect: nil)
        let data = try JSONEncoder().encode(env)
        let decoded = try decodeAnnotations(from: data)
        XCTAssertEqual(decoded.annotations.count, 2)
        XCTAssertEqual(decoded.annotations[0].id, rectID)
        guard case let .rectangle(rect) = decoded.annotations[0].geometry else { return XCTFail("expected rectangle") }
        XCTAssertEqual(rect, CGRect(x: 5, y: 6, width: 30, height: 40))
        guard case .text = decoded.annotations[1].geometry else { return XCTFail("expected text") }
    }

    // A future/unknown envelope version (e.g. one written by a newer build)
    // throws the typed error so the caller can surface "newer version" vs a
    // generic read failure — the fix for the stuck-strip-highlight bug.
    func testDecode_futureVersion_throwsUnsupportedVersion() {
        // v13 is beyond the current v12 envelope — stands in for a package written
        // by a newer build.
        let json = #"{"annotations":[],"version":13}"#.data(using: .utf8)!
        XCTAssertThrowsError(try decodeAnnotations(from: json)) { error in
            guard case AnnotationCodecError.unsupportedVersion(let v) = error else {
                return XCTFail("expected unsupportedVersion, got \(error)")
            }
            XCTAssertEqual(v, 13)
        }
    }

    // MARK: - v12 Style.textLayoutWidth (text mask model)

    func testTextLayoutWidth_roundTrips() throws {
        var style = Style(strokeColor: SerializableColor(.black), strokeWidth: 0)
        style.textLayoutWidth = 320
        let a = Annotation(geometry: .text(rect: CGRect(x: 0, y: 0, width: 100, height: 40),
                                           runs: [TextRun(text: "Hi", color: SerializableColor(.black),
                                                          fontSize: 18, isBold: false)]),
                           style: style)
        let data = try encodeAnnotations([a], crop: nil)
        let decoded = try decodeAnnotations(from: data)
        XCTAssertEqual(decoded.annotations.first?.style.textLayoutWidth, 320)
    }

    func testTextLayoutWidth_absentDecodesNil() throws {
        // A style JSON without the key (any pre-v12 file) → nil.
        let a = Annotation(geometry: .rectangle(rect: .zero),
                           style: Style(strokeColor: SerializableColor(.black), strokeWidth: 1))
        let data = try encodeAnnotations([a], crop: nil)
        XCTAssertNil(try decodeAnnotations(from: data).annotations.first?.style.textLayoutWidth)
    }

    // MARK: - v9 background fill

    func testRoundTrip_backgroundFill() throws {
        let fill = SerializableColor(r: 0.2, g: 0.4, b: 0.6, a: 1)
        let data = try encodeAnnotations([], crop: nil, backgroundFill: fill)
        let decoded = try decodeAnnotations(from: data)
        XCTAssertEqual(decoded.backgroundFill, fill)
    }

    func testRoundTrip_backgroundFill_nilIsTransparent() throws {
        let data = try encodeAnnotations([], crop: nil)
        let decoded = try decodeAnnotations(from: data)
        XCTAssertNil(decoded.backgroundFill)
    }

    // A pre-v9 package has no backgroundFill key; it must decode to nil
    // (transparent) rather than fail.
    func testDecode_preV9_backgroundFillDefaultsNil() throws {
        let json = #"{"annotations":[],"version":8,"resizedSize":null}"#.data(using: .utf8)!
        let decoded = try decodeAnnotations(from: json)
        XCTAssertNil(decoded.backgroundFill)
    }
}
