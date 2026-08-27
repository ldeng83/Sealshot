import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Whether the on-device Foundation Model can be used on this machine right
/// now — and, when it cannot, why.
///
/// `status` is a thin adapter over an answer that depends on the host machine,
/// so it carries no test coverage of its own; the decision logic built on top
/// of it lives in `AINudgePolicy`, which is pure and fully tested.
enum AIAvailability {

    /// Test seam. Production never sets this. Tests that need a specific
    /// machine state set it in `setUp` and MUST clear it in `tearDown` —
    /// it is process-global.
    static var statusOverride: AIStatus?

    static var status: AIStatus {
        if let statusOverride { return statusOverride }
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible:
                    return .unavailable(.deviceNotEligible)
                case .appleIntelligenceNotEnabled:
                    return .unavailable(.appleIntelligenceOff)
                case .modelNotReady:
                    return .unavailable(.modelNotReady)
                @unknown default:
                    // A reason we have no copy for. Fall back to the silent,
                    // non-actionable case that asserts nothing about hardware,
                    // OS, or settings — inventing a specific reason would risk
                    // telling an eligible user their Mac is unsupported.
                    return .unavailable(.unavailableForAnotherReason)
                }
            @unknown default:
                // An availability case we don't recognize at all. Same
                // reasoning as above: say nothing specific, don't guess.
                return .unavailable(.unavailableForAnotherReason)
            }
        }
        #endif
        return .unavailable(.notSupportedOS)
    }

    /// Unchanged meaning for all existing callers: false on anything below
    /// macOS 26, on ineligible hardware, when Apple Intelligence is off, or
    /// while the model is still downloading.
    static var isFoundationModelAvailable: Bool {
        status == .available
    }
}
