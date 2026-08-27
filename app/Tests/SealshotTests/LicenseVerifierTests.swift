import XCTest
import CryptoKit
@testable import Sealshot

final class LicenseVerifierTests: XCTestCase {
    let primary = Curve25519.Signing.PrivateKey()
    let standby = Curve25519.Signing.PrivateKey()
    var verifier: LicenseVerifier { .init(publicKeys: [1: primary.publicKey, 2: standby.publicKey]) }

    // MARK: - envelope-level verify(_:) — signature correctness only

    func test_verify_valid_returnsPayload() throws {
        let lic = try LicenseFormatTests.makeSigned(key: primary)
        let payload = try verifier.verify(lic)
        XCTAssertEqual(payload.email, "jane@x.com")
    }

    func test_verify_standbyKey_accepted() throws {
        let lic = try LicenseFormatTests.makeSigned(key: standby, keyID: 2)
        XCTAssertNoThrow(try verifier.verify(lic))
    }

    func test_verify_wrongKey_tamperedPayload_unknownKeyID_allRejected() throws {
        let stranger = try LicenseFormatTests.makeSigned(key: .init())          // signed by nobody we trust
        XCTAssertThrowsError(try verifier.verify(stranger))

        let good = try LicenseFormatTests.makeSigned(key: primary)
        var payloadData = Data(base64Encoded: good.payload)!
        payloadData[payloadData.count / 2] ^= 0xFF                              // flip a byte
        let tampered = SignedLicense(v: 1, key: 1, payload: payloadData.base64EncodedString(), sig: good.sig)
        XCTAssertThrowsError(try verifier.verify(tampered))

        let unknownKey = try LicenseFormatTests.makeSigned(key: primary, keyID: 9)
        XCTAssertThrowsError(try verifier.verify(unknownKey))
    }

    func test_productionKeys_parse() {
        // Catches an unreplaced sentinel in LicenseKeys.swift.
        XCTAssertEqual(LicenseKeys.production.count, 2)
    }

    // MARK: - whole-file verify(fileText:)

    func test_verifyFileText_valid_returnsPayload() throws {
        let file = try LicenseFormatTests.makeLicenseFile(key: primary)
        let payload = try verifier.verify(fileText: file)
        XCTAssertEqual(payload.name, "Jane Doe")
        XCTAssertEqual(payload.email, "jane@x.com")
    }

    func test_verifyFileText_editedFieldLine_textTampered() throws {
        let file = try LicenseFormatTests.makeLicenseFile(key: primary, name: "Jane Doe")
        // Change one letter of the name in the preamble (payload still says "Jane Doe").
        let tampered = file.replacingOccurrences(of: "Licensed to:      Jane Doe",
                                                  with: "Licensed to:      Jate Doe")
        XCTAssertNotEqual(tampered, file)
        XCTAssertThrowsError(try verifier.verify(fileText: tampered)) { error in
            XCTAssertEqual(error as? LicenseError, .textTampered)
        }
    }

    func test_verifyFileText_editedProseLine_textTampered() throws {
        let file = try LicenseFormatTests.makeLicenseFile(key: primary)
        let tampered = file.replacingOccurrences(of: "Keep this file exactly as received.",
                                                  with: "Keep this file roughly as received.")
        XCTAssertNotEqual(tampered, file)
        XCTAssertThrowsError(try verifier.verify(fileText: tampered)) { error in
            XCTAssertEqual(error as? LicenseError, .textTampered)
        }
    }

    func test_verifyFileText_benignTransportMutations_stillValid() throws {
        let file = try LicenseFormatTests.makeLicenseFile(key: primary)
        let payload = try verifier.verify(fileText: file)

        let crlf = file.replacingOccurrences(of: "\n", with: "\r\n")
        XCTAssertEqual(try verifier.verify(fileText: crlf), payload)

        let extraTrailingNewlines = file + "\n\n\n"
        XCTAssertEqual(try verifier.verify(fileText: extraTrailingNewlines), payload)

        let trailingSpaces = file.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0 + "   " }.joined(separator: "\n")
        XCTAssertEqual(try verifier.verify(fileText: trailingSpaces), payload)
    }

    func test_verifyFileText_NFDDecomposedAccentedName_stillValid() throws {
        // "José" — NFC in the freshly-built file, decomposed (NFD) on disk
        // (e.g. some editors / filesystems re-save this way).
        let file = try LicenseFormatTests.makeLicenseFile(key: primary, name: "Jos\u{E9} Ortiz")
        let decomposed = file.decomposedStringWithCanonicalMapping
        let payload = try verifier.verify(fileText: decomposed)
        XCTAssertEqual(payload.name, "Jos\u{E9} Ortiz")
    }

    func test_verifyFileText_issueTimeHash_trailingSpaceInName_valid() throws {
        // Reproduces reviewer finding: a name with trailing whitespace makes
        // the built preamble's "Licensed to:" line end in whitespace. If
        // issue-time hashing doesn't canonicalize first (matching what
        // verify() does), the trailing space gets trimmed away only on the
        // verify side and the hash mismatches.
        let file = try LicenseFormatTests.makeLicenseFile(key: primary, name: "Trailing Space ")
        XCTAssertNoThrow(try verifier.verify(fileText: file))
    }

    func test_verifyFileText_issueTimeHash_NFDDecomposedName_valid() throws {
        // Reproduces reviewer finding: an NFD-decomposed name (e.g. from an
        // input method that doesn't precompose) must still verify — the
        // issue-time hash has to canonicalize (NFC-normalize) before
        // hashing, same as verify() does.
        let name = "Jose\u{0301} Ortiz".decomposedStringWithCanonicalMapping
        let file = try LicenseFormatTests.makeLicenseFile(key: primary, name: name)
        XCTAssertNoThrow(try verifier.verify(fileText: file))
    }

    func test_verifyFileText_nonBlankContentAfterBlob_rejected() throws {
        // Reproduces reviewer finding: content appended after the blob line
        // must invalidate the file rather than being silently ignored.
        let file = try LicenseFormatTests.makeLicenseFile(key: primary)
        let tampered = file + "extra appended content\n"
        XCTAssertThrowsError(try verifier.verify(fileText: tampered)) { error in
            XCTAssertEqual(error as? LicenseError, .malformed)
        }
    }

    func test_verifyFileText_bareBlob_rejected() throws {
        let envelope = try LicenseFormatTests.makeSigned(key: primary)
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        let bareBlob = "SEALSHOT1." + (try enc.encode(envelope)).base64EncodedString()
        XCTAssertThrowsError(try verifier.verify(fileText: bareBlob)) { error in
            XCTAssertEqual(error as? LicenseError, .malformed)
        }
    }

    func test_verifyFileText_bareEnvelopeJSON_rejected() throws {
        let envelope = try LicenseFormatTests.makeSigned(key: primary)
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        let bareJSON = String(data: try enc.encode(envelope), encoding: .utf8)!
        XCTAssertThrowsError(try verifier.verify(fileText: bareJSON)) { error in
            XCTAssertEqual(error as? LicenseError, .malformed)
        }
    }

    func test_verifyFileText_payloadMissingTextHash_rejected() throws {
        // Hand-build an old-style payload JSON that omits "textHash" — the
        // synthesized Decodable requires the key, so decoding fails.
        let id = UUID()
        let oldStylePayloadJSON = """
        {"edition":"pro","email":"jane@x.com","id":"\(id.uuidString)","issued":"2026-07-17",\
        "name":"Jane Doe","seats":1,"updatesThrough":"2027-07-17"}
        """
        let payloadData = Data(oldStylePayloadJSON.utf8)
        let sig = try primary.signature(for: payloadData)
        let lic = SignedLicense(v: 1, key: 1, payload: payloadData.base64EncodedString(),
                                sig: sig.base64EncodedString())
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        let envelopeJSON = try enc.encode(lic)
        let preamble = LicenseFileFormat.buildPreamble(name: "Jane Doe", email: "jane@x.com", id: id,
                                                        issued: "2026-07-17", updatesThrough: "2027-07-17", seats: 1,
                                                        licenseType: .individual)
        let file = preamble + "\n\n" + LicenseFileFormat.blobPrefix + envelopeJSON.base64EncodedString() + "\n"
        XCTAssertThrowsError(try verifier.verify(fileText: file)) { error in
            XCTAssertEqual(error as? LicenseError, .malformed)
        }
    }

    func test_verifyFileText_tamperedBlobWithIntactPreamble_badSignature() throws {
        // Same shape as test_verify_wrongKey_tamperedPayload_...: sign the
        // real payload bytes, then flip a byte AFTER signing and embed the
        // tampered bytes — preamble/hash are untouched, only the signed
        // blob is corrupted, so signature verification fails first (before
        // textHash is ever compared).
        let name = "Jane Doe", email = "jane@x.com"
        let id = UUID()
        let issued = "2026-07-17", updatesThrough = "2027-07-17"
        let preamble = LicenseFileFormat.buildPreamble(name: name, email: email, id: id, issued: issued,
                                                        updatesThrough: updatesThrough, seats: 1,
                                                        licenseType: .individual)
        let hash = LicenseFileFormat.textHash(preamble: preamble)
        let payload = LicensePayload(id: id, name: name, email: email, licenseType: .individual, issued: issued,
                                     updatesThrough: updatesThrough, seats: 1, textHash: hash)
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        var payloadData = try enc.encode(payload)
        let sig = try primary.signature(for: payloadData)   // sign the real bytes
        payloadData[payloadData.count / 2] ^= 0xFF           // then corrupt what we ship
        let lic = SignedLicense(v: 1, key: 1, payload: payloadData.base64EncodedString(),
                                sig: sig.base64EncodedString())
        let envelopeJSON = try enc.encode(lic)
        let file = preamble + "\n\n" + LicenseFileFormat.blobPrefix + envelopeJSON.base64EncodedString() + "\n"
        XCTAssertThrowsError(try verifier.verify(fileText: file)) { error in
            XCTAssertEqual(error as? LicenseError, .badSignature)
        }
    }
}
