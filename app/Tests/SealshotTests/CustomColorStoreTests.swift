import XCTest
import AppKit
@testable import Sealshot

final class CustomColorStoreTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        let name = "CustomColorStoreTests." + UUID().uuidString
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func test_add_insertsNewestFirst() {
        let store = CustomColorStore(defaults: makeDefaults())
        store.add(NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        store.add(NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
        XCTAssertEqual(store.colors.map { hexString(from: $0) }, ["#00FF00", "#FF0000"])
    }

    func test_add_dedupesByHexMovingToFront() {
        let store = CustomColorStore(defaults: makeDefaults())
        store.add(NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        store.add(NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        store.add(NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))   // re-add red
        XCTAssertEqual(store.colors.map { hexString(from: $0) }, ["#FF0000", "#0000FF"])
    }

    func test_add_capsAtMaxColors() {
        let store = CustomColorStore(defaults: makeDefaults())
        for i in 0..<(CustomColorStore.maxColors + 5) {
            store.add(NSColor(srgbRed: CGFloat(i) / 255, green: 0, blue: 0, alpha: 1))
        }
        XCTAssertEqual(store.colors.count, CustomColorStore.maxColors)
    }

    func test_remove_byHex() {
        let store = CustomColorStore(defaults: makeDefaults())
        let red = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        store.add(red)
        store.add(NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
        store.remove(NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        XCTAssertEqual(store.colors.map { hexString(from: $0) }, ["#00FF00"])
    }

    func test_persistsAcrossInstances() {
        let name = "CustomColorStoreTests.persist." + UUID().uuidString
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        CustomColorStore(defaults: d).add(NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        let reloaded = CustomColorStore(defaults: d)
        XCTAssertEqual(reloaded.colors.map { hexString(from: $0) }, ["#336699"])
    }
}
