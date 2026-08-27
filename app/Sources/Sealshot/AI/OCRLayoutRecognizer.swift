import Vision
import CoreGraphics

/// Runs `VNRecognizeTextRequest` over a `CGImage` and returns one `LayoutToken`
/// per recognized text observation in normalized [0,1] top-down coordinates
/// (y increases downward from the top of the image).
///
/// This is the Vision boundary for the structured-extraction pipeline; all
/// downstream geometry (TableReconstructor etc.) is Vision-free and receives
/// plain `[LayoutToken]`.
struct OCRLayoutRecognizer {

    func recognize(_ image: CGImage) async throws -> [LayoutToken] {
        try await Task.detached(priority: .userInitiated) {
            try recognizeSync(image)
        }.value
    }
}

private func recognizeSync(_ image: CGImage) throws -> [LayoutToken] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    // Match TextRecognizer: without this Vision assumes en-US and garbles
    // non-Latin scripts. The explicit list is the detector's Latin prior
    // (see TextRecognizer.recognizeLines).
    request.automaticallyDetectsLanguage = true
    request.recognitionLanguages = ["en-US"]
    request.minimumTextHeight = 0.008

    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])

    return (request.results ?? []).compactMap { obs -> LayoutToken? in
        guard let candidate = obs.topCandidates(1).first else { return nil }
        let text = foldStrayFullwidth(candidate.string)
        guard !text.isEmpty else { return nil }
        return LayoutToken(text: text, rect: flipY(obs.boundingBox))
    }
}

/// Vision uses bottom-left origin; convert to top-left origin so y increases
/// downward — matching the `LayoutToken` convention expected by `TableReconstructor`.
private func flipY(_ r: CGRect) -> CGRect {
    CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height)
}
