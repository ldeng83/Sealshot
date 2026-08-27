import Foundation
import CryptoKit

/// Recovery code + escrow of the identity private key. The code is shown to
/// the user once; the escrow blob lives in keystore.json next to the data,
/// so save-folder backup + code recovers everything on a new machine.
enum RecoveryKey {
    enum Error: Swift.Error { case badEscrow, badCode }

    /// XXXXX-XXXXX-XXXXX-XXXXX-XXXXX — 25 chars ≈ 122 bits of entropy.
    static func generateCode() -> String {
        CrockfordCode.generate(groups: 5, groupSize: 5)
    }

    /// Escrow payload: PBKDF2 salt + SealedBlob of the private key bytes.
    struct Escrow: Codable, Equatable {
        let salt: Data
        let sealed: Data
        let iterations: Int
    }

    static let defaultIterations = 600_000

    /// Frozen floor — escrows claiming fewer iterations are rejected as
    /// tampered. Never lower this; raising defaultIterations is fine.
    static let minimumIterations = 600_000

    static func escrow(identity: IdentityKey, code: String,
                       iterations: Int = defaultIterations) throws -> Escrow {
        let salt = PassphraseKDF.makeSalt()
        let key = try derive(code: code, salt: salt, iterations: iterations)
        let sealed = try SealedBlob.seal(identity.rawRepresentation, with: key)
        return Escrow(salt: salt, sealed: sealed, iterations: iterations)
    }

    static func recover(escrow: Escrow, code: String) throws -> IdentityKey {
        guard escrow.iterations >= Self.minimumIterations else { throw Error.badEscrow }
        let key = try derive(code: code, salt: escrow.salt, iterations: escrow.iterations)
        guard let raw = try? SealedBlob.open(escrow.sealed, with: key) else { throw Error.badEscrow }
        return try IdentityKey(rawRepresentation: raw)
    }

    /// Normalize user input (case, dashes, whitespace) then PBKDF2-HMAC-SHA256.
    private static func derive(code: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        let normalized = code.uppercased().filter { !"- \t".contains($0) }
        guard !normalized.isEmpty else { throw Error.badCode }
        do {
            return try PassphraseKDF.derive(passphrase: normalized, salt: salt, iterations: iterations)
        } catch {
            throw Error.badCode
        }
    }
}
