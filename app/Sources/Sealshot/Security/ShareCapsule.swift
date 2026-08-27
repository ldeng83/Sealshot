import Foundation

/// CEK wrapped under a passphrase-derived key (scheme #1).
struct PassphraseCapsule: Codable, Equatable {
    var salt: Data
    var iterations: Int
    var sealed: Data        // SealedBlob.seal(cekBytes) under PassphraseKDF.derive(...)
    var hint: String?
}

/// One way to unwrap the package CEK. `unknown` preserves forward compatibility
/// with capsule types a future version introduces (e.g. the reserved self-decryptor).
enum ShareCapsule: Equatable {
    case passphrase(PassphraseCapsule)
    case identity(KeyCapsule)       // scheme #2 — reuses existing HPKE KeyCapsule
    case unknown
}

extension ShareCapsule: Codable {
    private enum CodingKeys: String, CodingKey { case type, passphrase, identity }
    private enum Kind: String, Codable { case passphrase, identity }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let raw = try? c.decode(String.self, forKey: .type),
              let kind = Kind(rawValue: raw) else {
            self = .unknown
            return
        }
        switch kind {
        case .passphrase: self = .passphrase(try c.decode(PassphraseCapsule.self, forKey: .passphrase))
        case .identity:   self = .identity(try c.decode(KeyCapsule.self, forKey: .identity))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .passphrase(let p):
            try c.encode(Kind.passphrase.rawValue, forKey: .type)
            try c.encode(p, forKey: .passphrase)
        case .identity(let k):
            try c.encode(Kind.identity.rawValue, forKey: .type)
            try c.encode(k, forKey: .identity)
        case .unknown:
            // A v1 writer never emits unknown capsules.
            throw EncodingError.invalidValue(self, .init(codingPath: encoder.codingPath,
                debugDescription: "Cannot encode an unknown capsule"))
        }
    }
}

struct ShareHeader: Codable, Equatable {
    var version: Int
    var createdAt: Date
    var expiresAt: Date?
    var capsules: [ShareCapsule]
}

struct ShareCapsuleSummary: Equatable {
    enum Kind { case passphrase, identity, unknown }
    var kind: Kind
    var generationID: UUID?   // for identity capsules: KeyCapsule.generationID
    var hint: String?         // for passphrase capsules
}
