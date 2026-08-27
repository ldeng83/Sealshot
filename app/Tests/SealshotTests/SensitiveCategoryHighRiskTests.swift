import XCTest
@testable import Sealshot

final class SensitiveCategoryHighRiskTests: XCTestCase {
    func test_highRisk_trueForCatastrophicLeak() {
        for c in [SensitiveCategory.creditCard, .iban, .routingNumber, .cryptoWallet, .ssn,
                  .awsKey, .stripeKey, .githubToken, .gitlabToken, .googleApiKey, .slackToken,
                  .openAIKey, .anthropicKey, .sendgridKey, .twilioKey, .jwt, .bearerToken,
                  .privateKeyBlock, .credentialedURL, .secretAssignment, .machineReadableZone,
                  .email, .phone, .postalAddress] {
            XCTAssertTrue(c.isHighRisk, "\(c) should be high-risk")
        }
    }
    func test_highRisk_falseForLowerStakes() {
        for c in [SensitiveCategory.personName, .organizationName, .placeName,
                  .ipAddress, .macAddress, .labeledField, .highEntropy, .contextual] {
            XCTAssertFalse(c.isHighRisk, "\(c) should not be high-risk")
        }
    }
    func test_everyCaseClassified() {
        // Exhaustiveness sanity: every case returns a Bool without trapping.
        for c in SensitiveCategory.allCases { _ = c.isHighRisk }
    }
}
