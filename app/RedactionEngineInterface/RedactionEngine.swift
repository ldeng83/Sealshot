import Foundation

/// One sensitive item found by an on-device engine: a category label (free text
/// from the model), the matched substring, and a confidence. Plain/Sendable so
/// it can cross the app↔plugin boundary without importing MLX.
public struct EngineDetection: Equatable, Sendable {
    public let label: String
    public let text: String
    public let confidence: Double
    public init(label: String, text: String, confidence: Double) {
        self.label = label; self.text = text; self.confidence = confidence
    }
}

/// Detection-only interface the universal app depends on. The implementation
/// lives in the arm64-only plugin (GLiNER2/MLX); the app never links MLX.
public protocol RedactionEngine: AnyObject {
    /// Detect entities of the given types in one block of OCR text.
    func detect(text: String, entityTypes: [String]) -> [EngineDetection]
}

/// Principal-class factory the plugin bundle exposes (so the app can load it via
/// NSBundle without a compile-time dependency).
@objc public protocol RedactionEngineProviding {
    /// Load the model at `modelPath` and return a ready engine, or nil on failure.
    @objc func makeEngine(modelPath: String) -> AnyObject?
}
