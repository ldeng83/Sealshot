import Foundation
import os.log

private let log = OSLog(subsystem: "com.seal-shot.sealshot", category: "duplicate")

/// Duplicates whole `.seal` capture packages — image plus every persisted edit.
/// A package is a directory bundle, so a recursive copy carries annotations,
/// resize, crop, background fill, and encryption over verbatim; the copy's
/// display title gets a Finder-style " copy" suffix so it reads as a distinct
/// capture rather than a same-named twin. Shared by the Library item menu, the
/// recent-strip tile menu, and the editor's empty-canvas menu.
enum CaptureDuplicator {

    /// The unique title/filename base for a copy: `"<base> copy"`, then
    /// `"<base> copy 2"`, … — the first whose `"<name>.<ext>"` is not already a
    /// filename in `existing`. `base` is sanitized to a legal filename first.
    ///
    /// Numbering continues from the STEM, so duplicating a copy gives
    /// `"Shot copy 2"` rather than `"Shot copy copy"`. Without that, the suffix
    /// grew on every round — the candidate was always free, so the counter
    /// never came into play.
    static func uniqueCopyName(base: String, existing: Set<String>, ext: String = "seal") -> String {
        let safe = copyStem(filenameSafe(base))
        func candidate(_ n: Int) -> String { n <= 1 ? "\(safe) copy" : "\(safe) copy \(n)" }
        var n = 1
        while existing.contains("\(candidate(n)).\(ext)") { n += 1 }
        return candidate(n)
    }

    /// `name` with a trailing `" copy"` or `" copy <n>"` removed, so a copy of a
    /// copy keeps counting instead of stacking suffixes. Matches Finder, which
    /// cannot tell its own suffix from a user-typed one either: a capture you
    /// named "Final copy" duplicates to "Final copy 2".
    ///
    /// The leading space is required — `Photocopy` and `copycat` are names, not
    /// suffixes. The word is matched case-insensitively (a renamed "Shot Copy"
    /// still continues numbering) but we always emit lowercase, as before.
    static func copyStem(_ name: String) -> String {
        var stem = Substring(name)
        while true {
            guard let range = stem.range(of: #"\s+copy(\s+\d+)?$"#,
                                         options: [.regularExpression, .caseInsensitive])
            else { return String(stem) }
            stem = stem[stem.startIndex..<range.lowerBound]
            // An all-suffix name ("copy", " copy 2") has no stem to keep.
            if stem.trimmingCharacters(in: .whitespaces).isEmpty { return name }
        }
    }

    /// Replace the characters that can't appear in a macOS filename (`/` and `:`)
    /// so a display title can seed a filename; falls back to "Capture" when
    /// nothing usable remains.
    static func filenameSafe(_ raw: String) -> String {
        let cleaned = raw.replacingOccurrences(of: "/", with: "-")
                         .replacingOccurrences(of: ":", with: "-")
                         .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Capture" : cleaned
    }

    /// Duplicate each `.seal` package in `urls` into its own folder. Returns the
    /// new URLs (packages that fail to copy are skipped). `baseName` supplies the
    /// source's display name for the " copy" title. Callers refresh the Library /
    /// strip afterward (the copy lands in the save folder).
    @MainActor
    @discardableResult
    static func duplicate(_ urls: [URL], baseName: (URL) -> String) -> [URL] {
        let fm = FileManager.default
        var created: [URL] = []
        for src in urls where src.pathExtension == "seal" {
            guard fm.fileExists(atPath: src.path) else { continue }
            let folder = src.deletingLastPathComponent()
            let existing = Set((try? fm.contentsOfDirectory(atPath: folder.path)) ?? [])
            let name = uniqueCopyName(base: baseName(src), existing: existing)
            let dest = folder.appendingPathComponent("\(name).seal", isDirectory: true)
            do {
                try fm.copyItem(at: src, to: dest)
                // The copy's display title becomes the " copy" name (encryption-
                // aware). Best-effort: a locked session leaves the copy untitled,
                // which still shows the "… copy" filename.
                try? SealMetadataStore.update(at: dest, createIfMissing: true) { $0.userTitle = name }
                created.append(dest)
            } catch {
                os_log("duplicate copy failed %{public}@: %{public}@",
                       log: log, type: .error, src.lastPathComponent, String(describing: error))
            }
        }
        return created
    }
}
