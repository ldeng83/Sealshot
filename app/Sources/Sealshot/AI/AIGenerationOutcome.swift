import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Result of an on-device model generation. Lets callers persist a terminal
/// marker on `.skip` (so the work isn't retried forever) versus leaving it for a
/// later retry on `.transient`. Shared by the image- and video-summary paths and
/// any future model call.
enum AIGenerationOutcome: Equatable {
    /// Usable model output.
    case text(String)
    /// Terminal: the model ran but produced nothing usable, or the input is
    /// unsupported (e.g. non-language OCR, guardrail). Retrying the same input
    /// will not help — callers should record a terminal marker.
    case skip
    /// Transient failure (model/assets unavailable, unknown error). Retrying
    /// later may succeed — callers should NOT mark it terminal.
    case transient
}

#if canImport(FoundationModels)
@available(macOS 26, *)
enum AIErrorClassifier {
    /// Classify a thrown generation error as terminal (`.skip`) or retryable
    /// (`.transient`). Terminal classes are ones where the same input can never
    /// succeed: unsupported language/locale, guardrail violation, an unsupported
    /// generation guide, a decoding failure, or an over-budget context. Anything
    /// else (assets/model unavailable, unknown) is treated as transient.
    static func outcome(for error: Error) -> AIGenerationOutcome {
        guard let gen = error as? LanguageModelSession.GenerationError else { return .transient }
        switch gen {
        case .unsupportedLanguageOrLocale, .guardrailViolation,
             .unsupportedGuide, .decodingFailure, .exceededContextWindowSize:
            return .skip
        default:
            return .transient
        }
    }
}
#endif
