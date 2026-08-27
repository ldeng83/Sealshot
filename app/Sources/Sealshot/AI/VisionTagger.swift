import Foundation
import CoreGraphics
import Vision

/// Turns a decoded screenshot into a curated, high-precision set of visual tags.
/// Pure (no I/O beyond Vision); `tags(for:)` is synchronous because Vision's
/// `perform` blocks — callers run it off the main actor.
struct VisionTagger {

    /// Bump when the tag vocabulary or thresholds change materially, to trigger
    /// re-tagging via `CaptureMetadata.visualTagVersion`.
    static let version = 1

    let config: VisionTagConfig
    init(config: VisionTagConfig = .current) { self.config = config }

    /// Scene classification (photo/chart/map) was investigated via
    /// `VNClassifyImageRequest` and dropped: that taxonomy has no `photograph`
    /// label, and `chart`/`map` fire only at noise-level confidence (<0.1) on
    /// real content — the one high-confidence hit (`screenshot`) is redundant
    /// with the structural `document` detector and meaningless for a screenshot
    /// app. Scene tagging is deferred to a future dedicated-model effort, so
    /// `VisualTags.scene` is currently always empty (the merge path stays
    /// scene-aware for that future work). See task-4 calibration in the plan.
    func tags(for image: CGImage) -> VisualTags {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        return VisualTags(structural: structuralTags(handler), scene: [])
    }

    // MARK: structural

    /// All three detectors in ONE `perform`.
    ///
    /// They used to be three separate `perform` calls on the same handler,
    /// which makes Vision redo its per-request image preparation each time.
    /// Batching lets it prepare once and share that across the requests — the
    /// saving is largest exactly where it matters most, on a Mac with no
    /// Neural Engine, where face detection and document segmentation run on
    /// CPU/GPU. Failure stays per-request: `perform` throwing leaves every
    /// `results` nil, which reads as "no tags", the same as before.
    private func structuralTags(_ handler: VNImageRequestHandler) -> [String] {
        let barcodes = VNDetectBarcodesRequest()
        let faces = VNDetectFaceRectanglesRequest()
        let document = VNDetectDocumentSegmentationRequest()
        try? handler.perform([barcodes, faces, document])

        var tags: [String] = []
        if let codes = barcodeTags(barcodes) { tags.append(contentsOf: codes) }
        if !(faces.results?.isEmpty ?? true) { tags.append("contains-faces") }
        if let obs = document.results?.first,
           obs.confidence >= config.documentConfidence { tags.append("document") }
        return tags
    }

    /// QR vs 1D barcode from a single barcode request.
    private func barcodeTags(_ req: VNDetectBarcodesRequest) -> [String]? {
        guard let results = req.results, !results.isEmpty else { return nil }
        var tags: [String] = []
        if results.contains(where: { $0.symbology == .qr }) { tags.append("qr-code") }
        if results.contains(where: { $0.symbology != .qr }) { tags.append("barcode") }
        return tags.isEmpty ? nil : tags
    }
}
