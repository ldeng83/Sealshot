import Foundation
import RedactionEngineInterface

/// Entity tier: runs the shipped GLiNER2 redaction engine with
/// structured-extraction labels over a geometry-ordered OCR transcript, mapping
/// detections into `StructuredItems`.
///
/// **Threading**: `extract(transcript:modelPath:)` is nonisolated and designed
/// to run in a background context — `RedactionEngineLoader().engine(...)` blocks
/// ~1s on first load. The caller must resolve `modelPath` on the main actor from
/// `RedactionModelManager.shared.state` (`.ready(path)`) and pass it in before
/// calling this method.
struct GLiNERExtractor {

    // MARK: - Label set

    /// GLiNER entity labels used for structured extraction. Derived from the
    /// same taxonomy as `RedactionCategories`, but phrased as natural-language
    /// strings the GLiNER2 model was trained to recognise.
    nonisolated static let labels: [String] = [
        "person name",
        "organization",
        "job title",
        "email address",
        "phone number",
        "mailing address",
        "money amount",
        "date",
        "url",
    ]

    // MARK: - Extraction

    /// Returns extracted entities as `StructuredItems`, or `nil` when the
    /// engine is unavailable (not Apple Silicon, plugin fails, or no detections
    /// above confidence threshold).
    ///
    /// **Call from a background context** — `RedactionEngineLoader().engine(...)`
    /// and `detect()` block synchronously (~1s on first load). The caller must
    /// resolve `modelPath` on the main actor from `RedactionModelManager.shared.state`
    /// (`.ready(path)`) before calling this method.
    func extract(transcript: String, modelPath: String) -> StructuredItems? {
        // Gate 1: Apple Silicon required (arm64 plugin only).
        guard RedactionEngineLoader.isAppleSilicon else { return nil }

        // Load the engine (blocking ~1s on first call) and run detection.
        return Self.detectAndMap(transcript: transcript, modelPath: modelPath)
    }

    // MARK: - Private helpers (nonisolated, off-main)

    /// Loads the engine (blocking), runs detection, filters by confidence, and
    /// maps detections to `StructuredItems`. Returns nil on any failure.
    private nonisolated static func detectAndMap(
        transcript: String,
        modelPath: String
    ) -> StructuredItems? {
        // Load the arm64 plugin engine (blocking ~1 s on first call).
        let loader = RedactionEngineLoader()
        guard let engine = loader.engine(modelPath: modelPath) else { return nil }

        // Run entity detection over the transcript.
        let raw: [EngineDetection] = engine.detect(
            text: transcript,
            entityTypes: GLiNERExtractor.labels
        )

        // Confidence threshold filter.
        let detections = raw.filter { $0.confidence >= 0.5 }
        guard !detections.isEmpty else { return nil }

        // Map detections → StructuredItems.
        return mapToStructuredItems(detections)
    }

    /// Pure mapping: `[EngineDetection]` → `StructuredItems`.
    ///
    /// - `EntityGrouping.groupContacts` handles person name / org / title /
    ///   email / phone grouping.
    /// - Non-contact labels are also routed into the appropriate string lists
    ///   so the coordinator can dedup them against the doc tier.
    private nonisolated static func mapToStructuredItems(
        _ detections: [EngineDetection]
    ) -> StructuredItems {

        // Feed all detections to EntityGrouping as (label, text) pairs.
        let pairs = detections.map { (label: $0.label, text: $0.text) }
        let grouped = EntityGrouping.groupContacts(pairs)

        var items = StructuredItems()
        items.contacts   = grouped.contacts
        items.formFields = grouped.formFields

        // Also populate the flat string lists for the six non-contact label
        // types so the coordinator's dedup pass can consolidate them.
        for det in detections {
            switch det.label {
            case "email address":   items.emails.append(det.text)
            case "phone number":    items.phones.append(det.text)
            case "mailing address": items.addresses.append(det.text)
            case "money amount":    items.money.append(det.text)
            case "date":            items.dates.append(det.text)
            case "url":             items.urls.append(det.text)
            default: break
            }
        }

        return items
    }
}
