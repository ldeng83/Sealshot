import Foundation
import CryptoKit

/// A content key wrapped to the identity public key via HPKE
/// (X25519 + SHA-256 + AES-GCM-256). Encrypting requires only the public
/// key; unwrapping requires the identity private key.
struct KeyCapsule: Codable, Equatable {
    /// Suite/format discriminant. v2 adds `generationID`; defaults to 2 when the
    /// version key is absent. A legacy v1 capsule has no `generationID` and so
    /// FAILS to decode — callers treat that as "no usable capsule" (wipe-ok, no
    /// backward compat).
    var version: Int = 2
    /// Which key generation wrapped this content key (see `KeyGeneration`).
    let generationID: UUID
    let encapsulated: Data   // HPKE encapsulated key
    let ciphertext: Data     // sealed content-key bytes

    private enum CodingKeys: String, CodingKey { case version, generationID, encapsulated, ciphertext }

    init(version: Int = 2, generationID: UUID, encapsulated: Data, ciphertext: Data) {
        self.version = version
        self.generationID = generationID
        self.encapsulated = encapsulated
        self.ciphertext = ciphertext
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 2
        generationID = try c.decode(UUID.self, forKey: .generationID)
        encapsulated = try c.decode(Data.self, forKey: .encapsulated)
        ciphertext = try c.decode(Data.self, forKey: .ciphertext)
    }
}

private let hpkeSuite = HPKE.Ciphersuite(
    kem: .Curve25519_HKDF_SHA256, kdf: .HKDF_SHA256, aead: .AES_GCM_256)
private let hpkeInfo = Data("sealshot.content-key.v1".utf8)

/// The identity public key — all that's needed to encrypt new data.
struct IdentityPublicKey {
    let key: Curve25519.KeyAgreement.PublicKey

    var rawRepresentation: Data { key.rawRepresentation }

    init(rawRepresentation: Data) throws {
        key = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: rawRepresentation)
    }

    init(_ key: Curve25519.KeyAgreement.PublicKey) { self.key = key }

    /// Wrap a content key, stamping the capsule with the active generation so
    /// divergence is detectable at unwrap time.
    func wrap(contentKey: SymmetricKey, generation: KeyGeneration) throws -> KeyCapsule {
        var sender = try HPKE.Sender(recipientKey: key, ciphersuite: hpkeSuite, info: hpkeInfo)
        let keyBytes = contentKey.withUnsafeBytes { Data($0) }
        let ciphertext = try sender.seal(keyBytes)
        return KeyCapsule(generationID: generation.id,
                          encapsulated: sender.encapsulatedKey, ciphertext: ciphertext)
    }
}

/// The identity private key — required to decrypt. Lives only in the
/// Keychain (user-presence gated) or, escrowed, in keystore.json.
/// Value type: assignments copy key material — keep instances tightly
/// scoped and never store `rawRepresentation` beyond the minimum window.
struct IdentityKey {
    let privateKey: Curve25519.KeyAgreement.PrivateKey

    static func generate() -> IdentityKey {
        IdentityKey(privateKey: Curve25519.KeyAgreement.PrivateKey())
    }

    var publicKey: IdentityPublicKey { IdentityPublicKey(privateKey.publicKey) }
    var rawRepresentation: Data { privateKey.rawRepresentation }

    init(privateKey: Curve25519.KeyAgreement.PrivateKey) { self.privateKey = privateKey }

    init(rawRepresentation: Data) throws {
        privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: rawRepresentation)
    }

    func unwrap(capsule: KeyCapsule) throws -> SymmetricKey {
        var recipient = try HPKE.Recipient(
            privateKey: privateKey, ciphersuite: hpkeSuite,
            info: hpkeInfo, encapsulatedKey: capsule.encapsulated)
        return SymmetricKey(data: try recipient.open(capsule.ciphertext))
    }
}
