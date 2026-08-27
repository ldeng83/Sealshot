import MachO
import XCTest

/// Reads the Info.plist *source files* from the repo (not the built bundle),
/// so both editions' configurations are testable from the MAS test run.
final class SparklePlistConfigurationTests: XCTestCase {
    private func plist(_ relativeToApp: String) throws -> [String: Any] {
        let appDir = URL(fileURLWithPath: #filePath)   // .../app/Tests/SealshotTests/ThisFile.swift
            .deletingLastPathComponent()               // SealshotTests
            .deletingLastPathComponent()               // Tests
            .deletingLastPathComponent()               // app
        let url = appDir.appendingPathComponent(relativeToApp)
        let data = try Data(contentsOf: url)
        let parsed = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return try XCTUnwrap(parsed as? [String: Any])
    }

    func testDirectPlistConfiguresSparkle() throws {
        let direct = try plist("Resources/Direct/Info.plist")
        XCTAssertEqual(
            direct["SUFeedURL"] as? String,
            "https://raw.githubusercontent.com/ldeng83/Sealshot/main/appcast.xml"
        )
        let key = try XCTUnwrap(direct["SUPublicEDKey"] as? String)
        XCTAssertEqual(key.count, 44, "expected a base64 Ed25519 public key")
        XCTAssertEqual(direct["SUEnableAutomaticChecks"] as? Bool, true)
    }

    func testMASPlistHasNoSparkleKeys() throws {
        let mas = try plist("Resources/MAS/Info.plist")
        XCTAssertNil(mas["SUFeedURL"])
        XCTAssertNil(mas["SUPublicEDKey"])
        XCTAssertNil(mas["SUEnableAutomaticChecks"])
    }

    func testMASProcessLoadsNoSparkleFramework() {
        // Regression gate: the MAS binary must not link Sparkle. Inspect
        // loaded images rather than the Frameworks folder on disk — both
        // schemes share a DerivedData products path, so a stale embedded
        // Sparkle.framework from a previous Direct build can sit in the
        // bundle without being linked or loaded.
        for i in 0..<_dyld_image_count() {
            guard let cName = _dyld_get_image_name(i) else { continue }
            let path = String(cString: cName)
            XCTAssertFalse(path.contains("Sparkle.framework"),
                           "Sparkle is loaded into the MAS process: \(path)")
        }
    }
}
