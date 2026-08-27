import Foundation
@testable import Sealshot

/// One redaction-coverage case: text the always-on layers (regex floor +
/// anchored label→value/address) must handle. `expect` = spans that must be
/// detected (recall); `reject` = substrings that must NOT be flagged (precision).
struct CoverageCase {
    let id: String
    let docType: String
    let ocrText: String
    let expect: [(SensitiveCategory, String)]
    let reject: [String]
}

enum RedactionCoverageFixtures {
    static let all: [CoverageCase] = [
        CoverageCase(
            id: "passport-labeled-fields", docType: "passport",
            ocrText: "Passport No.: ZE000509\nDate of birth: 01 JAN 1985",
            expect: [(.labeledField, "ZE000509"), (.labeledField, "01 JAN 1985")],
            reject: ["Passport No.", "Date of birth"]),   // labels themselves stay visible
        CoverageCase(
            id: "passport-mrz", docType: "passport",
            ocrText: "P<CANMARTIN<<SARAH<<<<<<<<<<<<<<<<<<<<<<<<<<<\nZE000509<9CAN8501019F2301147<<<<<<<<<<<<<<08",
            expect: [(.machineReadableZone, "P<CANMARTIN<<SARAH"),
                     (.machineReadableZone, "ZE000509<9CAN8501019F2301147")],
            reject: []),
        CoverageCase(
            id: "balance-sheet-not-org", docType: "financial",
            ocrText: "Treasury stock (2,000)\nTotal current liabilities 47,000",
            expect: [],                       // the always-on layer flags neither (no labels/secrets)
            reject: ["Treasury stock"]),      // must never be flagged as sensitive
        CoverageCase(
            id: "plain-prose-negative", docType: "negative",
            ocrText: "The patient was discharged on a sunny afternoon and went home.",
            expect: [],
            reject: ["patient", "discharged"]),  // bare label word in prose, no separator → no match
        // Bank statement: account number is alphanumeric (bypasses phone rule);
        // routing number is ABA-valid so fires as .routingNumber (higher confidence).
        CoverageCase(
            id: "bank-statement", docType: "financial",
            ocrText: "Account number: ACC-7788-9900\nRouting number: 021000021",
            expect: [(.labeledField, "ACC-7788-9900"), (.routingNumber, "021000021")],
            reject: ["Account number", "Routing number"]),
        // Medical record: values are opaque IDs/prose, caught only by label→value.
        CoverageCase(
            id: "medical-record", docType: "health",
            ocrText: "MRN: 00123456\nDiagnosis: hypertension\nMember ID: XYZ7788",
            expect: [(.labeledField, "00123456"), (.labeledField, "hypertension"), (.labeledField, "XYZ7788")],
            reject: ["MRN", "Diagnosis"]),
        // Insurance card: opaque IDs caught by label→value.
        CoverageCase(
            id: "insurance-card", docType: "health",
            ocrText: "Member ID: XYZ7788\nPolicy number: AB-99-1234\nGroup number: GRP-5678",
            expect: [(.labeledField, "XYZ7788"), (.labeledField, "AB-99-1234")],
            reject: ["Member ID", "Policy number"]),
        // Pay stub: employee ID is alphanumeric; SSN fires as .ssn (higher confidence).
        CoverageCase(
            id: "pay-stub", docType: "employment",
            ocrText: "Employee ID: EMP-0042\nSSN: 123-45-6789",
            expect: [(.labeledField, "EMP-0042"), (.ssn, "123-45-6789")],
            reject: ["Employee ID", "SSN"]),
        // Wire transfer: IBAN value has spaces so the format-rule regex won't
        // match it; the label→value path captures the full spaced value instead.
        CoverageCase(
            id: "wire-transfer", docType: "financial",
            ocrText: "IBAN: GB29 NWBK 6016 1331 9268 19\nSort code: 60-16-13",
            expect: [(.labeledField, "GB29 NWBK 6016 1331 9268 19"), (.labeledField, "60-16-13")],
            reject: ["IBAN", "Sort code"]),
        CoverageCase(
            id: "hyphen-compound-prose", docType: "negative",
            ocrText: "Apply for visa-free travel; she is a card-carrying member and policy-making is hard.",
            expect: [],
            reject: ["free travel", "carrying member", "making is hard"]),
        CoverageCase(
            id: "bare-shortword-labels", docType: "negative",
            ocrText: "case: SSHOT-123\nIn this case - we proceed carefully",
            expect: [],
            reject: ["SSHOT-123", "we proceed carefully"]),
    ]
}
