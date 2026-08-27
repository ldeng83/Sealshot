import Foundation

/// Why the on-device Foundation Model is not usable right now.
///
/// The distinction matters: `.appleIntelligenceOff` is a ten-second fix in
/// System Settings, while `.deviceNotEligible` is permanent for this Mac.
/// Telling both users the same thing would either waste the first one's
/// opportunity or nag the second one about something they cannot change.
enum AIUnavailableReason: Equatable {
    /// Below macOS 26 — the framework itself is absent.
    case notSupportedOS
    /// Intel or otherwise unsupported silicon.
    case deviceNotEligible
    /// Eligible Mac, but the user has Apple Intelligence switched off.
    case appleIntelligenceOff
    /// Turned on, still downloading the model.
    case modelNotReady
    /// A framework reason we have no specific copy for (e.g. a future
    /// `SystemLanguageModel.Availability.UnavailableReason` case, or an
    /// unrecognized top-level `Availability` case). Must not assert anything
    /// specific about the user's hardware, OS, or settings — we don't know.
    case unavailableForAnotherReason
}

enum AIStatus: Equatable {
    case available
    case unavailable(AIUnavailableReason)
}

/// A message for the user about the current AI status, plus whether it is
/// worth offering a way to act on it.
struct AINudge: Equatable {
    let title: String
    let body: String
    /// True only when the user can actually fix the situation — the sole
    /// case that earns an "Open System Settings…" button.
    let isActionable: Bool
}

/// Turns an availability status into what the user is told. The single home
/// for this copy: Settings and the Info panel both render whatever this
/// returns, so the wording can never drift between them.
///
/// Returns nil when there is nothing to say (everything is working).
enum AINudgePolicy {

    /// The Info panel's Summary-section unlock line (image and video panels
    /// both render this exact string) — copy has one home.
    static let summaryUnlockLine = "Summaries need Apple Intelligence turned on."

    static func presentation(for status: AIStatus, aiToggleOn: Bool) -> AINudge? {
        // Sealshot's own switch outranks every system reason. Someone who
        // turned this off deliberately should not be pitched Apple
        // Intelligence for a feature they already declined.
        guard aiToggleOn else {
            return AINudge(
                title: "On-device AI is off",
                body: "On-device AI is turned off in Sealshot.",
                isActionable: false)
        }

        switch status {
        case .available:
            return nil

        case .unavailable(.appleIntelligenceOff):
            return AINudge(
                title: "Apple Intelligence is off",
                body: "Turning it on adds capture summaries, smarter titles and keywords, "
                    + "and contextual Smart Redaction. Sealshot only ever uses the on-device "
                    + "model — your captures are never sent anywhere. Apple Intelligence is "
                    + "an Apple system feature with its own privacy terms, and other apps can "
                    + "choose to use its cloud (Private Cloud Compute); that's your call, not "
                    + "Sealshot's. Everything else in Sealshot works without it. You'll find it "
                    + "in System Settings ▸ Apple Intelligence & Siri.",
                isActionable: true)

        case .unavailable(.deviceNotEligible):
            return AINudge(
                title: "Apple Intelligence isn't available on this Mac",
                body: "This Mac doesn't support Apple Intelligence. Sealshot uses its "
                    + "built-in on-device engine instead — OCR, Smart Redaction, and "
                    + "tagging all work.",
                isActionable: false)

        case .unavailable(.notSupportedOS):
            return AINudge(
                title: "These features need a newer macOS",
                body: "Sealshot's Apple Intelligence features need macOS 26 or later. "
                    + "On this Mac it uses its built-in on-device engine instead.",
                isActionable: false)

        case .unavailable(.modelNotReady):
            return AINudge(
                title: "Apple Intelligence is getting ready",
                body: "Apple Intelligence is still downloading its model. These features "
                    + "appear once it finishes.",
                isActionable: false)

        case .unavailable(.unavailableForAnotherReason):
            return AINudge(
                title: "Apple Intelligence isn't available right now",
                body: "Sealshot uses its built-in on-device engine in the meantime.",
                isActionable: false)
        }
    }
}
