import Foundation
import CryptoKit

/// keystore.json — lives in the save-folder root so backups carry it.
/// Holds the identity PUBLIC key (encrypt-anytime), the recovery escrow of the
/// private key, and a sealed copy of the recovery code so it can be re-viewed.
struct Keystore: Codable {
    let version: Int
    /// Which generation's identity this keystore escrows — so recovery restores
    /// a named generation and the consistency check can match it to the keyring.
    let generation: KeyGeneration
    let publicKeyRaw: Data
    let escrow: RecoveryKey.Escrow
    /// Sealed copy of the recovery code, so the user can re-view it later.
    /// SECURITY TRADEOFF (accepted by the user): the recovery code is normally
    /// the one secret NOT on disk — only its escrow is. Sealing the code under the
    /// identity public key means anyone who compromises the unlocked identity can
    /// also read the code (and recover on another Mac, even after an identity
    /// rotation). "Generate new code" lets a worried user rotate it.
    let codeCapsule: KeyCapsule
    let sealedCode: Data

    static let filename = "keystore.json"
    /// v3: adds the sealed recovery code (`codeCapsule` + `sealedCode`). Older
    /// versions decode as nil (test data is disposable — no backward compat).
    static let currentVersion = 3

    static func create(identity: IdentityKey, recoveryCode: String,
                       generation: KeyGeneration) throws -> Keystore {
        // Seal the code under a fresh symmetric key wrapped to the identity's
        // public key (encrypt-anytime — no private key needed to write it).
        let codeKey = SymmetricKey(size: .bits256)
        let codeCapsule = try identity.publicKey.wrap(contentKey: codeKey, generation: generation)
        let sealedCode = try SealedBlob.seal(Data(recoveryCode.utf8), with: codeKey)
        return Keystore(version: currentVersion,
                        generation: generation,
                        publicKeyRaw: identity.publicKey.rawRepresentation,
                        escrow: try RecoveryKey.escrow(identity: identity, code: recoveryCode),
                        codeCapsule: codeCapsule, sealedCode: sealedCode)
    }

    /// Reveal the stored recovery code using the identity private key. Nil if the
    /// identity is wrong or the sealed data is corrupt.
    func recoveryCode(unwrappingWith identity: IdentityKey) -> String? {
        guard let key = try? identity.unwrap(capsule: codeCapsule),
              let data = try? SealedBlob.open(sealedCode, with: key)
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    var publicKey: IdentityPublicKey? {
        try? IdentityPublicKey(rawRepresentation: publicKeyRaw)
    }

    func write(toFolder folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self)
            .write(to: folder.appendingPathComponent(Self.filename), options: .atomic)
    }

    /// Nil for missing, corrupt, OR newer-version files — callers cannot
    /// distinguish. Phase 2's recovery flow must check file existence
    /// separately before treating nil as "no keystore" (a newer-version file
    /// should surface "update Sealshot", not "start fresh").
    static func read(fromFolder folder: URL) -> Keystore? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(filename)),
              let keystore = try? JSONDecoder().decode(Keystore.self, from: data),
              keystore.version == currentVersion
        else { return nil }
        return keystore
    }
}
