import XCTest
@testable import Sealshot

final class ExportPackageModelTests: XCTestCase {
    private func src(_ name: String) -> SharePackageSource {
        SharePackageSource(url: URL(fileURLWithPath: "/tmp/\(name).seal"), displayName: name, isVideo: false)
    }

    func testGeneratedModeRequiresCopy() {
        let m = ExportPackageModel(sources: [src("a")], encryptionEnabled: true)
        XCTAssertFalse(m.canExport)              // not copied yet
        m.markGeneratedCopied()
        XCTAssertTrue(m.canExport)
    }

    func testEmptySourcesBlocksExport() {
        let m = ExportPackageModel(sources: [])
        m.markGeneratedCopied()
        XCTAssertFalse(m.canExport)
    }

    func testRegenerateResetsCopyGate() {
        let m = ExportPackageModel(sources: [src("a")], encryptionEnabled: true)
        let first = m.generatedPassphrase
        m.markGeneratedCopied()
        XCTAssertTrue(m.canExport)
        m.regenerate()
        XCTAssertNotEqual(m.generatedPassphrase, first)
        XCTAssertFalse(m.hasCopiedGenerated)
        XCTAssertFalse(m.canExport)              // must re-copy
    }

    func testEffectivePassphraseIsGeneratedCode() {
        let m = ExportPackageModel(sources: [src("a")])
        XCTAssertEqual(m.effectivePassphrase, m.generatedPassphrase)
    }

    func testGeneratedPassphraseIsWellFormed() {
        let m = ExportPackageModel(sources: [src("a")])
        XCTAssertEqual(m.generatedPassphrase.split(separator: "-").count, 4)
        XCTAssertGreaterThanOrEqual(
            m.generatedPassphrase.replacingOccurrences(of: "-", with: "").count, 8)
    }

    func testDefaultFileName() {
        XCTAssertEqual(ExportPackageModel(sources: [src("shot")]).defaultFileName, "shot")
        XCTAssertEqual(ExportPackageModel(sources: [src("a"), src("b")]).defaultFileName, "Sealshot 2 items")
    }

    /// The toggle gates the expiry. It no longer passes `expiresAt` through
    /// untouched — see the expiry tests below: the exported instant is the end
    /// of the chosen day, floored at tomorrow, so a date-only choice can't ship
    /// as already-expired. This uses a real clock, so it asserts the contract
    /// rather than an exact date.
    func testEffectiveExpiry() {
        let now = Date()
        let m = ExportPackageModel(sources: [src("a")], now: now)
        XCTAssertNil(m.effectiveExpiry)
        m.expiresEnabled = true
        let expiry = m.effectiveExpiry
        XCTAssertNotNil(expiry)
        XCTAssertGreaterThan(expiry!, now)
    }

    func testFormatDefaultsToSealshare() {
        XCTAssertEqual(ExportPackageModel(sources: [src("a")], encryptionEnabled: true).format, .sealshare)
    }
    func testEncryptionEnabledIsInjectable() {
        XCTAssertTrue(ExportPackageModel(sources: [src("a")], encryptionEnabled: true).encryptionEnabled)
        XCTAssertFalse(ExportPackageModel(sources: [src("a")], encryptionEnabled: false).encryptionEnabled)
    }
    func testCanExportPlaintextNeedsNoCopy() {
        let m = ExportPackageModel(sources: [src("a")], encryptionEnabled: false)
        XCTAssertTrue(m.canExport)                      // no passcode gate when not encrypting
    }
    func testCanExportEncryptedStillNeedsCopy() {
        let m = ExportPackageModel(sources: [src("a")], encryptionEnabled: true)
        XCTAssertFalse(m.canExport)
        m.markGeneratedCopied()
        XCTAssertTrue(m.canExport)
    }
    func testEmptySourcesNeverExport() {
        XCTAssertFalse(ExportPackageModel(sources: [], encryptionEnabled: false).canExport)
    }

    // MARK: - Expiry

    /// A fixed clock so "tomorrow" and "end of day" are assertable. Deliberately
    /// mid-afternoon: the old behaviour carried the sheet's opening time along
    /// with the chosen date, so an afternoon time is what exposed it.
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }
    private func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    func test_minimumExpiry_isToday() {
        // Today is selectable BECAUSE expiry lands at the end of the day, so
        // "expires today" means the rest of today — a real choice. Only dates
        // genuinely in the past are refused.
        let now = at(2026, 8, 11, 15, 30)
        let min = ExportPackageModel.minimumExpiry(now: now, calendar: calendar)
        XCTAssertEqual(min, at(2026, 8, 11, 0, 0))
    }

    func test_minimumExpiry_justBeforeMidnight_isStillToday() {
        let now = at(2026, 8, 11, 23, 59)
        XCTAssertEqual(ExportPackageModel.minimumExpiry(now: now, calendar: calendar),
                       at(2026, 8, 11, 0, 0))
    }

    func test_effectiveExpiry_lapsesAtTheEndOfTheChosenDay() {
        // The picker shows only a date, so "expires 20 Aug" has to mean the whole
        // of the 20th. It used to mean 20 Aug at whatever time the sheet opened.
        let now = at(2026, 8, 11, 15, 30)
        let m = ExportPackageModel(sources: [src("a")], now: now)
        m.expiresEnabled = true
        m.expiresAt = at(2026, 8, 20, 9, 15)     // 09:15 — an arbitrary carried-over time

        let expiry = try? XCTUnwrap(m.resolvedExpiry(now: now, calendar: calendar))
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: expiry!),
                       DateComponents(year: 2026, month: 8, day: 20))
        // Last representable instant of that day, not the small hours of it.
        XCTAssertEqual(expiry, calendar.date(bySettingHour: 23, minute: 59, second: 59,
                                             of: at(2026, 8, 20, 12, 0))!)
    }

    func test_effectiveExpiry_isNilWhenDisabled() {
        let now = at(2026, 8, 11, 15, 30)
        let m = ExportPackageModel(sources: [src("a")], now: now)
        m.expiresAt = at(2026, 8, 20, 9, 15)
        XCTAssertNil(m.resolvedExpiry(now: now, calendar: calendar),
                     "no expiry unless the toggle is on")
    }

    func test_effectiveExpiry_neverExportsAnAlreadyExpiredDate() {
        // Belt and braces for the picker's range: the sheet can sit open past
        // midnight, and the macOS date field accepts typing.
        let now = at(2026, 8, 11, 15, 30)
        let m = ExportPackageModel(sources: [src("a")], now: now)
        m.expiresEnabled = true
        m.expiresAt = at(2026, 6, 1, 9, 0)       // long past

        let expiry = try? XCTUnwrap(m.resolvedExpiry(now: now, calendar: calendar))
        XCTAssertGreaterThan(expiry!, now,
                             "an expiry in the past would import as expired immediately")
    }

    func test_effectiveExpiry_allowsToday_lastingUntilTheEndOfIt() {
        let now = at(2026, 8, 11, 15, 30)
        let m = ExportPackageModel(sources: [src("a")], now: now)
        m.expiresEnabled = true
        m.expiresAt = at(2026, 8, 11, 16, 0)     // today

        let expiry = try? XCTUnwrap(m.resolvedExpiry(now: now, calendar: calendar))
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: expiry!),
                       DateComponents(year: 2026, month: 8, day: 11),
                       "today is a valid choice — it means the rest of today")
        XCTAssertGreaterThan(expiry!, now)
    }

    func test_effectiveExpiry_inTheFinalSecondOfTheDay_rollsForward() {
        // The one case where "end of today" is already behind us. Shipping it
        // would import as expired, which is the single outcome this must never
        // produce.
        let now = calendar.date(bySettingHour: 23, minute: 59, second: 59,
                                of: at(2026, 8, 11, 12, 0))!
        let m = ExportPackageModel(sources: [src("a")], now: now)
        m.expiresEnabled = true
        m.expiresAt = at(2026, 8, 11, 9, 0)      // today

        let expiry = try? XCTUnwrap(m.resolvedExpiry(now: now, calendar: calendar))
        XCTAssertGreaterThan(expiry!, now)
    }

    func test_defaultExpiry_sitsAboveTheMinimum() {
        let now = at(2026, 8, 11, 15, 30)
        let m = ExportPackageModel(sources: [src("a")], now: now)
        XCTAssertGreaterThan(m.expiresAt,
                             ExportPackageModel.minimumExpiry(now: now, calendar: calendar),
                             "the default must be selectable in the picker it opens")
    }
}
