import XCTest
@testable import Sealshot

final class RecoveryKeyTests: XCTestCase {
    func testGeneratedCodeFormat() {
        let code = RecoveryKey.generateCode()
        // 5 groups of 5 Crockford-Base32 chars: XXXXX-XXXXX-XXXXX-XXXXX-XXXXX
        let groups = code.split(separator: "-")
        XCTAssertEqual(groups.count, 5)
        for g in groups { XCTAssertEqual(g.count, 5) }
        XCTAssertNil(code.rangeOfCharacter(from: CharacterSet(charactersIn: "ILOU10")))
    }

    func testCodesAreUnique() {
        XCTAssertNotEqual(RecoveryKey.generateCode(), RecoveryKey.generateCode())
    }

    func testEscrowRoundTrip() throws {
        let identity = IdentityKey.generate()
        let code = RecoveryKey.generateCode()
        let escrow = try RecoveryKey.escrow(identity: identity, code: code)
        let restored = try RecoveryKey.recover(escrow: escrow, code: code)
        XCTAssertEqual(restored.rawRepresentation, identity.rawRepresentation)
    }

    func testWrongCodeFailsToRecover() throws {
        let escrow = try RecoveryKey.escrow(identity: .generate(), code: RecoveryKey.generateCode())
        XCTAssertThrowsError(try RecoveryKey.recover(escrow: escrow, code: RecoveryKey.generateCode()))
    }

    func testCodeNormalization() throws {
        // Lowercase + missing dashes must still recover (user-typed codes).
        let identity = IdentityKey.generate()
        let code = RecoveryKey.generateCode()
        let escrow = try RecoveryKey.escrow(identity: identity, code: code)
        let sloppy = code.lowercased().replacingOccurrences(of: "-", with: "")
        XCTAssertEqual(try RecoveryKey.recover(escrow: escrow, code: sloppy).rawRepresentation,
                       identity.rawRepresentation)
    }

    func testEscrowSaltIsFreshPerCall() throws {
        let identity = IdentityKey.generate()
        let code = RecoveryKey.generateCode()
        let a = try RecoveryKey.escrow(identity: identity, code: code)
        let b = try RecoveryKey.escrow(identity: identity, code: code)
        XCTAssertNotEqual(a.salt, b.salt)
        XCTAssertNotEqual(a.sealed, b.sealed)
    }

    func testTamperedLowIterationCountIsRejected() throws {
        let identity = IdentityKey.generate()
        let code = RecoveryKey.generateCode()
        let escrow = try RecoveryKey.escrow(identity: identity, code: code)
        let tampered = RecoveryKey.Escrow(salt: escrow.salt, sealed: escrow.sealed, iterations: 1)
        XCTAssertThrowsError(try RecoveryKey.recover(escrow: tampered, code: code))
    }

    func testEmptyCodeThrows() throws {
        XCTAssertThrowsError(try RecoveryKey.escrow(identity: .generate(), code: "---  "))
    }
}
