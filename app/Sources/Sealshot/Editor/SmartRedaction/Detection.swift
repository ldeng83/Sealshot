import CoreGraphics
import Foundation

/// What kind of sensitive content a detection is. The raw value is the
/// persistence key — `Detection` is `Codable` so detections can be stored in
/// the `.seal` manifest later, even though v1 keeps them ephemeral.
enum SensitiveCategory: String, Codable, CaseIterable, Sendable {
    case email
    case phone
    case creditCard
    // Cloud / API secrets
    case awsKey
    case stripeKey
    case githubToken
    case gitlabToken
    case googleApiKey
    case slackToken
    case openAIKey
    case anthropicKey
    case sendgridKey
    case twilioKey
    case jwt
    case bearerToken
    case privateKeyBlock
    case credentialedURL
    // Financial
    case iban
    case routingNumber
    case cryptoWallet
    // Vehicles (checksum-validated, ISO 3779)
    case vin
    // Network
    case ipAddress
    case macAddress
    // Contextual
    case ssn
    case secretAssignment
    // Identity documents
    case machineReadableZone
    // Contextual / NLP (NLTagger + NSDataDetector)
    case personName
    case organizationName
    case placeName
    case postalAddress
    case labeledField
    case highEntropy
    // Found by the on-device Foundation Model (context-sensitive PII the rules
    // miss: confirmation codes, passport/license numbers, names by context…).
    case contextual

    /// Detection certainty shown in the review panel. OCR lines don't carry
    /// per-line confidence (see `TextRecognizer`), so confidence reflects the
    /// strength of the *pattern*: anchored key formats are near-certain,
    /// loose numeric formats and the entropy heuristic less so.
    var baseConfidence: Double {
        switch self {
        case .awsKey, .stripeKey, .githubToken, .gitlabToken, .googleApiKey,
             .slackToken, .anthropicKey, .sendgridKey, .privateKeyBlock, .jwt,
             .machineReadableZone:
            return 0.95
        case .email, .creditCard, .bearerToken, .openAIKey, .twilioKey,
             .credentialedURL, .iban, .vin:
            return 0.9
        case .cryptoWallet, .macAddress, .ssn:
            return 0.85
        case .routingNumber, .postalAddress:
            return 0.8
        case .phone:
            return 0.75
        case .secretAssignment, .labeledField:
            return 0.7
        case .ipAddress:
            return 0.65
        case .highEntropy:
            return 0.6
        case .organizationName:
            return 0.5
        case .placeName, .personName:
            return 0.45
        case .contextual:
            return 0.6
        }
    }

    /// Catastrophic-leak categories that should be redacted by default
    /// regardless of detection confidence (their false-negative cost is far
    /// higher than an extra checked box the user can uncheck).
    var isHighRisk: Bool {
        switch self {
        case .creditCard, .iban, .routingNumber, .cryptoWallet, .ssn,
             .awsKey, .stripeKey, .githubToken, .gitlabToken, .googleApiKey,
             .slackToken, .openAIKey, .anthropicKey, .sendgridKey, .twilioKey,
             .jwt, .bearerToken, .privateKeyBlock, .credentialedURL, .secretAssignment,
             .machineReadableZone, .email, .phone, .postalAddress, .vin:
            return true
        case .personName, .organizationName, .placeName,
             .ipAddress, .macAddress, .labeledField, .highEntropy, .contextual:
            return false
        }
    }
}

/// One detected sensitive region, in 1× source-image space (top-left origin,
/// pixels) — the same space as `Annotation` geometry. `rects` is an array
/// because a single logical match can span multiple OCR line fragments.
struct Detection: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    let category: SensitiveCategory
    /// Matched text, pre-truncated for display so the review panel never
    /// shows a full secret (see `SensitiveTextRules.displaySnippet`).
    let snippet: String
    let confidence: Double
    let rects: [CGRect]
    /// Foundation-Model finds (`.contextual`) carry a precise type label and a
    /// one-line reason; nil for rule/NER detections (they use the category's
    /// `displayName` / `explanation`).
    let customLabel: String?
    let reason: String?

    init(id: UUID = UUID(), category: SensitiveCategory, snippet: String,
         confidence: Double, rects: [CGRect],
         customLabel: String? = nil, reason: String? = nil) {
        self.id = id
        self.category = category
        self.snippet = snippet
        self.confidence = confidence
        self.rects = rects
        self.customLabel = customLabel
        self.reason = reason
    }

    /// Shift every rect by (dx, dy), preserving identity. Used to map detections
    /// from a focus-area crop back into visible-image space.
    func offsetBy(dx: CGFloat, dy: CGFloat) -> Detection {
        guard dx != 0 || dy != 0 else { return self }
        return Detection(id: id, category: category, snippet: snippet, confidence: confidence,
                         rects: rects.map { $0.offsetBy(dx: dx, dy: dy) },
                         customLabel: customLabel, reason: reason)
    }
}

/// A sensitive item the on-device Foundation Model surfaced, with the precise
/// type and a one-line reason it produced. Plain (non-gated) so the analyzer and
/// review UI can use it without importing FoundationModels.
struct RedactionFinding: Equatable {
    let text: String
    let type: String
    let reason: String
}
