import Foundation
import CoreGraphics

/// One OCR line with its normalized [0,1], top-left-origin bounding box. Box
/// height is a font-size proxy used to weight titles by visual prominence.
/// A lightweight stand-in for the editor's `RecognizedLine` that keeps the
/// metadata module independent of the OCR module.
struct OCRLine: Equatable {
    let text: String
    let box: CGRect
}

/// Everything the rule-based generator needs, gathered after a capture.
/// No `browserDomain` in Phase 1 (deferred — needs per-browser automation).
struct MetadataSignals: Equatable {
    let ocrText: String
    /// Per-line geometry, when available. Empty for text-only callers; the
    /// generator falls back to reading-order selection on `ocrText` then.
    let ocrLines: [OCRLine]
    let sourceApp: String?
    let windowTitle: String?
    let captureDate: Date
    let imageWidth: Int
    let imageHeight: Int

    init(ocrText: String, ocrLines: [OCRLine] = [], sourceApp: String?,
         windowTitle: String?, captureDate: Date, imageWidth: Int, imageHeight: Int) {
        self.ocrText = ocrText
        self.ocrLines = ocrLines
        self.sourceApp = sourceApp
        self.windowTitle = windowTitle
        self.captureDate = captureDate
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
    }
}
