import Foundation

enum RedactionCategories {
    /// Entity labels passed to GLiNER2. Names are what the model keys on. The
    /// ID-document labels (passport/licence number, issue/expiry dates, place of
    /// birth, nationality) materially raise recall on identity documents — a
    /// probe on a sample passport went from 3 hits to 9 (catching the passport
    /// number, place of birth, nationality, and issue/expiry dates the base set
    /// missed). Unmapped labels surface as `.contextual` carrying the label.
    static let entityTypes: [String] = [
        "person name", "organization", "email address", "phone number",
        "mailing address", "date of birth", "social security number",
        "bank account number", "credit card number", "money amount",
        "medical condition", "medication", "ip address", "api key", "password",
        "passport number", "identity document number", "driver's license number",
        "date of issue", "date of expiry", "place of birth", "nationality",
    ]
    /// Type-agnostic PII present on any document — always included.
    static let coreEntityTypes: [String] = [
        "person name", "organization", "email address", "phone number",
        "mailing address", "date of birth", "social security number",
        "credit card number", "money amount", "ip address", "api key", "password",
    ]
    /// Labels specific to a document type. `coreEntityTypes` + every group here
    /// must equal the canonical `entityTypes` union (locked by a test).
    private static let typeSpecific: [RedactionDocType: [String]] = [
        .identity: ["passport number", "identity document number", "driver's license number",
                    "date of issue", "date of expiry", "place of birth", "nationality"],
        .health: ["medical condition", "medication"],
        .financial: ["bank account number"],
    ]
    /// The entity labels to run for the classified document type(s): core PII
    /// plus each matched type's specific labels (de-duped, stable order). An
    /// empty set falls back to the full union, so misclassification never loses
    /// recall.
    static func entityTypes(for types: Set<RedactionDocType>) -> [String] {
        guard !types.isEmpty else { return entityTypes }
        var seen = Set<String>(); var out: [String] = []
        func add(_ labels: [String]) { for l in labels where seen.insert(l).inserted { out.append(l) } }
        add(coreEntityTypes)
        for type in RedactionDocType.allCases where types.contains(type) { add(typeSpecific[type] ?? []) }
        return out
    }
    private static let map: [String: SensitiveCategory] = [
        "email address": .email, "phone number": .phone, "credit card number": .creditCard,
        "social security number": .ssn, "person name": .personName, "organization": .organizationName,
        "mailing address": .postalAddress, "ip address": .ipAddress, "bank account number": .iban,
        "password": .secretAssignment, "api key": .secretAssignment,
        "vin": .vin, "vehicle identification number": .vin,
    ]
    /// Return the `SensitiveCategory` for a known engine label, or nil when
    /// the label is unrecognised (caller should fall back to `.contextual`).
    static func category(forEngineLabel label: String) -> SensitiveCategory? {
        map[label.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)]
    }
}
