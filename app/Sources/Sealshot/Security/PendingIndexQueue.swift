import Foundation
import CryptoKit
import os.log

private let log = OSLog(subsystem: "com.seal-shot.sealshot", category: "pending-index")

/// One capture's index payload created while the session was locked.
struct PendingIndexEntry: Codable, Equatable {
    let row: CaptureIndexRow
    let ocrText: String
}

/// Spill folder for index entries that cannot be written into the in-memory
/// index because the session is locked. Each entry is its own file: a fresh
/// content key wrapped to the identity PUBLIC key (no auth to append),
/// drained with the private key at unlock.
struct PendingIndexQueue {
    let folder: URL

    /// Shared production location: `Application Support/Sealshot/pendingIndex`.
    /// Both `LibraryIndexStore` and `MetadataCoordinator` use this so the
    /// two cannot independently drift to different folders.
    static var defaultFolder: URL {
        AppSupportDirectory.file("pendingIndex")
    }

    private struct Envelope: Codable {
        let capsule: KeyCapsule
        let sealed: Data
    }

    var count: Int {
        (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "pending" }.count) ?? 0
    }

    func append(_ entry: PendingIndexEntry, publicKey: IdentityPublicKey,
                generation: KeyGeneration) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let key = SymmetricKey(size: .bits256)
        let envelope = Envelope(
            capsule: try publicKey.wrap(contentKey: key, generation: generation),
            sealed: try SealedBlob.seal(try JSONEncoder().encode(entry), with: key))
        let url = folder.appendingPathComponent("\(UUID().uuidString).pending")
        try JSONEncoder().encode(envelope).write(to: url, options: .atomic)
    }

    /// Re-wrap every pending envelope's capsule from `old` to `newPublic`+`gen`
    /// (used by key rotation). Best-effort: an envelope that can't be re-wrapped is
    /// left as-is and will be dropped at the next drain (its data re-derives from
    /// the package during reconcile).
    func rekey(old: IdentityKey, new newPublic: IdentityPublicKey, generation: KeyGeneration) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil)) ?? []
        for url in files where url.pathExtension == "pending" {
            guard let data = try? Data(contentsOf: url),
                  let env = try? JSONDecoder().decode(Envelope.self, from: data),
                  let key = try? old.unwrap(capsule: env.capsule),
                  let capsule = try? newPublic.wrap(contentKey: key, generation: generation)
            else { continue }
            let rewrapped = Envelope(capsule: capsule, sealed: env.sealed)
            try? JSONEncoder().encode(rewrapped).write(to: url, options: .atomic)
        }
    }

    /// Decrypt and remove every entry. Corrupt files are logged and removed
    /// (the reconcile pass will re-derive their data from the package).
    func drain(identity: IdentityKey) -> [PendingIndexEntry] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil)) ?? []
        var out: [PendingIndexEntry] = []
        for url in files where url.pathExtension == "pending" {
            defer { try? FileManager.default.removeItem(at: url) }
            guard let data = try? Data(contentsOf: url),
                  let env = try? JSONDecoder().decode(Envelope.self, from: data),
                  let key = try? identity.unwrap(capsule: env.capsule),
                  let plain = try? SealedBlob.open(env.sealed, with: key),
                  let entry = try? JSONDecoder().decode(PendingIndexEntry.self, from: plain)
            else {
                os_log("dropping corrupt pending entry %{public}@",
                       log: log, type: .error, url.lastPathComponent)
                continue
            }
            out.append(entry)
        }
        return out
    }
}
