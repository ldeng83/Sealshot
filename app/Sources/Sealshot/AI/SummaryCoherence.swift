import Foundation

/// Decides whether a screenshot's OCR text is coherent enough to summarize.
/// Dense "label soup" screenshots (maps, dashboards, busy UIs) are mostly tiny
/// disconnected fragments — the on-device model can't synthesize them and tends
/// to echo the fragments as a long list, so we skip summarizing them entirely.
enum SummaryCoherence {

    /// Minimum line count before the "label soup" heuristic applies. Short texts
    /// (notes, error dialogs) are always allowed.
    static let minLines = 20
    /// Below this average words-per-line, a many-line text is treated as soup.
    /// Lowered from 2.5 so dense label:value documents (forms, medical records,
    /// receipts) at ~1.5–2.5 words/line get summarized; only near-single-word
    /// soup (maps/place lists at ~1.4 and below) is still suppressed.
    static let minAverageWordsPerLine = 1.5

    static func isSummarizable(_ ocrText: String) -> Bool {
        let lines = ocrText
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count >= minLines else { return true }
        let words = lines.reduce(0) { $0 + $1.split(separator: " ").count }
        let average = Double(words) / Double(lines.count)
        return average >= minAverageWordsPerLine
    }
}
