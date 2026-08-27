import XCTest
import CryptoKit
@testable import Sealshot

final class LicenseFormatTests: XCTestCase {
    /// Envelope-only signer — used by tests that only care about signature
    /// correctness (LicenseVerifierTests' `verify(_:)` cases). Real license
    /// files also need a preamble + textHash; see `makeLicenseFile` below.
    static func makeSigned(key: Curve25519.Signing.PrivateKey,
                           keyID: Int = 1,
                           updatesThrough: String = "2027-07-17") throws -> SignedLicense {
        let payload = LicensePayload(id: UUID(), name: "Jane Doe", email: "jane@x.com",
                                     licenseType: .individual, issued: "2026-07-17",
                                     updatesThrough: updatesThrough, seats: 1)
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        let data = try enc.encode(payload)
        let sig = try key.signature(for: data)
        return SignedLicense(v: 1, key: keyID, payload: data.base64EncodedString(),
                             sig: sig.base64EncodedString())
    }

    /// Builds a complete, correctly-hashed-and-signed `.sealshotlicense`
    /// file: preamble → textHash → payload → sign → compose. Mirrors what
    /// licensegen's `issue` does.
    static func makeLicenseFile(key: Curve25519.Signing.PrivateKey,
                                keyID: Int = 1,
                                name: String = "Jane Doe",
                                email: String = "jane@x.com",
                                id: UUID = UUID(),
                                issued: String = "2026-07-17",
                                updatesThrough: String = "2027-07-17",
                                seats: Int = 1,
                                licenseType: LicenseType = .individual) throws -> String {
        let preamble = LicenseFileFormat.buildPreamble(name: name, email: email, id: id,
                                                        issued: issued, updatesThrough: updatesThrough,
                                                        seats: seats, licenseType: licenseType)
        // Hash the CANONICALIZED preamble, matching what verify() compares
        // against — mirrors the fix to licensegen's `issue` command. Hashing
        // the raw (as-built) preamble here would mint files that immediately
        // fail verification whenever a field value needs canonicalizing
        // (trailing whitespace, NFD-decomposed characters).
        let hash = LicenseFileFormat.textHash(preamble: LicenseFileFormat.canonicalize(preamble))
        let payload = LicensePayload(id: id, name: name, email: email, licenseType: licenseType,
                                     issued: issued, updatesThrough: updatesThrough, seats: seats,
                                     textHash: hash)
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        let payloadData = try enc.encode(payload)
        let sig = try key.signature(for: payloadData)
        let lic = SignedLicense(v: 1, key: keyID, payload: payloadData.base64EncodedString(),
                                sig: sig.base64EncodedString())
        let envelopeJSON = try enc.encode(lic)
        return preamble + "\n\n" + LicenseFileFormat.blobPrefix + envelopeJSON.base64EncodedString() + "\n"
    }

    // MARK: - canonicalize

    func test_canonicalize_stripsBOM_normalizesLineEndings_trimsTrailingWhitespace() {
        // Trailing "\t\n" is itself a blank final line — canonicalize trims
        // per-line trailing whitespace but does NOT drop blank lines (that's
        // splitPreambleAndBlob's job, scoped to the preamble only), so the
        // trailing blank line survives as an empty line.
        let text = "\u{FEFF}line one  \r\nline two\r\r\nline three\t\n"
        let canonical = LicenseFileFormat.canonicalize(text)
        XCTAssertEqual(canonical, "line one\nline two\n\nline three\n")
    }

    func test_canonicalize_normalizesToNFC() {
        // "é" as decomposed e + combining acute (NFD) canonicalizes to the
        // single precomposed NFC codepoint.
        let decomposed = "Jos\u{65}\u{0301}"
        let canonical = LicenseFileFormat.canonicalize(decomposed)
        XCTAssertEqual(canonical, "Jos\u{E9}")
    }

    // MARK: - splitPreambleAndBlob

    func test_splitPreambleAndBlob_findsPreambleAndBlob() throws {
        let file = try Self.makeLicenseFile(key: .init())
        let canonical = LicenseFileFormat.canonicalize(file)
        let parts = try XCTUnwrap(LicenseFileFormat.splitPreambleAndBlob(canonical))
        XCTAssertTrue(parts.preamble.hasPrefix("Sealshot License"))
        XCTAssertFalse(parts.preamble.contains("SEALSHOT1."))
        XCTAssertFalse(parts.blobBase64.isEmpty)
    }

    func test_splitPreambleAndBlob_dropsTrailingBlankLinesOfPreamble() {
        let canonical = "Sealshot License\nbody\n\n\nSEALSHOT1.abc"
        let parts = LicenseFileFormat.splitPreambleAndBlob(canonical)
        XCTAssertEqual(parts?.preamble, "Sealshot License\nbody")
    }

    func test_splitPreambleAndBlob_bareBlob_noPreamble_rejected() {
        XCTAssertNil(LicenseFileFormat.splitPreambleAndBlob("SEALSHOT1.abc"))
        XCTAssertNil(LicenseFileFormat.splitPreambleAndBlob("\n\nSEALSHOT1.abc"))
    }

    func test_splitPreambleAndBlob_noBlobLine_rejected() {
        XCTAssertNil(LicenseFileFormat.splitPreambleAndBlob("just some text\nno blob here"))
    }

    func test_splitPreambleAndBlob_nonBlankLineAfterBlob_rejected() {
        let canonical = "Sealshot License\nbody\n\nSEALSHOT1.abc\nextra garbage"
        XCTAssertNil(LicenseFileFormat.splitPreambleAndBlob(canonical))
    }

    func test_splitPreambleAndBlob_blankLinesAfterBlob_stillAccepted() {
        let canonical = "Sealshot License\nbody\n\nSEALSHOT1.abc\n\n\n"
        let parts = LicenseFileFormat.splitPreambleAndBlob(canonical)
        XCTAssertEqual(parts?.blobBase64, "abc")
    }

    // MARK: - textHash

    func test_textHash_deterministic_andSensitiveToContent() {
        let a = LicenseFileFormat.textHash(preamble: "hello")
        let b = LicenseFileFormat.textHash(preamble: "hello")
        let c = LicenseFileFormat.textHash(preamble: "hellp")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    // MARK: - LicensePayload

    func test_updatesThroughDate_parses_UTC_dayString() throws {
        let payload = LicensePayload(id: UUID(), name: "n", email: "e", licenseType: .individual,
                                     issued: "2026-07-17", updatesThrough: "2027-01-05", seats: 1)
        let date = try XCTUnwrap(payload.updatesThroughDate)
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day], from: date)
        XCTAssertEqual([c.year, c.month, c.day], [2027, 1, 5])
        XCTAssertNil(LicensePayload(id: UUID(), name: "n", email: "e", licenseType: .individual,
                                    issued: "x", updatesThrough: "garbage", seats: 1).updatesThroughDate)
    }

    func test_utcDay_parsesValidDay_rejectsEverythingElse() {
        let d = UTCDay.parse("2026-07-17")
        XCTAssertNotNil(d)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day], from: d!)
        XCTAssertEqual([c.year, c.month, c.day], [2026, 7, 17])

        XCTAssertNil(UTCDay.parse(""))
        XCTAssertNil(UTCDay.parse("garbage"))
        XCTAssertNil(UTCDay.parse("07/17/2026"))
    }

    // MARK: - LicenseType

    func test_licenseTypeRawValuesAreTheWireFormat() {
        XCTAssertEqual(LicenseType.individual.rawValue, "individual")
        XCTAssertEqual(LicenseType.businessVolume.rawValue, "business-volume")
    }

    func test_licenseTypeLabelsAreDisplayStrings() {
        XCTAssertEqual(LicenseType.individual.label, "Individual")
        XCTAssertEqual(LicenseType.businessVolume.label, "Business Volume")
    }

    func test_payloadRoundTripsLicenseType() throws {
        let payload = LicensePayload(id: UUID(), name: "Jane Doe", email: "jane@example.com",
                                     licenseType: .businessVolume, issued: "2026-07-20",
                                     updatesThrough: "2027-07-20", seats: 10, textHash: "h")
        let data = try JSONEncoder().encode(payload)
        XCTAssertEqual(try JSONDecoder().decode(LicensePayload.self, from: data), payload)
        XCTAssertTrue(String(data: data, encoding: .utf8)!.contains("\"business-volume\""))
    }

    func test_payloadRejectsUnknownLicenseType() {
        let json = "{\"id\":\"550E8400-E29B-41D4-A716-446655440000\",\"name\":\"J\",\"email\":\"e\",\"licenseType\":\"enterprise\",\"issued\":\"2026-07-20\",\"updatesThrough\":\"2027-07-20\",\"seats\":1,\"textHash\":\"h\"}"
        XCTAssertNil(try? JSONDecoder().decode(LicensePayload.self, from: Data(json.utf8)))
    }

    // MARK: - buildPreamble (v1.0 pricing doc template)

    func test_individualPreambleMatchesV1Document() {
        let out = LicenseFileFormat.buildPreamble(
            name: "Jane Doe", email: "jane@example.com",
            id: UUID(uuidString: "550E8400-E29B-41D4-A716-446655440000")!,
            issued: "2026-07-20", updatesThrough: "2027-07-20", seats: 1,
            licenseType: .individual)
        let expected = [
            "Sealshot License",
            "================",
            "Licensed to:      Jane Doe",
            "Email:            jane@example.com",
            "License ID:       550E8400-E29B-41D4-A716-446655440000",
            "License type:     Individual",
            "License issued:   2026-07-20",
            "App access:       Perpetual",
            "Updates through:  2027-07-20",
            "Users:            1",
            "Macs per user:    3",
            "",
            "This license does not expire. It permits use of every Sealshot",
            "release whose entitlement date is on or before 2027-07-20.",
            "",
            "Keep this file exactly as received. The information above is",
            "cryptographically signed; modifying it invalidates the license.",
        ].joined(separator: "\n")
        XCTAssertEqual(out, expected)
    }

    func test_businessVolumePreambleMatchesV1Document() {
        let out = LicenseFileFormat.buildPreamble(
            name: "Acme, Inc.", email: "software@acme.example",
            id: UUID(uuidString: "946C87B1-C2D7-46E9-B8CF-D88EB86532EE")!,
            issued: "2027-08-01", updatesThrough: "2028-09-15", seats: 10,
            licenseType: .businessVolume)
        let expected = [
            "Sealshot License",
            "================",
            "Licensed to:      Acme, Inc.",
            "Purchaser email:  software@acme.example",
            "License ID:       946C87B1-C2D7-46E9-B8CF-D88EB86532EE",
            "License type:     Business Volume",
            "License issued:   2027-08-01",
            "App access:       Perpetual",
            "Updates through:  2028-09-15",
            "User seats:       10",
            "Macs per user:    3",
            "",
            "This is an offline, organization-wide license for up to 10 users.",
            "Sealshot does not transmit installation or usage information.",
        ].joined(separator: "\n")
        XCTAssertEqual(out, expected)
    }

    /// Guards against the app's template drifting from the shared golden
    /// fixture that also backs the Worker and licensegen implementations.
    /// This is deliberately independent of `test_individualPreambleMatchesV1Document`:
    /// that inline test catches a bad edit to this file; this one catches
    /// the three implementations diverging from each other.
    func test_preambleMatchesSharedGoldenFixture() throws {
        let url = Bundle(for: type(of: self)).url(forResource: "golden-preamble-v2",
                                                  withExtension: "txt")
        let fixture = try String(contentsOf: try XCTUnwrap(url), encoding: .utf8)
            .trimmingCharacters(in: .newlines)
        let built = LicenseFileFormat.buildPreamble(
            name: "Jane Doe", email: "jane@example.com",
            id: UUID(uuidString: "550E8400-E29B-41D4-A716-446655440000")!,
            issued: "2026-07-20", updatesThrough: "2027-07-20", seats: 1,
            licenseType: .individual)
        XCTAssertEqual(built, fixture,
                       "app template drifted from the shared fixture — the Worker and "
                       + "licensegen copies must be updated in the same change")
    }

    /// A permanent license carries an EMPTY updatesThrough — every gate reads
    /// the field through `UTCDay.parse` and treats an unparseable value as "no
    /// limit", so blank means unlimited on builds already shipped. The label has
    /// to change with it: "Updates through:" followed by nothing reads as a
    /// missing field on the one document the customer keeps.
    func test_permanentPreambleMatchesSharedGoldenFixture() throws {
        let url = Bundle(for: type(of: self)).url(forResource: "golden-preamble-v2-permanent",
                                                  withExtension: "txt")
        let fixture = try String(contentsOf: try XCTUnwrap(url), encoding: .utf8)
            .trimmingCharacters(in: .newlines)
        let built = LicenseFileFormat.buildPreamble(
            name: "Jane Doe", email: "jane@example.com",
            id: UUID(uuidString: "550E8400-E29B-41D4-A716-446655440000")!,
            issued: "2026-08-26", updatesThrough: "", seats: 1,
            licenseType: .individual)
        XCTAssertEqual(built, fixture,
                       "app template drifted from the shared fixture — the Worker and "
                       + "licensegen copies must be updated in the same change")
    }

    /// The failure this guards: editing one of the two conditionals and not the
    /// other, which ships "on or before ." to a paying customer.
    func test_permanentPreambleLeavesNoDanglingDate() {
        let out = LicenseFileFormat.buildPreamble(
            name: "X", email: "y@z", id: UUID(), issued: "2026-08-26",
            updatesThrough: "", seats: 1, licenseType: .individual)
        XCTAssertFalse(out.contains("on or before"))
        XCTAssertFalse(out.contains("Updates through"))
    }

    /// A permanent license must verify end to end, not merely render: the
    /// preamble is hashed into the signed payload, so a template change that
    /// only one side made would fail activation as `textTampered`.
    func test_permanentLicenseFileVerifies() throws {
        let key = Curve25519.Signing.PrivateKey()
        let file = try Self.makeLicenseFile(key: key, updatesThrough: "")
        let payload = try LicenseVerifier(publicKeys: [1: key.publicKey]).verify(fileText: file)
        XCTAssertEqual(payload.updatesThrough, "")
        XCTAssertNil(payload.updatesThroughDate, "blank must not parse to a date")
        XCTAssertTrue(UpdatePolicy.allowsUpdate(publishedAt: UTCDay.parse("2099-01-01"),
                                                state: .licensed(payload)),
                      "a permanent license covers every future release")
        XCTAssertTrue(UpdatePolicy.coversRunningBuild(buildReleasedAt: UTCDay.parse("2099-01-01"),
                                                      payload: payload))
    }

    func test_everyLabelPadsToEighteenColumns() {
        let out = LicenseFileFormat.buildPreamble(
            name: "X", email: "y@z", id: UUID(), issued: "2026-01-01",
            updatesThrough: "2027-01-01", seats: 1, licenseType: .individual)
        for line in out.components(separatedBy: "\n") where line.contains(":") && !line.hasPrefix("=") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let valueStart = line.distance(from: line.startIndex, to: colon) + 1
            guard valueStart < 18 else { continue }
            XCTAssertEqual(line.prefix(18).trimmingCharacters(in: .whitespaces).count,
                           valueStart, "label column must be 18 in: \(line)")
        }
    }
}
