import Foundation

/// Coarse document categories used to tune the GLiNER2 label set. Multi-label:
/// a capture can match several (an ID shown on a bank statement).
enum RedactionDocType: CaseIterable { case identity, health, financial }

/// Pure keyword classifier over OCR text. A type is included when it has at
/// least one STRONG anchor or two REGULAR anchors; otherwise it's omitted
/// (empty result → the caller uses the full union, so misclassification is safe).
enum RedactionDocTypeClassifier {
    private static let strong: [RedactionDocType: [String]] = [
        .identity: ["passport", "national id", "driver's licence", "driver's license", "machine readable"],
        .health: ["diagnosis", "mrn", "medical record"],
        .financial: ["iban", "routing number", "swift", "sort code",
                     "balance sheet", "income statement", "cash flow"],
    ]
    private static let regular: [RedactionDocType: [String]] = [
        .identity: ["nationality", "place of birth", "date of expiry", "date of issue", "issuing authority"],
        .health: ["patient", "blood type", "prescription", "medication"],
        .financial: ["account number", "account no", "statement", "balance", "wire transfer",
                     "assets", "liabilities", "equity", "shareholders", "revenue",
                     "accounts payable", "accounts receivable", "retained earnings",
                     "net income", "total assets",
                     // Invoices / claims / estimates — money-bearing operational
                     // docs (regular, not strong: a passing "invoice" mention in
                     // prose shouldn't trip the money floor on its own).
                     "invoice", "subtotal", "grand total", "deductible", "amount due",
                     "unit price", "invoice total", "estimate"],
    ]
    static func classify(_ ocrText: String) -> Set<RedactionDocType> {
        let t = ocrText.lowercased()
        var out: Set<RedactionDocType> = []
        for type in RedactionDocType.allCases {
            let s = (strong[type] ?? []).reduce(0) { $0 + (t.contains($1) ? 1 : 0) }
            let r = (regular[type] ?? []).reduce(0) { $0 + (t.contains($1) ? 1 : 0) }
            if s >= 1 || r >= 2 { out.insert(type) }
        }
        return out
    }
}
