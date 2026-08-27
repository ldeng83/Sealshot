import Foundation
import CryptoKit

/// Identifies one provisioning of the identity keypair. Every key-bearing
/// artifact (capsules, lock.json, keystore.json) is stamped with the generation
/// it belongs to, so divergence between "which public key wrapped this" and
/// "which private key is on this Mac" becomes detectable instead of an uncaught
/// HPKE failure. See the keyring (`Keyring`) for the ledger of all generations.
struct KeyGeneration: Codable, Equatable {
    /// Unique per provisioning — the stable handle used to stamp artifacts and
    /// to name the per-generation keychain item.
    let id: UUID
    /// Cheap, non-secret structural tag of the public key (see `fingerprint(of:)`).
    let fingerprint: String
    let createdAt: Date

    /// Lowercase hex of the first 16 bytes of SHA256(public key). Non-secret —
    /// it lets the consistency check confirm a capsule's stamp matches the
    /// keyring's recorded public key WITHOUT loading the auth-gated private key.
    static func fingerprint(of publicKey: IdentityPublicKey) -> String {
        SHA256.hash(data: publicKey.rawRepresentation)
            .prefix(16)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Mint a generation for a public key. `id`/`createdAt` are injectable for
    /// deterministic tests; production callers take the defaults.
    static func make(publicKey: IdentityPublicKey,
                     id: UUID = UUID(),
                     createdAt: Date = Date()) -> KeyGeneration {
        KeyGeneration(id: id, fingerprint: Self.fingerprint(of: publicKey), createdAt: createdAt)
    }
}
