import XCTest
import PDFKit
@testable import Sealshot

final class RecoveryKitPDFTests: XCTestCase {
    private let fixedCode = "ABCDE-FGHIJ-KLMNO-PQRST-UVWXY"
    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    func testPDFHasMagicBytesPrefix() {
        let data = RecoveryKitPDF.make(code: fixedCode, generatedAt: fixedDate,
                                       macName: "Test Mac", licenseeLine: nil)
        let prefix = data.prefix(4)
        XCTAssertEqual(prefix, Data("%PDF".utf8))
    }

    func testExtractedTextContainsCodeAndRecoveryWord() throws {
        let data = RecoveryKitPDF.make(code: fixedCode, generatedAt: fixedDate,
                                       macName: "Test Mac", licenseeLine: nil)
        let document = try XCTUnwrap(PDFDocument(data: data))
        let text = try XCTUnwrap(document.string)
        XCTAssertTrue(text.contains(fixedCode), "Extracted text should contain the exact code")
        XCTAssertTrue(text.contains("Recovery"), "Extracted text should mention Recovery")
    }

    func testNilLicenseeLineWorks() throws {
        let data = RecoveryKitPDF.make(code: fixedCode, generatedAt: fixedDate,
                                       macName: "Test Mac", licenseeLine: nil)
        XCTAssertTrue(data.starts(with: Data("%PDF".utf8)))
        let document = try XCTUnwrap(PDFDocument(data: data))
        let text = try XCTUnwrap(document.string)
        XCTAssertTrue(text.contains(fixedCode))
    }

    func testLicenseeLineIncludedWhenPresent() throws {
        let data = RecoveryKitPDF.make(code: fixedCode, generatedAt: fixedDate,
                                       macName: "Test Mac",
                                       licenseeLine: "Licensed to Jane Doe (jane@example.com)")
        let document = try XCTUnwrap(PDFDocument(data: data))
        let text = try XCTUnwrap(document.string)
        XCTAssertTrue(text.contains("Jane Doe"))
        XCTAssertTrue(text.contains("jane@example.com"))
    }

    /// Brief requirement: "builder is deterministic for fixed inputs except
    /// dates". Raw bytes may legitimately differ (the PDF machinery stamps
    /// its own /CreationDate), so this compares extracted TEXT content
    /// instead — see the doc comment on `RecoveryKitPDF.make`.
    func testDeterministicTextContentForFixedInputs() throws {
        let first = RecoveryKitPDF.make(code: fixedCode, generatedAt: fixedDate,
                                        macName: "Test Mac",
                                        licenseeLine: "Licensed to Jane Doe (jane@example.com)")
        let second = RecoveryKitPDF.make(code: fixedCode, generatedAt: fixedDate,
                                         macName: "Test Mac",
                                         licenseeLine: "Licensed to Jane Doe (jane@example.com)")
        let firstText = try XCTUnwrap(PDFDocument(data: first)?.string)
        let secondText = try XCTUnwrap(PDFDocument(data: second)?.string)
        XCTAssertEqual(firstText, secondText)
    }

    /// Direct coverage of the CoreGraphics fallback path (`makeViaCoreGraphics`),
    /// which otherwise only runs when the primary NSHostingView path fails —
    /// a condition normal test runs can't reliably trigger. Held to the same
    /// bar as the primary path: `%PDF` prefix + extracted text contains the
    /// exact code and "Recovery".
    func testMakeViaCoreGraphicsFallbackDirectly() throws {
        let data = RecoveryKitPDF.makeViaCoreGraphics(code: fixedCode, generatedAt: fixedDate,
                                                       macName: "Test Mac", licenseeLine: nil)
        XCTAssertTrue(data.starts(with: Data("%PDF".utf8)))
        let document = try XCTUnwrap(PDFDocument(data: data))
        let text = try XCTUnwrap(document.string)
        XCTAssertTrue(text.contains(fixedCode), "Extracted text should contain the exact code")
        XCTAssertTrue(text.contains("Recovery"), "Extracted text should mention Recovery")
    }

    func testRendersRegardlessOfCodeLength() throws {
        let shortCode = "ABCDE"
        let longCode = "ABCDE-FGHIJ-KLMNO-PQRST-UVWXY-Z2345-6789A-BCDEF"
        for code in [shortCode, longCode] {
            let data = RecoveryKitPDF.make(code: code, generatedAt: fixedDate,
                                           macName: "Test Mac", licenseeLine: nil)
            XCTAssertTrue(data.starts(with: Data("%PDF".utf8)))
            let document = try XCTUnwrap(PDFDocument(data: data))
            let text = try XCTUnwrap(document.string)
            XCTAssertTrue(text.contains(code))
        }
    }
}
