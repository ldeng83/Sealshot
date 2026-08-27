import Foundation
import Observation

enum PackageFormat: Sendable { case sealshare, zip }

@Observable final class ExportPackageModel {
    private(set) var generatedPassphrase: String
    private(set) var hasCopiedGenerated = false

    var hint = ""
    var note = ""
    var includeOriginal = false
    var expiresEnabled = false
    var expiresAt: Date
    var format: PackageFormat = .sealshare
    var encryptionEnabled: Bool

    let sources: [SharePackageSource]

    init(sources: [SharePackageSource], now: Date = Date(),
         encryptionEnabled: Bool = UserDefaults.standard.bool(forKey: EncryptionSession.enabledKey)) {
        self.sources = sources
        self.expiresAt = now.addingTimeInterval(7 * 24 * 3600)
        self.generatedPassphrase = CrockfordCode.generate(groups: 4, groupSize: 5)
        self.encryptionEnabled = encryptionEnabled
    }

    func regenerate() {
        generatedPassphrase = CrockfordCode.generate(groups: 4, groupSize: 5)
        hasCopiedGenerated = false
    }

    func markGeneratedCopied() { hasCopiedGenerated = true }

    /// The passcode used for export (always the generated code in V1).
    var effectivePassphrase: String { generatedPassphrase }

    var canExport: Bool { !sources.isEmpty && (encryptionEnabled ? hasCopiedGenerated : true) }

    // MARK: - Expiry
    //
    // The picker shows a date and nothing else, but the binding is a full
    // `Date` — so the time of day used to ride along from whatever `expiresAt`
    // was seeded with (`now + 7 days`, i.e. the moment the sheet opened).
    // "Expires 20 Aug" therefore meant "20 Aug at some o'clock nobody chose",
    // and picking TODAY was expired-on-arrival or not depending on whether the
    // sheet had been opened earlier in the day than the export happened. Both
    // are resolved here rather than in the view: the picker's range is
    // presentation, and presentation is not where an invariant belongs.

    /// Earliest date the picker offers: today.
    ///
    /// Today is allowed BECAUSE expiry lands at the end of the chosen day —
    /// "expires today" means the rest of today, which is a real choice rather
    /// than an instantly-dead package. Only genuinely past dates are refused.
    nonisolated static func minimumExpiry(now: Date = Date(),
                                          calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: now)
    }

    /// The chosen day's final instant — what actually gets written into the
    /// package, so a date-only choice covers the whole of that date.
    ///
    /// Floors at `minimumExpiry` first. The range on the picker keeps a live
    /// user inside the lines, but the sheet can sit open past midnight and the
    /// macOS date field accepts typed input, so the value is re-checked at the
    /// point it is used.
    func resolvedExpiry(now: Date = Date(), calendar: Calendar = .current) -> Date? {
        guard expiresEnabled else { return nil }
        let floor = Self.minimumExpiry(now: now, calendar: calendar)
        let day = max(expiresAt, floor)
        let end = calendar.date(bySettingHour: 23, minute: 59, second: 59, of: day) ?? day
        // Exporting during the final second of a day would otherwise write an
        // expiry already behind `now`. Roll to the next day rather than ship
        // something that imports as expired — the one thing this must not do.
        guard end <= now else { return end }
        return calendar.date(byAdding: .day, value: 1, to: end) ?? end
    }

    /// Live floor for the picker's selectable range.
    var minimumSelectableExpiry: Date { Self.minimumExpiry() }

    var effectiveExpiry: Date? { resolvedExpiry() }

    var defaultFileName: String {
        sources.count == 1 ? sources[0].displayName : "Sealshot \(sources.count) items"
    }
}
