import XCTest
@testable import Sealshot

/// Per-tool opacity memory: each tool remembers its own creation opacity and
/// persists it — lowering the arrow's opacity must never dim the next
/// rectangle. Mirrors `ToolColorDefaultsTests`.
@MainActor
final class ToolOpacityDefaultsStoreTests: XCTestCase {

    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "tool-opacity-defaults-tests")!
        defaults.removePersistentDomain(forName: "tool-opacity-defaults-tests")
    }
    override func tearDown() {
        defaults.removePersistentDomain(forName: "tool-opacity-defaults-tests")
        super.tearDown()
    }

    func testRoundTrip_perToolIsolation() {
        var store = ToolOpacityDefaults(defaults: defaults)
        store.set(0.5, for: .arrow)
        store.set(0.2, for: .rectangle)
        XCTAssertEqual(store.opacity(for: .arrow), 0.5)
        XCTAssertEqual(store.opacity(for: .rectangle), 0.2)
        XCTAssertNil(store.opacity(for: .line), "never-set tool must read as unset")
    }

    func testNeverSet_isNilNotZero() {
        let store = ToolOpacityDefaults(defaults: defaults)
        XCTAssertNil(store.opacity(for: .text),
                     "absent key must be nil, not the 0.0 that double(forKey:) returns")
    }
}

/// EditorState behavior: the live `creationOpacity` swaps per tool.
@MainActor
final class EditorStateToolOpacityTests: XCTestCase {

    override func setUp() { super.setUp(); clearOpacityDefaults() }
    override func tearDown() { clearOpacityDefaults(); super.tearDown() }
    private func clearOpacityDefaults() {
        for tool in EditorTool.allCases {
            UserDefaults.standard.removeObject(forKey: "annotationOpacityDefault.\(tool.rawValue)")
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

    func testOpacityRemembersPerTool() {
        let s = state()
        s.selectedTool = .arrow
        s.creationOpacity = 0.5
        s.selectedTool = .rectangle
        XCTAssertEqual(s.creationOpacity, 1.0, accuracy: 1e-9,
                       "rectangle must start fully opaque, not inherit the arrow's 0.5")
        s.creationOpacity = 0.3
        s.selectedTool = .arrow
        XCTAssertEqual(s.creationOpacity, 0.5, accuracy: 1e-9)
        s.selectedTool = .rectangle
        XCTAssertEqual(s.creationOpacity, 0.3, accuracy: 1e-9)
    }

    func testOpacityPersistsAcrossStates() {
        let s1 = state()
        s1.selectedTool = .arrow
        s1.creationOpacity = 0.4
        let s2 = state()
        s2.selectedTool = .arrow
        XCTAssertEqual(s2.creationOpacity, 0.4, accuracy: 1e-9,
                       "per-tool opacity must persist to a fresh editor state")
    }

    func testAdoptForToolUpdatesThatToolsSlot_notThePreviousOwner() {
        let s = state()
        s.selectedTool = .arrow
        s.creationOpacity = 0.5
        s.selectedTool = .select   // editing happens in the neutral tool
        let style = Style(strokeColor: SerializableColor(.red), strokeWidth: 2, opacity: 0.2)
        s.adoptStyleAsToolDefault(style, for: .rectangle)
        s.selectedTool = .arrow
        XCTAssertEqual(s.creationOpacity, 0.5, accuracy: 1e-9,
                       "adopting a rectangle's opacity must not dim the arrow")
        s.selectedTool = .rectangle
        XCTAssertEqual(s.creationOpacity, 0.2, accuracy: 1e-9)
    }

    func testRememberTextToolStyle_targetsTextSlot_notASwitchedTool() {
        let s = state()
        // Simulate committing a text edit AFTER switching to the arrow tool:
        // the arrow already owns the live opacity var.
        s.selectedTool = .arrow
        s.creationOpacity = 0.9
        s.rememberTextToolStyle(color: .blue, opacity: 0.25)
        XCTAssertEqual(s.creationOpacity, 0.9, accuracy: 1e-9,
                       "remembering text style must not dim the arrow that owns the live var")
        s.selectedTool = .text
        XCTAssertEqual(s.creationOpacity, 0.25, accuracy: 1e-9,
                       "the text tool must load its remembered opacity on activation")
        XCTAssertEqual(SerializableColor(s.selectedColor), SerializableColor(.blue),
                       "the text tool must load its remembered color on activation")
    }
}
