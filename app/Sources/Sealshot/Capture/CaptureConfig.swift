import Foundation
import Observation
import AppKit

extension Notification.Name {
    /// Posted (main thread) when the capture save folder changes; object is the
    /// new folder `URL`. The old folder's files are left untouched on disk.
    static let saveFolderDidChange = Notification.Name("saveFolderDidChange")
}

enum CaptureOutput: String, CaseIterable, Codable {
    case clipboard
    case file
    case both
}

/// App-wide appearance preference. `.system` follows the macOS Light/Dark
/// setting; `.light`/`.dark` force that appearance regardless of the system.
enum AppearancePreference: String, CaseIterable, Codable {
    case system, light, dark

    /// The NSAppearance to install on the app (nil = follow the system).
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

@MainActor
@Observable
final class CaptureConfig {
    private enum Keys {
        static let defaultOutput = "captureConfig.defaultOutput"
        static let saveFolder = "captureConfig.saveFolder"
        static let filenameFormat = "captureConfig.filenameFormat"
        static let retentionDays = "captureConfig.retentionDays"
        static let appearance = "captureConfig.appearance"
    }

    static let defaultSaveFolder: URL = {
        let pictures = FileManager.default
            .urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures")
        return pictures.appendingPathComponent("Sealshot", isDirectory: true)
    }()

    /// Date portion only — the capture subject (window title or app) is
    /// prepended by `composeBase`. 12-hour time with AM/PM and milliseconds;
    /// underscores in the time keep names safe to upload to platforms that choke
    /// on dots/colons. Milliseconds (`SSS`) keep two captures taken within the
    /// same second from colliding (the old second-precision name forced a " 2"
    /// suffix and ambiguous ordering).
    nonisolated static let defaultFilenameFormat = "yyyy-MM-dd 'at' h_mm_ss_SSS a"
    /// The pre-subject default ("Sealshot …" with dots), still matched by the
    /// `'Sealshot'` substring check below.
    nonisolated static let legacyDefaultFilenameFormat = "'Sealshot' yyyy-MM-dd 'at' HH.mm.ss"
    /// Earlier built-in defaults to upgrade in place to `defaultFilenameFormat`.
    private nonisolated static let priorDefaultFilenameFormats = [
        "'Sealshot' yyyy-MM-dd 'at' HH.mm.ss",   // dotted, "Sealshot"-prefixed
        "yyyy-MM-dd 'at' HH_mm_ss",              // 24-hour underscore default
        "yyyy-MM-dd 'at' h_mm_ss a",             // pre-milliseconds 12-hour default
    ]

    /// Map a stored format to the one to use: nil or any prior built-in default
    /// → the current default; genuinely custom values are kept as-is.
    nonisolated static func migratedFilenameFormat(stored: String?) -> String {
        guard let stored else { return defaultFilenameFormat }
        if priorDefaultFilenameFormats.contains(stored) || stored.contains("'Sealshot'") {
            return defaultFilenameFormat
        }
        return stored
    }
    static let defaultRetentionDays = 7

    var defaultOutput: CaptureOutput {
        didSet { UserDefaults.standard.set(defaultOutput.rawValue, forKey: Keys.defaultOutput) }
    }

    /// Where captures and recordings are written. Changing it re-points the app
    /// at the new location — existing captures are NOT moved and stay where
    /// they are. Everything showing the old folder's contents (editor canvas,
    /// recent strip, Library) listens for `saveFolderDidChange`; without that
    /// they keep displaying files the app no longer considers its library.
    var saveFolder: URL {
        didSet {
            // Compare PATHS, not URLs: a folder read back from UserDefaults
            // carries a trailing slash the picker's URL doesn't, so plain URL
            // equality reports a change when the folder is really the same.
            guard saveFolder.path != oldValue.path else { return }
            UserDefaults.standard.set(saveFolder, forKey: Keys.saveFolder)
            NotificationCenter.default.post(name: .saveFolderDidChange, object: saveFolder)
        }
    }

    var filenameFormat: String {
        didSet { UserDefaults.standard.set(filenameFormat, forKey: Keys.filenameFormat) }
    }

    /// The allowed retention window; writes outside it are clamped to the
    /// nearest bound (settings field, Stepper, and any programmatic writer).
    nonisolated static let retentionDaysRange = 1...365

    nonisolated static func clampedRetention(_ days: Int) -> Int {
        min(max(days, retentionDaysRange.lowerBound), retentionDaysRange.upperBound)
    }

    /// Days a capture stays in the Deleted/ folder before auto-purge. Clamped
    /// to `retentionDaysRange`.
    var retentionDays: Int {
        didSet {
            // Reassigning below re-triggers didSet with the valid value, which persists.
            guard Self.retentionDaysRange.contains(retentionDays) else {
                retentionDays = Self.clampedRetention(retentionDays)
                return
            }
            UserDefaults.standard.set(retentionDays, forKey: Keys.retentionDays)
        }
    }

    /// Light/Dark/System theme. Persists and applies app-wide immediately.
    var appearancePreference: AppearancePreference {
        didSet {
            UserDefaults.standard.set(appearancePreference.rawValue, forKey: Keys.appearance)
            applyAppearance()
        }
    }

    init() {
        let defaults = UserDefaults.standard

        let outputRaw = defaults.string(forKey: Keys.defaultOutput) ?? CaptureOutput.both.rawValue
        self.defaultOutput = CaptureOutput(rawValue: outputRaw) ?? .both

        self.saveFolder = defaults.url(forKey: Keys.saveFolder) ?? Self.defaultSaveFolder

        // Upgrade the stale legacy default in place; persist if it changed.
        let storedFormat = defaults.string(forKey: Keys.filenameFormat)
        let migratedFormat = Self.migratedFilenameFormat(stored: storedFormat)
        self.filenameFormat = migratedFormat
        if migratedFormat != storedFormat {
            defaults.set(migratedFormat, forKey: Keys.filenameFormat)
        }

        let storedRetention = defaults.object(forKey: Keys.retentionDays) as? Int
        self.retentionDays = Self.clampedRetention(storedRetention ?? Self.defaultRetentionDays)

        let appearanceRaw = defaults.string(forKey: Keys.appearance) ?? AppearancePreference.system.rawValue
        self.appearancePreference = AppearancePreference(rawValue: appearanceRaw) ?? .system

        // Apply the stored preference at launch (CaptureConfig is created in
        // applicationWillFinishLaunching, before any window appears).
        applyAppearance()
    }

    /// Install the current preference's appearance on the application. nil
    /// appearance lets the app follow the macOS Light/Dark setting.
    func applyAppearance() {
        NSApplication.shared.appearance = appearancePreference.nsAppearance
    }

    /// The General-tab fields this config owns (theme, save location — it
    /// directs both captures and recordings — and trash retention).
    func resetGeneralDefaults() {
        appearancePreference = .system
        saveFolder = Self.defaultSaveFolder
        retentionDays = Self.defaultRetentionDays
    }

    /// The Capture-tab fields this config owns (destination, filename).
    func resetCaptureDefaults() {
        defaultOutput = .both
        filenameFormat = Self.defaultFilenameFormat
    }

    /// Both scopes (see SettingsReset for the full per-tab reset story —
    /// keyboard shortcuts reset via their own store, not here).
    func resetToDefaults() {
        resetGeneralDefaults()
        resetCaptureDefaults()
    }

    func renderFilename(extension ext: String = "png", subject: String? = nil,
                        at date: Date = .init()) -> String {
        "\(Self.composeBase(subject: subject, format: filenameFormat, at: date)).\(ext)"
    }

    /// The subject to embed in a capture filename under the privacy policy:
    /// while encryption is enabled, captures are named by timestamp only, so the
    /// on-disk filename never leaks the app/window title (the title is still
    /// kept inside the encrypted manifest and shown as the display name). When
    /// encryption is off, the subject is used as before (app-first naming).
    nonisolated static func filenameSubject(_ subject: String?, encryptionEnabled: Bool) -> String? {
        encryptionEnabled ? nil : subject
    }

    /// The subject to embed in an IMPORTED file's name. Imports keep their
    /// original filename (Format A: "<name> <timestamp>") when encryption is
    /// off, or on with the "include title & app in filename" opt-in enabled —
    /// otherwise timestamp-only, matching the capture privacy policy
    /// (`captureFilenameBase`). Pure for testing.
    nonisolated static func importFilenameSubject(_ subject: String,
                                                  includeTitle: Bool) -> String? {
        includeTitle ? subject : nil
    }

    /// "<sanitized subject> <date>" (or just "<date>" with no subject). Pure —
    /// the date format and timezone are explicit so it's deterministic to test.
    nonisolated static func composeBase(subject: String?, format: String, at date: Date,
                                        timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        let datePart = formatter.string(from: date)
        guard let s = subject, !s.isEmpty else { return datePart }
        return "\(FriendlyFilename.sanitize(s)) \(datePart)"
    }

    /// "<app> <title> <timestamp>" — the unified capture name (app first, then
    /// the cleaned window/AI title). The title is run through
    /// `CaptureSubject.clean` (strips a trailing " - App" suffix, collapses
    /// whitespace) and dropped when empty or identical to the app; app and title
    /// are sanitized for the filesystem; the head is capped so a long title
    /// can't produce an absurd name. Collapses to date-only when both are empty.
    /// Pure for deterministic testing.
    nonisolated static func composeTitleAppBase(title: String?, app: String?, format: String,
                                                at date: Date, timeZone: TimeZone = .current,
                                                maxLength: Int = 50) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        let datePart = formatter.string(from: date)

        func sanitizedNonEmpty(_ raw: String?) -> String? {
            guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            let s = FriendlyFilename.sanitize(raw)
            return s.isEmpty ? nil : s
        }
        let appPart = sanitizedNonEmpty(app)
        var titlePart = sanitizedNonEmpty(CaptureSubject.clean(title))
        // Drop a title that's just the app name again (some apps title their
        // windows with their own name).
        if let t = titlePart, let a = appPart, t.caseInsensitiveCompare(a) == .orderedSame {
            titlePart = nil
        }
        let head = [appPart, titlePart].compactMap { $0 }.joined(separator: " ")
        let capped = head.count > maxLength
            ? String(head.prefix(maxLength)).trimmingCharacters(in: .whitespaces) : head
        return capped.isEmpty ? datePart : "\(capped) \(datePart)"
    }

    /// The on-disk base name for a fresh capture, applying the privacy policy:
    /// - encryption off → "<app> <title> <date>";
    /// - encryption on, "include title & app" off → timestamp only (no leak);
    /// - encryption on, "include title & app" on (user opt-in) → "<app> <title> <date>".
    /// Composed synchronously at capture time so the file is named correctly
    /// before it opens in an editor — no after-the-fact rename. Pure for testing.
    nonisolated static func captureFilenameBase(title: String?, app: String?,
                                                includeTitle: Bool,
                                                format: String, at date: Date,
                                                timeZone: TimeZone = .current) -> String {
        // "<app> <title> <date>" when the include-title toggle is on; a bare
        // timestamp otherwise — encryption-agnostic (the toggle carries the
        // privacy policy; enabling Enhanced Security defaults it off).
        if includeTitle {
            return composeTitleAppBase(title: title, app: app, format: format, at: date, timeZone: timeZone)
        }
        return composeBase(subject: nil, format: format, at: date, timeZone: timeZone)
    }

    /// Target filename when the user renames via the title — exactly the
    /// sanitized title (no timestamp), de-collided. Returns nil when it already
    /// equals `currentName`, so repeated commits of the same title are a no-op
    /// (and a display name that already contains a timestamp isn't re-stamped).
    /// Default stem when a rename input has no usable content.
    nonisolated static let defaultRenameStem = "screenshot"

    nonisolated static func renameTargetName(currentName: String, title: String,
                                             ext: String, exists: (String) -> Bool) -> String? {
        // "No valid string" = the entered title has no real letters or digits
        // (empty, whitespace, emoji, or only punctuation/dashes/dots like "...",
        // "///", "•••"). Such inputs would make a bare ".seal" or an ugly/hidden
        // filename, so fall back to a sensible default. Judge from the RAW title
        // — `sanitize` bakes in its own capitalized "Screenshot" fallback, which
        // we deliberately bypass so every no-content case yields the SAME
        // lowercase default (not a mix of "Screenshot"/"screenshot").
        //
        // Test scalar properties, NOT CharacterSet.alphanumerics: that set spans
        // Unicode categories L*, M*, and N*, so the invisible variation selector
        // U+FE0F (category Mn) inside an emoji like "✳️" counted as content —
        // sanitize then stripped the visible glyph and left the selector alone,
        // yielding "️.seal" (a bare-looking ".seal"). `isAlphabetic` excludes
        // variation selectors and combining marks while still accepting CJK and
        // other non-Latin letters.
        let hasContent = title.unicodeScalars.contains {
            $0.properties.isAlphabetic || CharacterSet.decimalDigits.contains($0)
        }
        let base = hasContent ? FriendlyFilename.sanitize(title) : Self.defaultRenameStem
        if "\(base).\(ext)" == currentName { return nil }
        return uniqueName(base: base, ext: ext, exists: exists)
    }

    /// First non-colliding "<base>.<ext>", bumping to "<base> 2", "<base> 3", …
    /// `exists` reports whether a candidate filename is already taken.
    nonisolated static func uniqueName(base: String, ext: String, exists: (String) -> Bool) -> String {
        let first = "\(base).\(ext)"
        guard exists(first) else { return first }
        var n = 2
        while exists("\(base) \(n).\(ext)") { n += 1 }
        return "\(base) \(n).\(ext)"
    }
}
