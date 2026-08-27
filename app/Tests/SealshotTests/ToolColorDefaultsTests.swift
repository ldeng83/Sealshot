import XCTest
@testable import Sealshot

/// Per-tool color memory: every color a tool exposes (stroke, shape fill,
/// badge fill/number, blur solid) is remembered per tool and persisted —
/// changing the pen's color must never repaint the next rectangle.
@MainActor
final class ToolColorDefaultsTests: XCTestCase {

    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "tool-color-defaults-tests")!
        defaults.removePersistentDomain(forName: "tool-color-defaults-tests")
    }
    override func tearDown() {
        defaults.removePersistentDomain(forName: "tool-color-defaults-tests")
        super.tearDown()
    }

    private let green = SerializableColor(r: 0, g: 1, b: 0, a: 1)
    private let blue = SerializableColor(r: 0, g: 0, b: 1, a: 1)

    func testRoundTrip_perToolPerRoleIsolation() {
        var store = ToolColorDefaults(defaults: defaults)
        store.set(green, .stroke, for: .pen)
        store.set(blue, .stroke, for: .rectangle)
        XCTAssertTrue(store.color(.stroke, for: .pen) == .some(green))
        XCTAssertTrue(store.color(.stroke, for: .rectangle) == .some(blue))
        XCTAssertTrue(store.color(.stroke, for: .line) == nil, "never-set tool must read as unset")
        XCTAssertTrue(store.color(.fill, for: .rectangle) == nil, "roles are independent")
    }

    func testExplicitNoFill_distinctFromNeverSet() {
        var store = ToolColorDefaults(defaults: defaults)
        XCTAssertTrue(store.color(.fill, for: .rectangle) == nil)
        store.set(nil, .fill, for: .rectangle)   // the user chose "No fill"
        XCTAssertTrue(store.color(.fill, for: .rectangle) == .some(nil),
                      "explicit no-fill must round-trip distinctly from never-set")
    }
}

/// EditorState behavior: live creation-color vars swap per tool.
@MainActor
final class EditorStateToolColorsTests: XCTestCase {

    override func setUp() { super.setUp(); clearColorDefaults() }
    override func tearDown() { clearColorDefaults(); super.tearDown() }
    private func clearColorDefaults() {
        for tool in EditorTool.allCases {
            for role in ToolColorRole.allCases {
                UserDefaults.standard.removeObject(
                    forKey: "annotationColorDefault.\(tool.rawValue).\(role.rawValue)")
            }
        }
    }

    private func state() -> EditorState {
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return EditorState(sourceImage: ctx.makeImage()!, sourceURL: nil)
    }

    private let green = NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
    private let blue = NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
    private let yellow = NSColor(srgbRed: 1, green: 1, blue: 0, alpha: 1)

    func testStrokeColorRemembersPerTool() {
        let s = state()
        s.selectedTool = .pen
        s.selectedColor = green
        s.selectedTool = .rectangle
        XCTAssertEqual(SerializableColor(s.selectedColor), SerializableColor(.red),
                       "rectangle must start at its own default, not the pen's pick")
        s.selectedColor = blue
        s.selectedTool = .pen
        XCTAssertEqual(SerializableColor(s.selectedColor), SerializableColor(green))
        s.selectedTool = .rectangle
        XCTAssertEqual(SerializableColor(s.selectedColor), SerializableColor(blue))
    }

    func testShapeFillRemembersPerTool_includingExplicitNoFill() {
        let s = state()
        s.selectedTool = .rectangle
        s.shapeFillColor = yellow
        s.selectedTool = .ellipse
        XCTAssertNil(s.shapeFillColor, "ellipse starts at its own default (no fill)")
        s.shapeFillColor = blue
        s.selectedTool = .rectangle
        XCTAssertEqual(s.shapeFillColor.map { SerializableColor($0) }, SerializableColor(yellow))
        s.shapeFillColor = nil                       // the user picks "No fill" for rectangles
        s.selectedTool = .ellipse
        XCTAssertEqual(s.shapeFillColor.map { SerializableColor($0) }, SerializableColor(blue))
        s.selectedTool = .rectangle
        XCTAssertNil(s.shapeFillColor, "explicit no-fill must be remembered, not revert")
    }

    func testBadgeAndBlurColorsRememberPerTool() {
        let s = state()
        s.selectedTool = .badge
        s.badgeFillColor = blue
        s.badgeNumberColor = green
        s.selectedTool = .blur
        s.blurSolidColor = yellow
        s.selectedTool = .pen
        s.selectedTool = .badge
        XCTAssertEqual(SerializableColor(s.badgeFillColor), SerializableColor(blue))
        XCTAssertEqual(SerializableColor(s.badgeNumberColor), SerializableColor(green))
        s.selectedTool = .blur
        XCTAssertEqual(SerializableColor(s.blurSolidColor), SerializableColor(yellow))
    }

    func testColorsPersistAcrossStates() {
        let s1 = state()
        s1.selectedTool = .pen
        s1.selectedColor = green
        let s2 = state()
        s2.selectedTool = .pen
        XCTAssertEqual(SerializableColor(s2.selectedColor), SerializableColor(green),
                       "per-tool colors must persist to a fresh editor state")
    }

    func testAdoptForToolUpdatesThatToolsSlot_notThePreviousOwner() {
        let s = state()
        s.selectedTool = .pen
        s.selectedColor = green
        s.selectedTool = .select   // editing happens in the neutral tool
        let style = Style(strokeColor: SerializableColor(blue), strokeWidth: 2,
                          fillColor: SerializableColor(yellow))
        s.adoptStyleAsToolDefault(style, for: .rectangle)
        s.selectedTool = .pen
        XCTAssertEqual(SerializableColor(s.selectedColor), SerializableColor(green),
                       "adopting a rectangle's style must not pollute the pen's color")
        s.selectedTool = .rectangle
        XCTAssertEqual(SerializableColor(s.selectedColor), SerializableColor(blue))
        XCTAssertEqual(s.shapeFillColor.map { SerializableColor($0) }, SerializableColor(yellow))
    }
}
