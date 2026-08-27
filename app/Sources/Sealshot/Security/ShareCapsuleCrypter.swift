import Foundation
import CryptoKit

extension SymmetricKey {
    /// Raw key bytes as `Data`.
    var rawData: Data { withUnsafeBytes { Data($0) } }
}

enum ShareCapsuleCrypter {
    // MARK: Passphrase (scheme #1)

    static func wrap(cek: SymmetricKey, passphrase: String, hint: String?) throws -> PassphraseCapsule {
        let salt = PassphraseKDF.makeSalt()
        let key = try PassphraseKDF.derive(passphrase: passphrase, salt: salt,
                                           iterations: PassphraseKDF.defaultIterations)
        let sealed = try SealedBlob.seal(cek.rawData, with: key)
        return PassphraseCapsule(salt: salt, iterations: PassphraseKDF.defaultIterations,
                                 sealed: sealed, hint: hint)
    }

    /// Returns the CEK, or nil when the passphrase is wrong (derivation/auth failure).
    static func unwrap(_ capsule: PassphraseCapsule, passphrase: String) -> SymmetricKey? {
        guard let key = try? PassphraseKDF.derive(passphrase: passphrase, salt: capsule.salt,
                                                  iterations: capsule.iterations),
              let cekBytes = try? SealedBlob.open(capsule.sealed, with: key) else {
            return nil
        }
        return SymmetricKey(data: cekBytes)
    }

    // MARK: Identity (scheme #2)

    static func wrap(cek: SymmetricKey, recipient: IdentityPublicKey,
                     generation: KeyGeneration) throws -> KeyCapsule {
        try recipient.wrap(contentKey: cek, generation: generation)
    }

    /// Returns the CEK, or nil when this identity cannot open the capsule.
    static func unwrap(_ capsule: KeyCapsule, identity: IdentityKey) -> SymmetricKey? {
        try? identity.unwrap(capsule: capsule)
    }
}
