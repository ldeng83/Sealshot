import Foundation
import CryptoKit

/// Plaintext header inside an encrypted .seal package: names the codec
/// version and carries the package content key wrapped to the identity
/// public key. Presence of this file == "locked package" (codec v5).
struct LockHeader: Codable, Equatable {
    static let filename = "lock.json"
    /// v6: the nested `capsule` is v2 (carries a generationID).
    static let currentVersion = 6

    var version: Int = LockHeader.currentVersion
    let capsule: KeyCapsule
}

/// What package I/O needs from the encryption layer, injectable for tests.
/// `publicKey`+`generation` enable WRITING locked packages (no auth ever);
/// `identity` enables READING them (only present while the session is unlocked).
struct SealPackageCryptoContext: Sendable {
    let publicKey: IdentityPublicKey?
    let generation: KeyGeneration?
    let identity: IdentityKey?

    /// `generation` defaults to nil so plaintext (no-key) contexts read the same
    /// as before. WRITING a locked package needs BOTH a publicKey and a
    /// generation (see `SealPackageIO`); a publicKey with no generation writes
    /// plaintext, same as no key.
    init(publicKey: IdentityPublicKey?, generation: KeyGeneration? = nil, identity: IdentityKey?) {
        self.publicKey = publicKey
        self.generation = generation
        self.identity = identity
    }

    /// Production context from the shared session. Disabled feature (or no
    /// active generation) → publicKey/generation nil → package I/O behaves
    /// exactly as before (plaintext v4).
    @MainActor
    static func current() -> SealPackageCryptoContext {
        let session = EncryptionSession.shared
        guard session.isEnabled else {
            return SealPackageCryptoContext(publicKey: nil, generation: nil, identity: nil)
        }
        return SealPackageCryptoContext(
            publicKey: session.publicKey,
            generation: session.activeGeneration,
            identity: session.unlockedIdentityForDrain())
    }
}

/// Seals/opens the inner files of a .seal package with a per-package
/// content key (CEK). The CEK travels in lock.json, wrapped via HPKE.
enum SealPackageCrypter {
    /// Seal every entry with a CEK (fresh unless `reusing` is given) and add
    /// the lock.json header. Returns the sealed entry map and the CEK so the
    /// caller can hand it to the metadata pipeline.
    static func sealEntries(
        _ entries: [String: Data],
        publicKey: IdentityPublicKey,
        generation: KeyGeneration,
        reusing cek: SymmetricKey? = nil
    ) throws -> (entries: [String: Data], cek: SymmetricKey) {
        let key = cek ?? SymmetricKey(size: .bits256)
        var out: [String: Data] = [:]
        for (name, data) in entries {
            out[name] = try SealedBlob.seal(data, with: key)
        }
        let header = LockHeader(capsule: try publicKey.wrap(contentKey: key, generation: generation))
        out[LockHeader.filename] = try JSONEncoder().encode(header)
        return (out, key)
    }

    static func unwrapCEK(_ header: LockHeader, identity: IdentityKey) throws -> SymmetricKey {
        try identity.unwrap(capsule: header.capsule)
    }

    /// True when the package directory carries a lock.json header.
    static func isLocked(_ packageURL: URL) -> Bool {
        // `lock.json` is an ENTRY, so its presence is a directory lookup in a
        // container and a file check in a legacy package.
        if SealContainer.isContainer(packageURL) {
            return (try? SealContainer.Reader(url: packageURL))?
                .entry(LockHeader.filename) != nil
        }
        return FileManager.default.fileExists(
            atPath: packageURL.appendingPathComponent(LockHeader.filename).path)
    }
}
