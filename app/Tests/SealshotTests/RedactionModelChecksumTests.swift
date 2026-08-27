import XCTest
@testable import Sealshot

final class RedactionModelChecksumTests: XCTestCase {
    private func tmp(_ data: Data) throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: u); return u
    }
    func testSha256MatchesKnownDigest() throws {
        let u = try tmp(Data("hello\n".utf8))
        // sha256("hello\n") = 5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03
        XCTAssertEqual(try RedactionModelChecksum.sha256(ofFileAt: u),
                       "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03")
    }
    func testMatches_caseInsensitiveAndNegative() throws {
        let u = try tmp(Data("hello\n".utf8))
        XCTAssertTrue(RedactionModelChecksum.matches(fileAt: u, expected: "5891B5B522D5DF086D0FF0B110FBD9D21BB4FC7163AF34D08286A2E846F6BE03"))
        XCTAssertFalse(RedactionModelChecksum.matches(fileAt: u, expected: "deadbeef"))
    }
}
