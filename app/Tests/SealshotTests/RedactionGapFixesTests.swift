import XCTest
import CoreGraphics
@testable import Sealshot

/// Regression tests for the claims-workstation detection gaps: side-adjacent
/// form fields (label left, value right), self-labeled values (label + value
/// on one line without a separator), VINs, claim numbers, invoice/claims
/// financial classification, and multi-occurrence rect survival.
@MainActor
final class RedactionGapFixesTests: XCTestCase {

    /// Build a layout from (text, x, y, w, h) normalized line boxes.
    private func layout(_ rows: [(String, CGFloat, CGFloat, CGFloat, CGFloat)]) -> RecognizedTextLayout {
        let lines = rows.map { (t, x, y, w, h) -> RecognizedLine in
            let n = max(t.count, 1)
            let boxes = (0..<t.count).map {
                CGRect(x: x + CGFloat($0)/CGFloat(n)*w, y: y, width: w/CGFloat(n), height: h)
            }
            return RecognizedLine(text: t, box: CGRect(x: x, y: y, width: w, height: h), charBoxes: boxes)
        }
        return RecognizedTextLayout(lines: lines)
    }
    private let tile = CGRect(x: 0, y: 0, width: 1000, height: 1000)

    // MARK: - Side-adjacent label → value (form UIs: label left, value right)

    func test_capturesValueBesideLabel() {
        let l = layout([
            ("Policy Number:", 0.10, 0.10, 0.12, 0.02),
            ("AUTO-87654321",  0.26, 0.10, 0.14, 0.02),
        ])
        let dets = SmartRedactionAnalyzer.labeledValueDetections(in: l, tile: tile)
        XCTAssertEqual(dets.count, 1)
        XCTAssertEqual(dets[0].snippet, "AUTO-87654321")
        XCTAssertEqual(dets[0].customLabel, "policy number")
    }

    /// Table headers must not fire: "Claim #" beside "Claimant" — a beside
    /// value must carry a digit (names/labels belong to the NER).
    func test_besideValue_requiresADigit() {
        let l = layout([
            ("Claim #",  0.05, 0.10, 0.06, 0.02),
            ("Claimant", 0.13, 0.10, 0.08, 0.02),
        ])
        XCTAssertTrue(SmartRedactionAnalyzer.labeledValueDetections(in: l, tile: tile).isEmpty)
    }

    /// A far-away line on the same row is not the label's value field.
    func test_besideValue_boundedGap() {
        let l = layout([
            ("Policy Number:", 0.05, 0.10, 0.12, 0.02),
            ("REC-1379-14",    0.80, 0.10, 0.10, 0.02),   // other side of the window
        ])
        XCTAssertTrue(SmartRedactionAnalyzer.labeledValueDetections(in: l, tile: tile).isEmpty)
    }

    // MARK: - Self-labeled value (label + digit-bearing value, no separator)

    func test_selfLabeledDOB_noSeparator() {
        let l = layout([("DOB 1975-12-12", 0.2, 0.1, 0.15, 0.02)])
        let dets = SmartRedactionAnalyzer.labeledValueDetections(in: l, tile: tile)
        XCTAssertEqual(dets.count, 1)
        XCTAssertEqual(dets[0].snippet, "1975-12-12")
        XCTAssertEqual(dets[0].customLabel, "dob")
    }

    /// Prose with digits after a label word must not fire (every value token
    /// must carry a digit).
    func test_selfLabeled_rejectsProse() {
        let l = layout([("Patient 5 was discharged yesterday", 0.1, 0.1, 0.4, 0.02)])
        XCTAssertTrue(SmartRedactionAnalyzer.labeledValueDetections(in: l, tile: tile).isEmpty)
    }

    // MARK: - VIN

    /// Checksum-valid VIN (ISO 3779 check digit at position 9) fires anywhere.
    func test_vinRule_matchesValidCheckDigit() {
        let ms = SensitiveTextRules.combinedMatches(in: "Vehicle 1HGCV1F35JA123456 listed",
                                                    additional: [])
        XCTAssertTrue(ms.contains { $0.category == .vin && $0.text == "1HGCV1F35JA123456" })
    }

    /// Invalid check digit (typical synthetic/demo VIN) → the content rule
    /// stays silent; the label path below covers the labeled case.
    func test_vinRule_rejectsInvalidCheckDigit() {
        let ms = SensitiveTextRules.combinedMatches(in: "Vehicle 1HGCV1F30JA123456 listed",
                                                    additional: [])
        XCTAssertFalse(ms.contains { $0.category == .vin })
    }

    func test_vinLabel_catchesLabeledFakeVIN() {
        let ms = ContextualDetectors.matches(in: "VIN: 1HGCV1F30JA123456")
        XCTAssertTrue(ms.contains { $0.category == .labeledField && $0.text == "1HGCV1F30JA123456" })
    }

    // MARK: - Claim number label

    func test_claimNumberLabel_sameLine() {
        let ms = ContextualDetectors.matches(in: "Claim Number: REC-1379-14")
        XCTAssertTrue(ms.contains { $0.category == .labeledField && $0.text == "REC-1379-14" })
    }

    // MARK: - Doc classifier: invoices/claims are financial (money floor)

    func test_invoiceDocument_classifiesFinancial() {
        let text = "INVOICE\nSubtotal $3,301.07\nGrand Total $3,401.07\nDeductible $500.00"
        XCTAssertTrue(RedactionDocTypeClassifier.classify(text).contains(.financial))
    }

    func test_casualInvoiceMention_notFinancial() {
        XCTAssertFalse(RedactionDocTypeClassifier.classify("please send the invoice tomorrow")
            .contains(.financial))
    }

    // MARK: - Medical-record labels (GDPR special categories + clinical fields)

    func test_specialCategoryLabels_valueBelow() {
        let l = layout([
            ("ETHNICITY",             0.05, 0.10, 0.10, 0.02),
            ("Asian",                 0.05, 0.13, 0.06, 0.02),
            ("RELIGIOUS AFFILIATION", 0.30, 0.10, 0.20, 0.02),
            ("Christian",             0.30, 0.13, 0.09, 0.02),
        ])
        let dets = SmartRedactionAnalyzer.labeledValueDetections(in: l, tile: tile)
        XCTAssertEqual(Set(dets.map(\.snippet)), ["Asian", "Christian"])
        XCTAssertEqual(Set(dets.compactMap(\.customLabel)),
                       ["ethnicity", "religious affiliation"])
    }

    func test_allergyAndBiometricLabels_valueBelow() {
        let l = layout([
            ("ALLERGY NAME",   0.05, 0.10, 0.12, 0.02),
            ("Bee Stings",     0.05, 0.13, 0.10, 0.02),
            ("BLOOD PRESSURE", 0.40, 0.10, 0.14, 0.02),
            ("118/78 mmHg",    0.40, 0.13, 0.11, 0.02),
        ])
        let dets = SmartRedactionAnalyzer.labeledValueDetections(in: l, tile: tile)
        XCTAssertEqual(Set(dets.map(\.snippet)), ["Bee Stings", "118/78 mmHg"])
    }

    /// "sex" must not shadow "sexual orientation" in the alternation, and a
    /// sports "RACE RESULTS" header stays below the label-fraction gate.
    func test_demographicLabels_edges() {
        let ms = ContextualDetectors.matches(in: "Sexual Orientation: Heterosexual")
        XCTAssertTrue(ms.contains { $0.category == .labeledField && $0.text == "Heterosexual" })
        let l = layout([
            ("Race Results 2024",      0.05, 0.10, 0.20, 0.02),
            ("1. Team Alpha 2:04:11",  0.05, 0.13, 0.20, 0.02),
        ])
        XCTAssertTrue(SmartRedactionAnalyzer.labeledValueDetections(in: l, tile: tile).isEmpty)
    }

    // MARK: - Audit-wave rules (masked PAN, DOB-anywhere, ticket IDs, roles)

    func test_maskedPAN_lastFour() {
        let ms = SensitiveTextRules.combinedMatches(in: "Visa **** 4242 on file", additional: [])
        XCTAssertTrue(ms.contains { $0.category == .creditCard && $0.text == "4242" })
    }

    func test_dobAnywhereInLine() {
        for line in ["Samir Chen · DOB 2001-05-03", "Born 16 Aug 1982 in Sydney",
                     "BIRTHDAY 12/17/1960 (54)"] {
            let ms = SensitiveTextRules.combinedMatches(in: line, additional: [])
            XCTAssertTrue(ms.contains { $0.category == .labeledField }, "missed: \(line)")
        }
    }

    func test_ticketRecordIdentifiers() {
        for id in ["PRIV-2346", "INC-2174", "CLM-3391-18", "POL-7745-CK", "OT-2024-0512"] {
            let ms = SensitiveTextRules.combinedMatches(in: "ref \(id) assigned", additional: [])
            XCTAssertTrue(ms.contains { $0.category == .labeledField && $0.text == id },
                          "missed: \(id)")
        }
        // Short prefixes with few digits stay out ("A-123", "Q-42").
        XCTAssertFalse(SensitiveTextRules.combinedMatches(in: "see A-123 and Q-42", additional: [])
            .contains { $0.category == .labeledField })
    }

    func test_roleLabels_captureSubjectNames() {
        let l = layout([
            ("Claimant:",    0.06, 0.10, 0.08, 0.014),
            ("Priya Keller", 0.20, 0.10, 0.10, 0.014),
            ("Tenant",       0.06, 0.20, 0.05, 0.014),
            ("Alex Rios",    0.06, 0.23, 0.08, 0.014),
        ])
        let dets = SmartRedactionAnalyzer.labeledValueDetections(in: l, tile: tile)
        XCTAssertEqual(Set(dets.map(\.snippet)), ["Priya Keller", "Alex Rios"])
    }

    // MARK: - Backup-code grids

    func test_backupCodeGrid_allCellsCaught_buttonExcluded() {
        var rows: [(String, CGFloat, CGFloat, CGFloat, CGFloat)] = [
            ("Backup Verification codes", 0.40, 0.50, 0.12, 0.012),
        ]
        let codes = ["38045294", "60682352", "81249913", "99256130", "52110679", "85773051"]
        for (k, code) in codes.enumerated() {
            let col = CGFloat(k % 3), row = CGFloat(k / 3)
            rows.append((code, 0.40 + col * 0.09, 0.53 + row * 0.03, 0.05, 0.012))
        }
        rows.append(("GENERATE NEW CODES", 0.40, 0.60, 0.11, 0.012))
        let dets = SmartRedactionAnalyzer.labeledValueDetections(in: layout(rows), tile: tile)
        XCTAssertEqual(Set(dets.map(\.snippet)), Set(codes))
        XCTAssertEqual(dets.count, codes.count, "the button must not be collected")
    }

    func test_codeLikeness() {
        XCTAssertTrue(SmartRedactionAnalyzer.isCodeLike("38045294"))
        XCTAssertTrue(SmartRedactionAnalyzer.isCodeLike("ab12-cd34"))
        XCTAssertFalse(SmartRedactionAnalyzer.isCodeLike("GENERATE NEW CODES"))
        XCTAssertFalse(SmartRedactionAnalyzer.isCodeLike("12345"))          // too short
        XCTAssertFalse(SmartRedactionAnalyzer.isCodeLike("Off"))
    }

    // MARK: - Deterministic street / city-state-zip lines

    func test_streetLines_consistentAcrossSuffixes() {
        for line in ["456 Maple Drive", "222 Cedar Court", "55 Sunset Way",
                     "900 River Road", "1234 Oak Street", "789 Pine Lane"] {
            let ms = SensitiveTextRules.combinedMatches(in: "Re: \(line) Refinance", additional: [])
            XCTAssertTrue(ms.contains { $0.category == .postalAddress && $0.text.contains(line) },
                          "missed street line: \(line)")
        }
    }

    func test_cityStateZip_evenFakeStateCode() {
        let ms = SensitiveTextRules.combinedMatches(in: "Springfield, ST 62704", additional: [])
        XCTAssertTrue(ms.contains { $0.category == .postalAddress })
    }

    func test_streetRule_noFalsePositiveOnProse() {
        let ms = SensitiveTextRules.combinedMatches(in: "take the 3 Easy Steps today",
                                                    additional: [])
        XCTAssertFalse(ms.contains { $0.category == .postalAddress })
    }

    func test_claimCenterDocIDLabels() {
        for (line, value) in [("Invoice #: INV-6228-23", "INV-6228-23"),
                              ("Work Order #: WO-6228-23", "WO-6228-23"),
                              ("Estimate Ref #: EST-6228-23", "EST-6228-23"),
                              ("Police Report #: FRM-23-04567", "FRM-23-04567")] {
            let ms = ContextualDetectors.matches(in: line)
            XCTAssertTrue(ms.contains { $0.category == .labeledField && $0.text == value },
                          "missed \(line)")
        }
    }

    func test_streetLoopSuffix() {
        let ms = SensitiveTextRules.combinedMatches(in: "601 Cedar Loop, Fairmont", additional: [])
        XCTAssertTrue(ms.contains { $0.category == .postalAddress && $0.text.contains("601 Cedar Loop") })
    }

    func test_repairInvoiceClassifiesFinancial() {
        let text = "REPAIR INVOICE Unit Price $450.00 Invoice Total $1,486.12"
        XCTAssertTrue(RedactionDocTypeClassifier.classify(text).contains(.financial))
    }

    func test_envelopeIDLabel() {
        let l = layout([
            ("Envelope ID",       0.70, 0.70, 0.08, 0.014),
            ("ENV-7XJH-4L2P-9Q8R", 0.70, 0.73, 0.13, 0.014),
        ])
        XCTAssertEqual(SmartRedactionAnalyzer.labeledValueDetections(in: l, tile: tile)
            .map(\.snippet), ["ENV-7XJH-4L2P-9Q8R"])
    }

    // MARK: - Ops-console secrets (corpus round 1)

    func test_envVarSecretAssignment() {
        // An `sk-` value is claimed by the higher-confidence key rule —
        // either category covering the value is a correct redaction.
        let ms = SensitiveTextRules.combinedMatches(
            in: "export LOG_UPLOAD_TOKEN=sk-test-redact-15e710c5fef4b1a638cad9dfd4bf",
            additional: [])
        XCTAssertTrue(ms.contains {
            ($0.category == .secretAssignment || $0.category == .openAIKey)
                && $0.text.contains("15e710c5fef4b1a638")
        })
        // A non-`sk` value must ride the env-var label itself.
        let plain = SensitiveTextRules.combinedMatches(
            in: "export DB_BACKUP_SECRET=q7mLp92xVt44", additional: [])
        XCTAssertTrue(plain.contains {
            $0.category == .secretAssignment && $0.text == "q7mLp92xVt44"
        })
    }

    func test_decoratedSecretLabel_capturesSplitToken() {
        let ms = SensitiveTextRules.combinedMatches(
            in: "credential (API key): sk-test-redact- bfe0614b9ad9456148ba9d2f41a4",
            additional: [])
        XCTAssertTrue(ms.contains {
            $0.category == .secretAssignment
                && $0.text == "sk-test-redact- bfe0614b9ad9456148ba9d2f41a4"
        }, "the OCR-split token continuation must ride along")
    }

    func test_signedURLQueryCredential() {
        let ms = SensitiveTextRules.combinedMatches(
            in: "link: https://files.example.com/share/15e710c5fef4b1a638?sig=cad9dfd4bf",
            additional: [])
        XCTAssertTrue(ms.contains { $0.category == .credentialedURL && $0.text == "cad9dfd4bf" })
    }

    func test_ticketLabel() {
        let ms = ContextualDetectors.matches(in: "internal ticket: PRIV-2939 / team-ops")
        XCTAssertTrue(ms.contains { $0.category == .labeledField && $0.text == "PRIV-2939 / team-ops" })
    }

    /// The label may sit inside a parenthetical qualifier.
    func test_parenWrappedLabel() {
        let ms = ContextualDetectors.matches(in: "org_context (internal ticket): PRIV-2939 / team-ops")
        XCTAssertTrue(ms.contains { $0.category == .labeledField && $0.text == "PRIV-2939 / team-ops" })
    }

    /// Secrets-manager form: "credential (API key)" labels the token field
    /// BELOW it; the form's next rows ("Status") must not be walked.
    func test_credentialFieldBelow_caught_noFormWalk() {
        let l = layout([
            ("credential (API key)",                          0.66, 0.74, 0.12, 0.014),
            ("sk-test-redact-edef0f5abb1a71dd469802a1902d",   0.66, 0.77, 0.20, 0.014),
            ("Status",                                        0.66, 0.80, 0.05, 0.014),
        ])
        let dets = SmartRedactionAnalyzer.labeledValueDetections(in: l, tile: tile)
        XCTAssertEqual(dets.map(\.snippet), ["sk-test-redact-edef0f5abb1a71dd469802a1902d"])
        XCTAssertEqual(dets.first?.customLabel, "credential")
    }

    /// Key/value secret row: "Secret | billing-integration-prod" — the
    /// digit-less value binds beside via the secret word-value stem.
    func test_secretKeyValueBeside() {
        let l = layout([
            ("Secret",                   0.66, 0.60, 0.05, 0.014),
            ("billing-integration-prod", 0.74, 0.60, 0.13, 0.014),
        ])
        XCTAssertEqual(SmartRedactionAnalyzer.labeledValueDetections(in: l, tile: tile)
            .map(\.snippet), ["billing-integration-prod"])
    }

    /// A bare "Account" heading over a Title-Case KEY column (ops panels)
    /// must not anchor geometry detection at all — only qualified forms
    /// ("Account #") do. The digit gate also ends any walk into key columns.
    func test_bareAccountHeading_doesNotCascade() {
        let l = layout([
            ("Account",        0.74, 0.40, 0.07, 0.015),
            ("Environment",    0.74, 0.43, 0.09, 0.015),
            ("Cluster",        0.74, 0.46, 0.06, 0.015),
            ("Namespace",      0.74, 0.49, 0.08, 0.015),
        ])
        XCTAssertTrue(SmartRedactionAnalyzer.labeledValueDetections(in: l, tile: tile).isEmpty)
    }

    /// Label-above-value GRID: the beside-neighbour is a sibling ALL-CAPS
    /// header, which must be vetoed so the label resolves downward to its
    /// real value.
    func test_grid_besideHeaderVetoed_belowValueWins() {
        let l = layout([
            ("ETHNICITY",       0.06, 0.10, 0.09, 0.015),
            ("LANGUAGE SPOKEN", 0.22, 0.10, 0.14, 0.015),
            ("Asian",           0.06, 0.13, 0.05, 0.015),
            ("English",         0.22, 0.13, 0.06, 0.015),
        ])
        let dets = SmartRedactionAnalyzer.labeledValueDetections(in: l, tile: tile)
        XCTAssertEqual(dets.map(\.snippet), ["Asian"])
        XCTAssertFalse(dets.contains { $0.snippet == "LANGUAGE SPOKEN" })
    }

    /// Key/value panel: the label's below-neighbour is the NEXT KEY — the
    /// value is beside. Beside must win, and the key column must not be
    /// walked as a value column.
    func test_keyValuePanel_besideWins_keyColumnNotWalked() {
        let l = layout([
            ("ticket",                 0.74, 0.70, 0.05, 0.015),
            ("PRIV-4410 / team-claims", 0.82, 0.70, 0.13, 0.015),
            ("record",                 0.74, 0.73, 0.05, 0.015),
            ("REC-6875-40",            0.82, 0.73, 0.09, 0.015),
            ("Annotations",            0.74, 0.76, 0.08, 0.015),
        ])
        let dets = SmartRedactionAnalyzer.labeledValueDetections(in: l, tile: tile)
        XCTAssertEqual(dets.map(\.snippet), ["PRIV-4410 / team-claims"])
    }

    // MARK: - Name-family labels + wide form gaps (corpus round 1)

    /// The medical template's value column starts ~25% of the page right of
    /// its labels — the beside bound must be width-relative, not line-height-
    /// relative, and a name value (no digit) must ride the name-label stem.
    func test_fullNameBesideLabel_wideFormGap() {
        let l = layout([
            ("Full Name:",    0.06, 0.10, 0.10, 0.012),
            ("Jasen Gaylord", 0.41, 0.10, 0.12, 0.012),
        ])
        XCTAssertEqual(SmartRedactionAnalyzer.labeledValueDetections(in: l, tile: tile)
            .map(\.snippet), ["Jasen Gaylord"])
    }

    // MARK: - Column-aware labeled values (a header labels its whole column)

    func test_columnHeader_catchesEveryCell() {
        let l = layout([
            ("Weight",    0.20, 0.10, 0.06, 0.02),
            ("10.20 lbs", 0.20, 0.13, 0.07, 0.02),
            ("8.60 lbs",  0.20, 0.16, 0.06, 0.02),
            ("8.60 lbs",  0.20, 0.19, 0.06, 0.02),
        ])
        let dets = SmartRedactionAnalyzer.labeledValueDetections(in: l, tile: tile)
        XCTAssertEqual(dets.map(\.snippet), ["10.20 lbs", "8.60 lbs", "8.60 lbs"])
    }

    /// The walk stops at a section break: a summary figure far below the
    /// table's row pitch is not part of the column.
    func test_columnWalk_stopsAtSectionGap() {
        let l = layout([
            ("Weight",    0.20, 0.10, 0.06, 0.02),
            ("10.20 lbs", 0.20, 0.13, 0.07, 0.02),
            ("8.60 lbs",  0.20, 0.16, 0.06, 0.02),
            ("27.40 lbs", 0.20, 0.40, 0.07, 0.02),   // totals row, far below
        ])
        let dets = SmartRedactionAnalyzer.labeledValueDetections(in: l, tile: tile)
        XCTAssertEqual(dets.map(\.snippet), ["10.20 lbs", "8.60 lbs"])
    }

    /// Compound headers: one short modifier word before the label anchors too
    /// ("Serial / Barcode", "RESTING HEART RATE").
    func test_compoundHeaders_prefixWordSkipped() {
        let serial = layout([
            ("Serial / Barcode", 0.10, 0.55, 0.10, 0.013),
            ("SN-4482-991",      0.10, 0.58, 0.08, 0.013),
        ])
        XCTAssertEqual(SmartRedactionAnalyzer.labeledValueDetections(in: serial, tile: tile)
            .map(\.snippet), ["SN-4482-991"])

        let heart = layout([
            ("RESTING HEART RATE", 0.50, 0.30, 0.12, 0.014),
            ("76 bpm",             0.50, 0.33, 0.05, 0.014),
        ])
        XCTAssertEqual(SmartRedactionAnalyzer.labeledValueDetections(in: heart, tile: tile)
            .map(\.snippet), ["76 bpm"])
    }

    /// "Tracking / Barcode" column header walks its whole barcode column.
    func test_trackingBarcodeColumnHeader() {
        let l = layout([
            ("Tracking / Barcode", 0.10, 0.55, 0.11, 0.013),
            ("PKG100987654321",    0.10, 0.58, 0.10, 0.013),
            ("PKG100987654322",    0.10, 0.61, 0.10, 0.013),
            ("PKG100987654323",    0.10, 0.64, 0.10, 0.013),
        ])
        let dets = SmartRedactionAnalyzer.labeledValueDetections(in: l, tile: tile)
        XCTAssertEqual(dets.map(\.snippet),
                       ["PKG100987654321", "PKG100987654322", "PKG100987654323"])
    }

    func test_trackingNumberLabel() {
        let ms = ContextualDetectors.matches(in: "Tracking #: SL1234567890")
        XCTAssertTrue(ms.contains { $0.category == .labeledField && $0.text == "SL1234567890" })
    }

    // MARK: - International phones, card fragments, travel labels

    func test_internationalPhone_matches() {
        let ms = SensitiveTextRules.combinedMatches(in: "Hotel: +33 1 42 60 09 16", additional: [])
        XCTAssertTrue(ms.contains { $0.category == .phone && $0.text == "+33 1 42 60 09 16" })
        let uk = SensitiveTextRules.combinedMatches(in: "Call +44 20 7946 0958 now", additional: [])
        XCTAssertTrue(uk.contains { $0.category == .phone })
    }

    func test_internationalPhone_rejectsShortAndVersions() {
        XCTAssertFalse(SensitiveTextRules.combinedMatches(in: "score +1 2 points", additional: [])
            .contains { $0.category == .phone })
        XCTAssertFalse(SensitiveTextRules.combinedMatches(in: "upgrade to +2.3.1 today", additional: [])
            .contains { $0.category == .phone })
    }

    func test_cardEndingIn_redactsLastFour() {
        let ms = SensitiveTextRules.combinedMatches(in: "Visa ending in 4242", additional: [])
        XCTAssertTrue(ms.contains { $0.category == .creditCard && $0.text == "4242" })
        XCTAssertFalse(SensitiveTextRules.combinedMatches(in: "meeting ending in 2024", additional: [])
            .contains { $0.category == .creditCard })
    }

    func test_bookingReferenceLabel() {
        let ms = ContextualDetectors.matches(in: "Booking Reference: BKG-7H2X9L")
        XCTAssertTrue(ms.contains { $0.category == .labeledField && $0.text == "BKG-7H2X9L" })
    }

    // MARK: - Word-value labels beside (digit gate exemption)

    func test_bloodTypeBesideLabel_wordValueAllowed() {
        let l = layout([
            ("Blood Type:", 0.06, 0.10, 0.10, 0.02),
            ("O+",          0.20, 0.10, 0.03, 0.02),
        ])
        let dets = SmartRedactionAnalyzer.labeledValueDetections(in: l, tile: tile)
        XCTAssertEqual(dets.map(\.snippet), ["O+"])
        XCTAssertEqual(dets.first?.customLabel, "blood type")
    }

    func test_relationshipBesideLabel() {
        let l = layout([
            ("Relationship:", 0.06, 0.10, 0.11, 0.02),
            ("Wife",          0.20, 0.10, 0.04, 0.02),
        ])
        XCTAssertEqual(SmartRedactionAnalyzer.labeledValueDetections(in: l, tile: tile)
            .map(\.snippet), ["Wife"])
    }

    /// Adjacent demographic column HEADERS must not read as label+value —
    /// a header is itself label-shaped and is rejected as a value.
    func test_wordValueLabels_headerBesideHeader_notAValue() {
        let l = layout([
            ("GENDER", 0.05, 0.10, 0.07, 0.02),
            ("RACE",   0.15, 0.10, 0.05, 0.02),
        ])
        XCTAssertTrue(SmartRedactionAnalyzer.labeledValueDetections(in: l, tile: tile).isEmpty)
    }

    // MARK: - Consolidation: repeated value keeps every occurrence's rect

    func test_sameValueTwoLocations_keepsBothRects() {
        let a = Detection(category: .phone, snippet: "(512) 555-0144", confidence: 0.9,
                          rects: [CGRect(x: 100, y: 100, width: 120, height: 20)],
                          customLabel: nil, reason: nil)
        let b = Detection(category: .phone, snippet: "(512) 555-0144", confidence: 0.9,
                          rects: [CGRect(x: 700, y: 900, width: 120, height: 20)],
                          customLabel: nil, reason: nil)
        let out = DetectionConsolidation.consolidate([a, b])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].rects.count, 2, "disjoint occurrence rects must all survive")
    }
}
