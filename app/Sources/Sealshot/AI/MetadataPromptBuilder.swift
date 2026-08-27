import Foundation

/// Pure, deterministic construction of the instructions + prompt fed to the
/// on-device Foundation Model for capture metadata. No model dependency, so
/// fully unit-testable on any OS (the build machine can't run the model).
enum MetadataPromptBuilder {
    /// System instructions: keep the model tightly scoped to labeling, since the
    /// small on-device model does best on focused classification/extraction.
    static let instructions = """
    You label screenshots for a personal screenshot library. Given the screen \
    text (OCR) and optional app and window-title context, produce a concise \
    title, a single best category, and a few lowercase tags. Base everything \
    only on the provided text — never invent details that aren't present.
    """

    /// Trim OCR text to a character budget (model context is small), preferring
    /// to cut at a line boundary so we don't slice mid-line.
    static func ocrExcerpt(_ text: String, maxChars: Int) -> String {
        guard text.count > maxChars else { return text }
        let end = text.index(text.startIndex, offsetBy: maxChars)
        let head = text[text.startIndex..<end]
        if let lastNewline = head.lastIndex(of: "\n") {
            return String(text[text.startIndex..<lastNewline])
        }
        return String(head)
    }

    /// Assemble the user prompt from capture signals, excerpting OCR text.
    /// Missing app/window fields are omitted entirely (no placeholder noise).
    static func userPrompt(from signals: MetadataSignals, maxOCRChars: Int) -> String {
        var parts: [String] = []
        if let app = signals.sourceApp, !app.isEmpty { parts.append("App: \(app)") }
        if let window = signals.windowTitle, !window.isEmpty { parts.append("Window title: \(window)") }
        parts.append("Screen text (OCR):\n\(ocrExcerpt(signals.ocrText, maxChars: maxOCRChars))")
        return parts.joined(separator: "\n")
    }
}
