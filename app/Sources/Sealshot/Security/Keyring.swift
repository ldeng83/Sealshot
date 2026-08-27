import Foundation

/// One generation's public record in the keyring: the generation identity, the
/// public key to encrypt new data under it, and when it was retired (nil = live).
/// Retired records are KEPT in the ledger until their data is migrated forward,
/// so an old generation never becomes silently unrecoverable.
struct GenerationRecord: Codable, Equatable {
    let generation: KeyGeneration
    let publicKeyRaw: Data   // 32-byte Curve25519 public key (encrypt-anytime under this generation)
    var retiredAt: Date?

    var publicKey: IdentityPublicKey? {
        try? IdentityPublicKey(rawRepresentation: publicKeyRaw)
    }
}

/// `keyring.json` (capsule folder) — the append-and-retire ledger of every key
/// generation. Replaces the bare `public.key`: the active record's `publicKeyRaw`
/// is the encrypt-anytime key, and the full list lets recovery/rotation (#2)
/// keep old generations addressable instead of clobbering them.
struct Keyring: Codable {
    var version: Int
    var activeGenerationID: UUID
    var generations: [GenerationRecord]

    static let filename = "keyring.json"
    static let currentVersion = 1

    init(version: Int = currentVersion, activeGenerationID: UUID, generations: [GenerationRecord]) {
        self.version = version
        self.activeGenerationID = activeGenerationID
        self.generations = generations
    }

    /// The currently-active generation's record, or nil if the ledger is malformed.
    var active: GenerationRecord? {
        generations.first { $0.generation.id == activeGenerationID }
    }

    func record(for id: UUID) -> GenerationRecord? {
        generations.first { $0.generation.id == id }
    }

    /// A fresh keyring with a single active generation.
    static func initial(_ record: GenerationRecord) -> Keyring {
        Keyring(activeGenerationID: record.generation.id, generations: [record])
    }

    /// Append a record; optionally make it active. Existing records are
    /// preserved (append-only) so superseded generations stay recoverable.
    func appending(_ record: GenerationRecord, active: Bool = true) -> Keyring {
        var copy = self
        copy.generations.append(record)
        if active { copy.activeGenerationID = record.generation.id }
        return copy
    }

    /// Stamp a generation retired (kept in the ledger). Does not change which
    /// generation is active.
    func retiring(_ id: UUID, at date: Date) -> Keyring {
        var copy = self
        if let i = copy.generations.firstIndex(where: { $0.generation.id == id }) {
            copy.generations[i].retiredAt = date
        }
        return copy
    }

    func write(toFolder folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self)
            .write(to: folder.appendingPathComponent(Self.filename), options: .atomic)
    }

    /// Nil for missing / corrupt / version≠current (no backward compat — old
    /// keyrings are disposable test data).
    static func read(fromFolder folder: URL) -> Keyring? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(filename)),
              let ring = try? JSONDecoder().decode(Keyring.self, from: data),
              ring.version == currentVersion
        else { return nil }
        return ring
    }
}
