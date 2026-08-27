import XCTest
@testable import Sealshot

final class ToolShadowDefaultsTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "shadow-test-\(UUID().uuidString)")!
    }

    func testUnsetToolReturnsPronounced() {
        let store = ToolShadowDefaults(defaults: freshDefaults())
        XCTAssertEqual(store.shadow(for: .arrow), .pronounced)
    }

    func testPerToolIndependent() {
        var store = ToolShadowDefaults(defaults: freshDefaults())
        var lineShadow = ShadowStyle.pronounced
        lineShadow.blur = 2
        store.set(lineShadow, for: .line)
        XCTAssertEqual(store.shadow(for: .line).blur, 2)
        XCTAssertEqual(store.shadow(for: .arrow), .pronounced, "arrow unaffected by line")
    }

    func testPersistsAcrossInstances() {
        let d = freshDefaults()
        var a = ToolShadowDefaults(defaults: d)
        var s = ShadowStyle.pronounced; s.opacity = 0.1
        a.set(s, for: .rectangle)
        let b = ToolShadowDefaults(defaults: d)
        XCTAssertEqual(b.shadow(for: .rectangle).opacity, 0.1, accuracy: 1e-9)
    }
}
