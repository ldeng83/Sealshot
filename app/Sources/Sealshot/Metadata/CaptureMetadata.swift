import Foundation

/// Screenshot kind, inferred by the rule-based generator. Trimmed to
/// categories that keyword rules can actually separate.
enum ScreenshotCategory: String, Codable, CaseIterable, Equatable {
    case error, code, design, document, dashboard, chat, settings, receipt, other
}

/// Auto-generated, user-editable metadata for one capture. Stored inside the
/// `.seal` package's `manifest.json`. `generatedTitle` is the rules/AI value;
/// `userTitle` is a manual override and is never clobbered by regeneration.
struct CaptureMetadata: Codable, Equatable {
    let generatedTitle: String
    var userTitle: String?
    var tags: [String]
    /// Auto-generated, READ-ONLY keywords (rule/FM/Vision/video taggers). Separate
    /// from user `tags`: generators write only this; users edit only `tags`.
    /// Pre-split manifests (no `smartKeywords` key) migrate their old `tags` here.
    var smartKeywords: [String]
    let category: ScreenshotCategory
    let confidence: Double
    let generatorVersion: Int
    /// Bumped when this capture has been visually tagged (see `VisionTagger.version`).
    /// `0` = never visually tagged. Defaulted on decode so pre-feature manifests load.
    var visualTagVersion: Int
    /// AI-generated 1–3 sentence summary of the capture; `nil` = not generated.
    /// Produced by `MetadataCoordinator` (eagerly at capture, and backfilled when
    /// an image is opened) from the OCR text. Defaulted on decode so pre-feature
    /// manifests load.
    var summary: String?
    /// Bumped when this capture's summary was generated. `0` = never summarized.
    var summaryVersion: Int
    /// Manual summary override (v13) — edited in place in the Info panel and
    /// never clobbered by regeneration. Three states:
    /// - `nil`  = no override → show the generated `summary`, regeneration allowed.
    /// - `""`   = explicitly suppressed → show blank, regeneration OFF (the user
    ///            deleted the summary on purpose; "Revert to Generated Summary"
    ///            brings it back by resetting this to nil).
    /// - other  = the override text → show it, regeneration OFF.
    var userSummary: String?

    init(generatedTitle: String, userTitle: String?, tags: [String],
         smartKeywords: [String] = [],
         category: ScreenshotCategory, confidence: Double, generatorVersion: Int,
         visualTagVersion: Int = 0, summary: String? = nil, summaryVersion: Int = 0,
         userSummary: String? = nil) {
        self.generatedTitle = generatedTitle
        self.userTitle = userTitle
        self.tags = tags
        self.smartKeywords = smartKeywords
        self.category = category
        self.confidence = confidence
        self.generatorVersion = generatorVersion
        self.visualTagVersion = visualTagVersion
        self.summary = summary
        self.summaryVersion = summaryVersion
        self.userSummary = userSummary
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        generatedTitle = try c.decode(String.self, forKey: .generatedTitle)
        userTitle = try c.decodeIfPresent(String.self, forKey: .userTitle)
        let decodedTags = try c.decode([String].self, forKey: .tags)
        if let sk = try c.decodeIfPresent([String].self, forKey: .smartKeywords) {
            // v11+: both fields stored independently.
            smartKeywords = sk
            tags = decodedTags
        } else {
            // Pre-split manifest: old `tags` were mostly auto-generated → Smart
            // Keywords; the user Tags section starts empty.
            smartKeywords = decodedTags
            tags = []
        }
        category = try c.decode(ScreenshotCategory.self, forKey: .category)
        confidence = try c.decode(Double.self, forKey: .confidence)
        generatorVersion = try c.decode(Int.self, forKey: .generatorVersion)
        visualTagVersion = try c.decodeIfPresent(Int.self, forKey: .visualTagVersion) ?? 0
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        summaryVersion = try c.decodeIfPresent(Int.self, forKey: .summaryVersion) ?? 0
        userSummary = try c.decodeIfPresent(String.self, forKey: .userSummary)
    }

    /// The summary to display: the user's override whenever one is present
    /// (an empty override = deliberately blank), else the generated one (which
    /// may itself be nil / the "" terminal marker). Only `nil` falls through
    /// to `summary`, so a suppressed summary stays blank.
    var effectiveSummary: String? {
        if let u = userSummary { return u.trimmingCharacters(in: .whitespacesAndNewlines) }
        return summary
    }

    /// Whether the user has taken control of the summary — an override text OR
    /// a deliberate suppression. Drives the regeneration/progress gates so a
    /// suppressed summary is never regenerated and repopulated.
    var hasUserSummaryOverride: Bool { userSummary != nil }

    /// Neutral shell for a package whose generators never ran (on-device AI
    /// disabled, or edits made before generation finishes). Lets user edits
    /// (tags, rename) persist without faking generator output: empty
    /// `smartKeywords` + `generatorVersion` 0 keep the capture eligible for a
    /// later AI backfill, and the empty `generatedTitle` never wins over the
    /// filename fallback in `displayTitle`.
    static func userEditableShell() -> CaptureMetadata {
        CaptureMetadata(generatedTitle: "", userTitle: nil, tags: [],
                        category: .other, confidence: 0, generatorVersion: 0)
    }

    /// `userTitle ?? generatedTitle ?? fallback`, treating empty strings as absent.
    func displayTitle(fallback: String) -> String {
        if let u = userTitle, !u.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return u }
        if !generatedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return generatedTitle }
        return fallback
    }
}
