import XCTest
import CoreGraphics
@testable import Sealshot

final class StyleTests: XCTestCase {

    func test_styleDefaults() {
        let s = Style(strokeColor: SerializableColor(r: 1, g: 0, b: 0, a: 1), strokeWidth: 4)
        XCTAssertEqual(s.opacity, 1.0, accuracy: 0.0001)
        XCTAssertNil(s.fillColor)
        XCTAssertEqual(s.cornerRadius, 0)
    }

    func test_clampedCornerRadius() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 40)
        XCTAssertEqual(clampedCornerRadius(8, for: rect), 8, accuracy: 0.0001)
        XCTAssertEqual(clampedCornerRadius(40, for: rect), 20, accuracy: 0.0001)
        XCTAssertEqual(clampedCornerRadius(-5, for: rect), 0, accuracy: 0.0001)
    }

    func test_textStyleDefaults() {
        let s = Style(strokeColor: SerializableColor(r: 0, g: 0, b: 0, a: 1), strokeWidth: 4)
        XCTAssertEqual(s.fontSize, 18, accuracy: 0.0001)
        XCTAssertFalse(s.isBold)
    }

    func test_style_backwardCompat_missingTextFields_usesDefaults() throws {
        // Encode a style with non-default text fields, then strip those keys to
        // simulate an older v2 file, and confirm decode falls back to defaults.
        let style = Style(strokeColor: SerializableColor(r: 1, g: 0, b: 0, a: 1),
                          strokeWidth: 3, fontSize: 40, isBold: true)
        let data = try JSONEncoder().encode(style)
        var obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        obj.removeValue(forKey: "fontSize")
        obj.removeValue(forKey: "isBold")
        let stripped = try JSONSerialization.data(withJSONObject: obj)
        let decoded = try JSONDecoder().decode(Style.self, from: stripped)
        XCTAssertEqual(decoded.fontSize, 18, accuracy: 0.0001)
        XCTAssertFalse(decoded.isBold)
    }

    func test_style_roundTripsTextFields() throws {
        let style = Style(strokeColor: SerializableColor(r: 0, g: 0, b: 1, a: 1),
                          strokeWidth: 2, fontSize: 28, isBold: true)
        let data = try JSONEncoder().encode(style)
        let decoded = try JSONDecoder().decode(Style.self, from: data)
        XCTAssertEqual(decoded, style)
    }

    // MARK: - Arrow caps & dash style

    func test_capDashDefaults_preserveLegacyArrowAppearance() {
        // Defaults reproduce today's look: a single filled head at the END, no
        // start cap, solid shaft.
        let s = Style(strokeColor: SerializableColor(r: 0, g: 0, b: 0, a: 1), strokeWidth: 4)
        XCTAssertEqual(s.startCap, .none)
        XCTAssertEqual(s.endCap, .filled)
        XCTAssertEqual(s.dashStyle, .solid)
    }

    func test_style_backwardCompat_missingCapDashFields_usesDefaults() throws {
        // A v6 file written before these fields existed lacks the keys; decode
        // must fall back to the legacy-preserving defaults, not throw.
        let style = Style(strokeColor: SerializableColor(r: 1, g: 0, b: 0, a: 1),
                          strokeWidth: 3, startCap: .dot, endCap: .open, dashStyle: .dashed)
        let data = try JSONEncoder().encode(style)
        var obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        obj.removeValue(forKey: "startCap")
        obj.removeValue(forKey: "endCap")
        obj.removeValue(forKey: "dashStyle")
        let stripped = try JSONSerialization.data(withJSONObject: obj)
        let decoded = try JSONDecoder().decode(Style.self, from: stripped)
        XCTAssertEqual(decoded.startCap, .none)
        XCTAssertEqual(decoded.endCap, .filled)
        XCTAssertEqual(decoded.dashStyle, .solid)
    }

    func test_style_roundTripsCapDashFields() throws {
        let style = Style(strokeColor: SerializableColor(r: 0, g: 0, b: 1, a: 1),
                          strokeWidth: 2, startCap: .bar, endCap: .dot, dashStyle: .sparseDotted)
        let data = try JSONEncoder().encode(style)
        let decoded = try JSONDecoder().decode(Style.self, from: data)
        XCTAssertEqual(decoded, style)
    }
}
