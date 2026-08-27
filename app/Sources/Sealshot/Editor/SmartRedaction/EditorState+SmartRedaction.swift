import AppKit
import CoreGraphics

/// One detection under review: kept proposals become blur annotations on
/// Apply, skipped ones are dropped.
struct RedactionProposal: Identifiable, Equatable {
    let detection: Detection
    var isKept: Bool = true
    var id: UUID { detection.id }
}

/// Lifecycle of a smart-redaction scan. Transient UI state — never persisted
/// and never snapshotted for undo. `empty` is distinct from `idle` so the UI
/// can show a "no sensitive content found" note exactly once per scan.
enum RedactionScanState: Equatable {
    case idle
    case scanning
    case found([RedactionProposal])
    case empty

    /// Coarse lifecycle discriminator — `EditorState` bumps the sidebar's
    /// rebuild generation only when this changes, so kept-flag mutations
    /// (same phase) update the review panel in place instead of rebuilding.
    var phase: Int {
        switch self {
        case .idle: return 0
        case .scanning: return 1
        case .found: return 2
        case .empty: return 3
        }
    }

    /// The Smart Redact mode is "on screen": mid-scan OR showing the review
    /// panel. Drives the toolbar pill highlight — it stays lit through the whole
    /// interaction, not just the scan, so redaction reads as an active mode like
    /// Enhance/Live Text.
    var isActive: Bool {
        switch self {
        case .scanning, .found: return true
        case .idle, .empty: return false
        }
    }
}

extension EditorState {

    /// Detections at or above this confidence are checked by default in the
    /// review panel; lower-precision ones (NER names, IP addresses, the entropy
    /// heuristic) start unchecked so the user opts in rather than out.
    static let redactionAutoKeepThreshold = 0.7

    /// Substrings that mark a `.contextual` detection's `customLabel` as a
    /// high-risk identifier (engine/FM finds whose specific type isn't a mapped
    /// SensitiveCategory). Case-insensitive.
    private static let highRiskLabelKeywords = [
        "passport", "card", "ssn", "social security", "account number",
        "national id", "driver", "licen", "iban", "routing", "mrz",
        "machine readable", "tax id", "bank account",
        // Contact PII + PHI (real captures showed these slipping through unchecked).
        "email", "phone", "address",
        "medical", "medication", "diagnosis", "prescription", "allerg", "health",
        // Government ID numbers (GLiNER2 "identity document number" is unmapped).
        "identity document", "document number",
    ]

    static func isHighRiskLabel(_ label: String?) -> Bool {
        guard let l = label?.lowercased() else { return false }
        return highRiskLabelKeywords.contains { l.contains($0) }
    }

    /// GLiNER2 emits the unmapped label "money amount" (→ .contextual).
    static func isMoneyAmount(_ d: Detection) -> Bool {
        d.customLabel?.lowercased().contains("money") ?? false
    }

    /// Whether a proposal is checked by default: high-risk categories and
    /// high-risk labels are always kept (leak cost is catastrophic); on
    /// financial documents, money amounts are also kept; everything else uses
    /// the confidence threshold.
    /// Down-ranked "noise" labels (DetectionRelabel sanity reclassification):
    /// mislabeled non-PII kept visible but never auto-checked.
    private static let noiseLabels: Set<String> = ["timestamp", "hostname", "service name"]
    static func isNoiseLabel(_ label: String?) -> Bool {
        guard let l = label?.lowercased() else { return false }
        return noiseLabels.contains(l)
    }

    static func defaultKept(_ d: Detection, financialDocument: Bool = false) -> Bool {
        if isNoiseLabel(d.customLabel) { return false }
        return d.category.isHighRisk
            || isHighRiskLabel(d.customLabel)
            || (financialDocument && isMoneyAmount(d))
            || d.confidence >= redactionAutoKeepThreshold
    }

    func presentRedactionProposals(_ detections: [Detection], financialDocument: Bool = false) {
        let ordered = Self.readingOrderSorted(detections)
        redactionListScrollOffset = 0   // fresh scan → fresh list, start at the top
        redactionScan = ordered.isEmpty
            ? .empty
            : .found(ordered.map {
                RedactionProposal(detection: $0, isKept: Self.defaultKept($0, financialDocument: financialDocument))
            })
    }

    func toggleRedactionProposal(_ id: UUID) {
        guard case .found(var proposals) = redactionScan,
              let index = proposals.firstIndex(where: { $0.id == id }) else { return }
        proposals[index].isKept.toggle()
        redactionScan = .found(proposals)
    }

    /// Check or uncheck every proposal at once (Select all / Deselect all).
    func setAllRedactionProposals(kept: Bool) {
        guard case .found(var proposals) = redactionScan else { return }
        for i in proposals.indices { proposals[i].isKept = kept }
        redactionScan = .found(proposals)
    }

    func cancelRedactionScan() {
        redactionScan = .idle
    }

    /// Detections in page reading order: top-to-bottom, then left-to-right within
    /// a row. Rows are grouped by `minY` proximity (band = median bounding-box
    /// height) so same-line items read left-to-right despite minor `minY` jitter.
    /// Rects are top-left origin, so ascending minY = top, minX = left.
    /// Detections without rects sort last; stable for ties.
    nonisolated static func readingOrderSorted(_ detections: [Detection]) -> [Detection] {
        func bbox(_ d: Detection) -> CGRect? {
            guard let first = d.rects.first else { return nil }
            return d.rects.dropFirst().reduce(first) { $0.union($1) }
        }
        var positioned: [(det: Detection, box: CGRect, idx: Int)] = []
        var unpositioned: [Detection] = []
        for (i, d) in detections.enumerated() {
            if let b = bbox(d) { positioned.append((d, b, i)) } else { unpositioned.append(d) }
        }
        guard !positioned.isEmpty else { return detections }
        // Use individual rect heights (not union bbox heights) so multi-line
        // detections don't inflate the band estimate.
        let allRectHeights = detections.flatMap(\.rects).map(\.height).sorted()
        let heights = allRectHeights.isEmpty ? positioned.map(\.box.height).sorted() : allRectHeights
        let band = max(1, heights[heights.count / 2] * 0.7)
        // Stable sort by minY (idx breaks ties to preserve input order).
        let byY = positioned.sorted { $0.box.minY != $1.box.minY ? $0.box.minY < $1.box.minY : $0.idx < $1.idx }
        var ordered: [Detection] = []
        var row: [(det: Detection, box: CGRect, idx: Int)] = []
        var baseline: CGFloat = 0
        func flush() {
            ordered.append(contentsOf:
                row.sorted { $0.box.minX != $1.box.minX ? $0.box.minX < $1.box.minX : $0.idx < $1.idx }
                   .map(\.det))
            row.removeAll()
        }
        for item in byY {
            if row.isEmpty { baseline = item.box.minY; row.append(item) }
            else if item.box.minY - baseline <= band { row.append(item) }
            else { flush(); baseline = item.box.minY; row.append(item) }
        }
        flush()
        return ordered + unpositioned
    }

    /// Convert every kept proposal into a solid-fill blur annotation (one
    /// rect annotation per detection rect), as a single undo step. Solid is
    /// deliberate: pixelation of short high-value strings is reversible, so
    /// detected redactions always default to the strongest mode regardless of
    /// the blur tool's current setting.
    func applyKeptRedactionProposals() {
        guard case .found(let proposals) = redactionScan else { return }
        redactionScan = .idle
        guard !isReadOnly else { return }
        let rects = proposals.filter(\.isKept).flatMap(\.detection.rects)
        guard !rects.isEmpty else { return }

        recordUndoCheckpoint(action: "Redact")
        let style = Style(strokeColor: SerializableColor(selectedColor),
                          strokeWidth: 0,
                          opacity: 1.0,
                          fillColor: SerializableColor(opaqueSRGB(blurSolidColor)),
                          blurMode: .solid,
                          // A redaction must hide completely — use the Solid
                          // opacity default (full), not the Gaussian strength.
                          blurStrength: blurSolidOpacity)
        annotations.append(contentsOf: rects.map {
            Annotation(geometry: .blur(region: .rect($0)), style: style)
        })
    }
}
