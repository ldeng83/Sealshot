import Foundation

/// Describes one Live Capture window in a single sentence. Behind a protocol so
/// the assembly logic is testable without the model.
protocol SceneWindowDescribing {
    func describe(windowText: String) async -> AIGenerationOutcome
}

/// Builds a Live Capture scene's summary: one bullet per captured window,
/// frontmost first.
///
/// Each window is described on its own rather than as one aggregate prompt.
/// Scene windows are independent documents — sending them together invites the
/// model to merge or drop them, and "one bullet per window" would then depend
/// on the model obeying an instruction instead of on code. Here the list is
/// assembled from the manifest, so the structure is guaranteed and only the
/// sentence is generated.
struct SceneSummarizer {
    let describer: SceneWindowDescribing

    init(describer: SceneWindowDescribing) {
        self.describer = describer
    }

    /// nil when the scene has no windows to describe.
    func summarize(_ windows: [SceneWindowText]) async -> String? {
        let ordered = windows.sorted { $0.z < $1.z }
        guard !ordered.isEmpty else { return nil }

        var bullets: [String] = []
        for window in ordered {
            let label = SceneText.label(app: window.app, title: window.title)
            // A failed description costs the sentence, never the window.
            if case let .text(sentence) = await describer.describe(windowText: window.text) {
                let trimmed = Self.oneLine(sentence)
                bullets.append(trimmed.isEmpty ? "- \(label)" : "- \(label): \(trimmed)")
            } else {
                bullets.append("- \(label)")
            }
        }
        return bullets.joined(separator: "\n")
    }

    /// Flatten a model sentence onto a single line, collapsing runs of
    /// whitespace to one space.
    ///
    /// The prompt forbids line breaks, but assembling the list in code is
    /// exactly what keeps "one bullet per window" from depending on the model
    /// obeying instructions. An embedded newline would survive into the bullet,
    /// `SummaryLayout.parse` would read the continuation as an EXTRA bullet, and
    /// the bullet cap would then discard a real window's line.
    static func oneLine(_ sentence: String) -> String {
        sentence
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}

/// Model-backed window description. Mirrors `FoundationSummaryGenerator`'s
/// contract: never throws, and failures surface as `.skip` (terminal) or
/// `.transient` so callers can decide whether to retry. `SceneSummarizer`
/// treats both the same — the window still gets a name-only bullet.
///
/// Uses the one-sentence `windowSummary` prompt, not `summarize`: the latter
/// asks for up to three sentences and the Info-panel variant emits its own
/// bullet list, either of which would put a paragraph or a nested list inside
/// a single window's bullet.
struct FoundationSceneWindowDescriber: SceneWindowDescribing {
    func describe(windowText: String) async -> AIGenerationOutcome {
        // A window whose asset OCR'd to nothing (an image viewer, a blank
        // canvas) has nothing to describe — asking the model about an empty
        // prompt invites invention. Terminal: the bullet is name-only.
        guard !windowText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              SummaryCoherence.isSummarizable(windowText) else { return .skip }
        if #available(macOS 26, *) {
            return await FoundationTextActions().windowSummary(ocrText: windowText)
        }
        return .transient
    }
}
