import XCTest
@testable import Sealshot

final class SensitiveTextRulesTests: XCTestCase {

    private func categories(in text: String) -> [SensitiveCategory] {
        SensitiveTextRules.matches(in: text).map(\.category)
    }

    // MARK: - Email

    func testEmail_detected() {
        let matches = SensitiveTextRules.matches(in: "Contact: jane.doe+test@example.co.uk today")
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].category, .email)
        XCTAssertEqual(matches[0].text, "jane.doe+test@example.co.uk")
    }

    func testEmail_rangeIsCharacterOffsets() {
        let line = "a x@b.io z"
        let matches = SensitiveTextRules.matches(in: line)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].range, 2..<8)
        XCTAssertEqual(String(Array(line)[matches[0].range]), "x@b.io")
    }

    // MARK: - Phone

    func testPhone_commonUSFormats() {
        XCTAssertEqual(categories(in: "Call (555) 123-4567 now"), [.phone])
        XCTAssertEqual(categories(in: "+1 555.123.4567"), [.phone])
        XCTAssertEqual(categories(in: "555-123-4567"), [.phone])
    }

    func testPhone_shortNumberNotDetected() {
        XCTAssertEqual(categories(in: "room 123-45"), [])
    }

    // MARK: - Credit card

    func testCreditCard_luhnValidDetected() {
        let matches = SensitiveTextRules.matches(in: "Card: 4111 1111 1111 1111 exp 12/28")
        XCTAssertEqual(matches.map(\.category), [.creditCard])
        XCTAssertEqual(matches[0].text, "4111 1111 1111 1111")
    }

    func testCreditCard_luhnInvalidDetected() {
        // Favor recall: card-shaped numbers are redacted regardless of Luhn validity.
        XCTAssertEqual(categories(in: "Card: 4111 1111 1111 1112"), [.creditCard])
    }

    func testCreditCard_redactsCardShapedEvenIfNotLuhn() {
        // 5322 2596 2153 2368 is card-shaped but NOT Luhn-valid; favor recall.
        let cats = SensitiveTextRules.matches(in: "Card 5322 2596 2153 2368").map(\.category)
        XCTAssertTrue(cats.contains(.creditCard))
    }

    // MARK: - Secrets

    func testAWSAccessKey_detected() {
        XCTAssertEqual(categories(in: "key=AKIAIOSFODNN7EXAMPLE"), [.awsKey])
    }

    func testStripeKeys_liveAndTestDetected() {
        // Concatenated like the ghp_ fixture below, and for the same reason:
        // a fixture realistic enough to exercise the rule is realistic enough
        // to trip GitHub's push protection, which scans the SOURCE text. The
        // runtime string is unchanged. (The AWS fixture above is exempt — it
        // is Amazon's own documentation key, which scanners allowlist.)
        XCTAssertEqual(categories(in: "sk_live_" + "abcdefghijklmnopqrstuvwx"), [.stripeKey])
        XCTAssertEqual(categories(in: "pk_live_" + "abcdefghijklmnopqrstuvwx"), [.stripeKey])
        // Test keys are credentials too — catch them as well.
        XCTAssertEqual(categories(in: "sk_test_" + "abcdefghijklmnopqrstuvwx"), [.stripeKey])
    }

    func testGitHubTokens_detected() {
        XCTAssertEqual(categories(in: "ghp_" + String(repeating: "A1b2C3d4E5f6", count: 3)), [.githubToken])
        XCTAssertEqual(categories(in: "github_pat_" + String(repeating: "Ab1_", count: 20) + "Xy"), [.githubToken])
    }

    func testJWT_detected() {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVPmB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        XCTAssertEqual(categories(in: "Authorization: " + jwt), [.jwt])
    }

    func testBearerToken_detected() {
        XCTAssertEqual(categories(in: "Authorization: Bearer abcDEF1234567890_token-value"), [.bearerToken])
    }

    // MARK: - High entropy

    func testHighEntropy_randomTokenDetected() {
        // 32 distinct characters → Shannon entropy log2(32) = 5.0 bits/char.
        let token = "aB3xK9mQ7rT2wZ5vL8pD4hN6cF1gJ0sY"
        let matches = SensitiveTextRules.matches(in: "secret " + token)
        XCTAssertEqual(matches.map(\.category), [.highEntropy])
        XCTAssertEqual(matches[0].text, token)
    }

    func testHighEntropy_uuidAndGitShaNotDetected() {
        // Hex(+dash) alphabet caps entropy below the threshold by construction.
        XCTAssertEqual(categories(in: "id 550e8400-e29b-41d4-a716-446655440000"), [])
        XCTAssertEqual(categories(in: "commit 3f786850e387550fdab836ed7e6dc881de23001b"), [])
    }

    func testHighEntropy_proseNotDetected() {
        XCTAssertEqual(categories(in: "internationalization documentation"), [])
    }

    func testHighEntropy_suppressedWhenStrongerPatternOverlaps() {
        // A Stripe key is also a high-entropy token; only the stronger match survives.
        let cats = categories(in: "sk_live_" + "aB3xK9mQ7rT2wZ5vL8pD4hN6cF1g")
        XCTAssertEqual(cats, [.stripeKey])
    }

    // MARK: - Multiple matches

    func testMultipleMatches_orderedByLocation() {
        let matches = SensitiveTextRules.matches(in: "a@b.io then (555) 123-4567")
        XCTAssertEqual(matches.map(\.category), [.email, .phone])
        XCTAssertLessThan(matches[0].range.lowerBound, matches[1].range.lowerBound)
    }

    // MARK: - Display snippet

    func testDisplaySnippet_secretsTruncated_shortTextKept() {
        XCTAssertEqual(SensitiveTextRules.displaySnippet(for: "sk_live_" + "abcdefghijklmnopqrstuvwx"),
                       "sk_live_…uvwx")
        XCTAssertEqual(SensitiveTextRules.displaySnippet(for: "a@b.io"), "a@b.io")
    }

    // MARK: - Confidence

    func testConfidence_strongPatternsHigherThanEntropy() {
        XCTAssertGreaterThan(SensitiveCategory.stripeKey.baseConfidence,
                             SensitiveCategory.highEntropy.baseConfidence)
        XCTAssertGreaterThan(SensitiveCategory.email.baseConfidence,
                             SensitiveCategory.phone.baseConfidence)
    }

    // MARK: - New cloud / API secrets

    func testCloudSecretPrefixes_detected() {
        XCTAssertEqual(categories(in: "k AIza" + String(repeating: "a", count: 35)), [.googleApiKey])
        XCTAssertEqual(categories(in: "glpat-" + String(repeating: "a", count: 20)), [.gitlabToken])
        XCTAssertEqual(categories(in: "xoxb-123456789012-aaaaaa"), [.slackToken])
        XCTAssertEqual(categories(in: "AC" + String(repeating: "a", count: 32)), [.twilioKey])
        XCTAssertEqual(categories(in: "SG." + String(repeating: "a", count: 22)
                                       + "." + String(repeating: "b", count: 43)), [.sendgridKey])
    }

    func testOpenAIAndAnthropicKeys_anthropicWinsOnOverlap() {
        XCTAssertEqual(categories(in: "sk-" + String(repeating: "z", count: 25)), [.openAIKey])
        // `sk-ant-…` also satisfies the looser OpenAI `sk-…`; the higher-
        // confidence anthropic match must win via overlap resolution.
        XCTAssertEqual(categories(in: "sk-ant-" + String(repeating: "z", count: 24)), [.anthropicKey])
    }

    func testPrivateKeyBlock_detected() {
        XCTAssertEqual(categories(in: "-----BEGIN RSA PRIVATE KEY-----"), [.privateKeyBlock])
        XCTAssertEqual(categories(in: "-----BEGIN PRIVATE KEY-----"), [.privateKeyBlock])
    }

    func testCredentialedURL_winsOverEmailInside() {
        // The embedded `secretpass@db.example.com` looks like an email, but the
        // whole credentialed URI is the right thing to redact (one row).
        XCTAssertEqual(categories(in: "DSN postgres://user:secretpass@db.example.com:5432/app"),
                       [.credentialedURL])
    }

    // MARK: - Financial

    func testIBAN_validChecksum_invalidIgnored() {
        XCTAssertEqual(categories(in: "IBAN GB82WEST12345698765432 ok"), [.iban])
        XCTAssertFalse(categories(in: "GB00WEST12345698765432").contains(.iban))
    }

    func testRoutingNumber_validChecksum_invalidIgnored() {
        XCTAssertEqual(categories(in: "ABA 021000021 ok"), [.routingNumber])
        XCTAssertFalse(categories(in: "num 123456789").contains(.routingNumber))
    }

    func testCryptoWallets_detected() {
        XCTAssertEqual(categories(in: "eth 0x" + String(repeating: "a", count: 40)), [.cryptoWallet])
        XCTAssertEqual(categories(in: "btc 1" + String(repeating: "a", count: 33)), [.cryptoWallet])
    }

    // MARK: - Network

    func testIPv4_validDetected_outOfRangeIgnored() {
        XCTAssertEqual(categories(in: "ip 192.168.1.1"), [.ipAddress])
        XCTAssertFalse(categories(in: "ver 256.1.1.1").contains(.ipAddress))
    }

    func testIPv6_detected_timeIgnored() {
        XCTAssertEqual(categories(in: "addr 2001:0db8:85a3:0000:0000:8a2e:0370:7334"), [.ipAddress])
        XCTAssertFalse(categories(in: "at 12:34:56 today").contains(.ipAddress))
    }

    func testMAC_detected() {
        XCTAssertEqual(categories(in: "hw 00:1A:2B:3C:4D:5E"), [.macAddress])
    }

    // MARK: - Contextual

    func testSSN_validFormat_badAreaAndBareDigitsIgnored() {
        XCTAssertEqual(categories(in: "SSN 123-45-6789"), [.ssn])
        XCTAssertFalse(categories(in: "000-12-3456").contains(.ssn))
        XCTAssertFalse(categories(in: "666-12-3456").contains(.ssn))
        XCTAssertFalse(categories(in: "id 123456789").contains(.ssn))
    }

    func testSecretAssignment_redactsValueOnly() {
        let line = "password = hunter2secret"
        let matches = SensitiveTextRules.matches(in: line)
        XCTAssertEqual(matches.map(\.category), [.secretAssignment])
        // Only the VALUE is reported/redacted, not the `password =` label.
        XCTAssertEqual(matches[0].text, "hunter2secret")
        XCTAssertEqual(String(Array(line)[matches[0].range]), "hunter2secret")
    }

    func testSecretAssignment_namedKeyValueWinsOverGenericAssignment() {
        // `api_key: <google key>` — the specific googleApiKey match should win
        // over the generic secretAssignment value covering the same pixels.
        XCTAssertEqual(categories(in: "api_key: AIza" + String(repeating: "a", count: 35)),
                       [.googleApiKey])
    }

    // MARK: - Overlap resolution

    func testOverlap_disjointSecretsBothKept() {
        XCTAssertEqual(Set(categories(in: "mail a@b.io ip 192.168.0.1")),
                       Set([.email, .ipAddress]))
    }

    func testCombined_labeledFieldValueWinsOverPersonNameInside() {
        // The regex set + semantic detectors are resolved across the union, so a
        // labeledField value swallows any NER personName found inside it.
        let line = "Patient: Jane Q Public"
        let semantic = ContextualDetectors.matches(in: line)
        let cats = SensitiveTextRules.combinedMatches(in: line, additional: semantic).map(\.category)
        XCTAssertTrue(cats.contains(.labeledField))
        XCTAssertFalse(cats.contains(.personName))
    }

    func testCombined_emptyAdditional_matchesRegexOnlyBehavior() {
        let line = "DSN postgres://user:secretpass@db.example.com:5432/app"
        XCTAssertEqual(SensitiveTextRules.combinedMatches(in: line, additional: []).map(\.category),
                       SensitiveTextRules.matches(in: line).map(\.category))
    }

    // MARK: - Display names

    func testEveryCategoryHasDisplayName() {
        for category in SensitiveCategory.allCases {
            XCTAssertFalse(category.displayName.isEmpty, "\(category) is missing a displayName")
        }
    }

    // MARK: - Passport MRZ

    func testMRZ_detectsBothPassportLines() {
        XCTAssertEqual(categories(in: "P<CANMARTIN<<SARAH<<<<<<<<<<<<<<<<<<<<<<<<<<<"),
                       [.machineReadableZone])
        XCTAssertEqual(categories(in: "ZE000509<9CAN8501019F2301147<<<<<<<<<<<<<<08"),
                       [.machineReadableZone])
    }

    func testMRZ_ignoresOrdinaryText() {
        // No `<<` filler → not an MRZ line, regardless of length or case.
        XCTAssertFalse(categories(in: "TEDDY FAB INC. BALANCE SHEET").contains(.machineReadableZone))
        XCTAssertFalse(categories(in: "CANADIAN/CANADIENNE").contains(.machineReadableZone))
        XCTAssertFalse(categories(in: "ABCDEFGHIJKLMNOPQRSTUVWXYZ012345").contains(.machineReadableZone))
    }
}
