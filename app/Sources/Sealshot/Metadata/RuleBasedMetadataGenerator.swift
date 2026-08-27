import Foundation
import CoreGraphics

/// Pure, deterministic metadata generation from on-device signals. No I/O,
/// no clock reads (date is passed in), no randomness — fully unit-testable.
struct RuleBasedMetadataGenerator {

    static let version = 2

    func generate(_ s: MetadataSignals) -> CaptureMetadata {
        let category = classify(s)
        let titled = makeTitle(s)
        return CaptureMetadata(
            generatedTitle: titled.title,
            userTitle: nil,
            tags: [],
            smartKeywords: makeTags(s),
            category: category,
            confidence: titled.confidence,
            generatorVersion: Self.version
        )
    }

    // MARK: Category

    /// Keyword classification, most-specific first; first match wins.
    private func classify(_ s: MetadataSignals) -> ScreenshotCategory {
        let hay = (s.ocrText + " " + (s.windowTitle ?? "") + " " + (s.sourceApp ?? "")).lowercased()
        func has(_ words: [String]) -> Bool { words.contains { hay.contains($0) } }

        if has(["error", "exception", "forbidden", "failed", "denied", "traceback", "stack trace"]) { return .error }
        if has(["subtotal", "total due", "invoice", "receipt", "amount paid", "order #"]) { return .receipt }
        if has(["pull request", "commit", "github", "func ", "def ", "import ", "console.log"]) { return .code }
        if has(["figma", "sketch", "artboard", "prototype"]) { return .design }
        if has(["dashboard", "revenue", "metrics", "analytics", "kpi"]) { return .dashboard }
        if has(["settings", "preferences", "configuration"]) { return .settings }
        if has(["slack", "message", "reply", "dm "]) { return .chat }
        if has(["pdf", "document", "page ", "chapter"]) { return .document }
        return .other
    }

    // MARK: Title

    /// Title plus a confidence keyed to *which* signal produced it, so the
    /// display layer can gate weak guesses behind a neutral fallback. A clean
    /// window title is trustworthy; an OCR line is a guess; the app-name and
    /// no-signal cases are placeholders.
    private func makeTitle(_ s: MetadataSignals) -> (title: String, confidence: Double) {
        if let t = cleanWindowTitle(s.windowTitle) { return (titleCased(t), 0.85) }
        if let ocr = layoutTitle(s.ocrLines) { return ocr }
        if let line = salientOCRLine(s.ocrText) { return (titleCased(line), 0.55) }
        if let app = s.sourceApp, !app.isEmpty { return ("\(titleCased(app)) Screenshot", 0.40) }
        return ("Screenshot", 0.20)
    }

    /// Layout-aware OCR title: pick the tallest title-like line (text size as a
    /// prominence proxy). Promote to high confidence (0.78, displayed) only when
    /// it clearly dominates — ≥ 1.4× the median height of the other lines AND in
    /// the top 40% of the image; otherwise medium (0.55, App·date fallback).
    /// Returns nil when there are no lines or none are title-like, so callers
    /// fall back to the text-only path.
    private func layoutTitle(_ lines: [OCRLine]) -> (title: String, confidence: Double)? {
        var bestIdx: Int?
        for (i, l) in lines.enumerated() where isTitleLike(l.text) {
            if bestIdx == nil || l.box.height > lines[bestIdx!].box.height { bestIdx = i }
        }
        guard let idx = bestIdx else { return nil }
        let candidate = lines[idx]
        let title = titleCased(candidate.text.trimmingCharacters(in: .whitespaces))

        let otherHeights = lines.indices.filter { $0 != idx }.map { lines[$0].box.height }
        let dominant: Bool
        if let med = median(otherHeights), med > 0 {
            dominant = candidate.box.height >= 1.4 * med && candidate.box.midY <= 0.40
        } else {
            dominant = false   // single line / no body to compare against
        }
        return (title, dominant ? 0.78 : 0.55)
    }

    private func median(_ xs: [CGFloat]) -> CGFloat? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        let n = s.count
        return n.isMultiple(of: 2) ? (s[n / 2 - 1] + s[n / 2]) / 2 : s[n / 2]
    }

    /// Has letters and ≤ 8 words after trimming — the bar for a usable title.
    private func isTitleLike(_ text: String) -> Bool {
        let line = text.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty,
              line.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) else {
            return false
        }
        return line.split(separator: " ").count <= 8
    }

    /// Shared suffix-strip + whitespace-collapse (`CaptureSubject.clean`), plus
    /// the title-display nicety of normalising remaining " - " to an en dash.
    private func cleanWindowTitle(_ raw: String?) -> String? {
        CaptureSubject.clean(raw).map { $0.replacingOccurrences(of: " - ", with: " \u{2013} ") }
    }

    /// First title-like OCR line in reading order. Text-only fallback for when
    /// no per-line geometry is available (see `layoutTitle`).
    private func salientOCRLine(_ ocr: String) -> String? {
        for raw in ocr.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if isTitleLike(line) { return line }
        }
        return nil
    }

    private func titleCased(_ s: String) -> String {
        s.split(separator: " ").map { w -> String in
            guard let first = w.first else { return String(w) }
            // Preserve all-caps tokens (e.g. "SAML", "403").
            if w.count > 1 && w.allSatisfy({ $0.isUppercase || $0.isNumber }) { return String(w) }
            return first.uppercased() + w.dropFirst().lowercased()
        }.joined(separator: " ")
    }

    // MARK: Tags

    /// Curated content keywords to surface as tags when present in OCR text.
    private static let keywordTags = [
        "stripe", "github", "pull-request", "aws", "figma", "docker",
        "kubernetes", "403", "404", "500", "payment", "checkout", "invoice",
        "slack", "jira", "terminal", "sql"
    ]

    private func makeTags(_ s: MetadataSignals) -> [String] {
        var raw: [String] = []
        // 1. app slug
        if let app = s.sourceApp, !app.isEmpty { raw.append(app) }
        // 2. content keyword hits
        let hay = (s.ocrText + " " + (s.windowTitle ?? "")).lowercased()
        for kw in Self.keywordTags where hay.contains(kw.replacingOccurrences(of: "-", with: " ")) || hay.contains(kw) {
            raw.append(kw)
        }
        return TagNormalizer.normalize(raw)
    }
}
