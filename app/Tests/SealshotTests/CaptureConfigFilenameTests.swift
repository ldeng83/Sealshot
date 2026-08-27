import XCTest
@testable import Sealshot

@MainActor
final class CaptureConfigFilenameTests: XCTestCase {

    func testRenderFilename_defaultFormat_matchesSystemStyle() {
        let config = CaptureConfig()
        config.filenameFormat = CaptureConfig.defaultFilenameFormat
        let name = config.renderFilename(at: Date(timeIntervalSince1970: 1_780_000_000))
        // Default = date + 12-hour time with AM/PM and milliseconds, underscores
        // in the time: "YYYY-MM-DD at H_MM_SS_mmm AM/PM.png". Milliseconds keep
        // two captures taken in the same second from colliding.
        let pattern = #"^\d{4}-\d{2}-\d{2} at \d{1,2}_\d{2}_\d{2}_\d{3} (AM|PM)\.png$"#
        XCTAssertNotNil(
            name.range(of: pattern, options: .regularExpression),
            "Filename did not match system-style pattern. Got: \(name)"
        )
    }

    func testRenderFilename_customFormat_isApplied() {
        let config = CaptureConfig()
        config.filenameFormat = "'cap-'yyyyMMdd-HHmmss"
        let name = config.renderFilename(at: Date(timeIntervalSince1970: 1_780_000_000))
        let pattern = #"^cap-\d{8}-\d{6}\.png$"#
        XCTAssertNotNil(
            name.range(of: pattern, options: .regularExpression),
            "Custom format did not apply. Got: \(name)"
        )
    }

    @MainActor
    func test_renderFilename_withCustomExtension() {
        let config = CaptureConfig()
        let date = Date(timeIntervalSince1970: 0)   // 1970-01-01 00:00:00 UTC
        let name = config.renderFilename(extension: "seal", at: date)
        XCTAssertTrue(name.hasSuffix(".seal"), "got \(name)")
        XCTAssertFalse(name.hasSuffix(".png"))
    }

    @MainActor
    func test_renderFilename_defaultExtensionIsPng() {
        let config = CaptureConfig()
        let name = config.renderFilename()
        XCTAssertTrue(name.hasSuffix(".png"), "got \(name)")
    }

    func testMigration_nilUsesNewDefault() {
        XCTAssertEqual(CaptureConfig.migratedFilenameFormat(stored: nil),
                       CaptureConfig.defaultFilenameFormat)
    }

    func testMigration_legacyDefaultUpgradedToNew() {
        XCTAssertEqual(
            CaptureConfig.migratedFilenameFormat(stored: CaptureConfig.legacyDefaultFilenameFormat),
            CaptureConfig.defaultFilenameFormat)
    }

    func testMigration_customFormatUntouched() {
        XCTAssertEqual(CaptureConfig.migratedFilenameFormat(stored: "'cap-'yyyyMMdd"), "'cap-'yyyyMMdd")
    }

    func testMigration_prior24HourDefaultUpgraded() {
        // The earlier 24-hour underscore default upgrades to the new 12-hour one.
        XCTAssertEqual(
            CaptureConfig.migratedFilenameFormat(stored: "yyyy-MM-dd 'at' HH_mm_ss"),
            CaptureConfig.defaultFilenameFormat)
    }

    func testMigration_anySealshotPrefixedFormatUpgraded() {
        // A 'Sealshot'-prefixed variant (e.g. underscores) is still the old
        // scheme and must drop the literal, not be treated as a custom format.
        XCTAssertEqual(
            CaptureConfig.migratedFilenameFormat(stored: "'Sealshot' yyyy-MM-dd 'at' HH_mm_ss"),
            CaptureConfig.defaultFilenameFormat)
    }

    func testMigration_priorSecondsDefaultUpgradedToMilliseconds() {
        // The pre-milliseconds 12-hour default upgrades to the new ms default so
        // existing users get collision-free filenames without re-configuring.
        XCTAssertEqual(
            CaptureConfig.migratedFilenameFormat(stored: "yyyy-MM-dd 'at' h_mm_ss a"),
            CaptureConfig.defaultFilenameFormat)
    }

    func testDefaultFormat_includesMilliseconds() {
        XCTAssertTrue(CaptureConfig.defaultFilenameFormat.contains("SSS"),
                      "default format should carry milliseconds; got \(CaptureConfig.defaultFilenameFormat)")
    }

    func testMigration_alreadyNewUntouched() {
        XCTAssertEqual(
            CaptureConfig.migratedFilenameFormat(stored: CaptureConfig.defaultFilenameFormat),
            CaptureConfig.defaultFilenameFormat)
    }

    // MARK: - Encryption-aware filename subject

    func test_filenameSubject_encryptionOff_keepsSubject() {
        XCTAssertEqual(
            CaptureConfig.filenameSubject("Safari — Bank", encryptionEnabled: false),
            "Safari — Bank")
    }

    func test_filenameSubject_encryptionOn_dropsSubject() {
        // While encryption is on, the filename must not leak the app/window
        // title — the subject is dropped so composeBase yields timestamp-only.
        XCTAssertNil(CaptureConfig.filenameSubject("Safari — Bank", encryptionEnabled: true))
    }

    func test_composeBase_withDroppedSubject_isTimestampOnly() {
        let date = Date(timeIntervalSince1970: 1_780_000_000)
        let subject = CaptureConfig.filenameSubject("Safari — Bank", encryptionEnabled: true)
        let base = CaptureConfig.composeBase(
            subject: subject, format: CaptureConfig.defaultFilenameFormat, at: date)
        // No subject prefix — matches the bare date format (with milliseconds).
        let pattern = #"^\d{4}-\d{2}-\d{2} at \d{1,2}_\d{2}_\d{2}_\d{3} (AM|PM)$"#
        XCTAssertNotNil(base.range(of: pattern, options: .regularExpression),
                        "expected timestamp-only base, got: \(base)")
    }

    // MARK: - Capture filename base (include-title policy, encryption-agnostic)

    private static let fixedDate = Date(timeIntervalSince1970: 1_780_000_000)
    private static let timestampPattern = #"\d{4}-\d{2}-\d{2} at \d{1,2}_\d{2}_\d{2}_\d{3} (AM|PM)"#

    func test_captureFilenameBase_includeTitle_usesAppThenTitle() {
        let base = CaptureConfig.captureFilenameBase(
            title: "Bank Statement", app: "Safari", includeTitle: true,
            format: CaptureConfig.defaultFilenameFormat, at: Self.fixedDate)
        XCTAssertTrue(base.hasPrefix("Safari Bank Statement "), "got: \(base)")
        XCTAssertNotNil(base.range(of: "^Safari Bank Statement \(Self.timestampPattern)$",
                                   options: .regularExpression), "got: \(base)")
    }

    func test_captureFilenameBase_includeTitle_noTitle_usesAppOnly() {
        // AI metadata off / no window title: the app name alone still names the file.
        let base = CaptureConfig.captureFilenameBase(
            title: nil, app: "Safari", includeTitle: true,
            format: CaptureConfig.defaultFilenameFormat, at: Self.fixedDate)
        XCTAssertNotNil(base.range(of: "^Safari \(Self.timestampPattern)$",
                                   options: .regularExpression), "got: \(base)")
    }

    func test_captureFilenameBase_includeTitleOff_isTimestampOnly() {
        // Toggle off: must not leak the app/window title — with or without
        // Enhanced Security (the toggle is encryption-agnostic now).
        let base = CaptureConfig.captureFilenameBase(
            title: "Bank Statement", app: "Safari", includeTitle: false,
            format: CaptureConfig.defaultFilenameFormat, at: Self.fixedDate)
        XCTAssertNotNil(base.range(of: "^\(Self.timestampPattern)$", options: .regularExpression),
                        "expected timestamp-only, got: \(base)")
    }

    func test_captureFilenameBase_titleWithAppSuffix_isCleaned() {
        // A window title carrying a trailing " - App" suffix is cleaned, so it
        // isn't repeated after the app.
        let base = CaptureConfig.captureFilenameBase(
            title: "Stripe Dashboard - Google Chrome", app: "Google Chrome", includeTitle: true,
            format: CaptureConfig.defaultFilenameFormat, at: Self.fixedDate)
        XCTAssertNotNil(base.range(of: "^Google Chrome Stripe Dashboard \(Self.timestampPattern)$",
                                   options: .regularExpression), "got: \(base)")
    }

    func test_captureFilenameBase_titleEqualsApp_isNotRepeated() {
        let base = CaptureConfig.captureFilenameBase(
            title: "Finder", app: "Finder", includeTitle: true,
            format: CaptureConfig.defaultFilenameFormat, at: Self.fixedDate)
        XCTAssertNotNil(base.range(of: "^Finder \(Self.timestampPattern)$",
                                   options: .regularExpression), "got: \(base)")
    }
}
