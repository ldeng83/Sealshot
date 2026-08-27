import Foundation
import CryptoKit

/// Signed revocation list, published next to the appcast in the
/// Sealshot-Release repo and maintained by `licensegen revoke`. Fetched only
/// when the Direct build's "Automatically check for updates" is on (AppDelegate
/// gates the refresh on `UpdaterController.automaticallyChecksForUpdates` — the
/// same network expectation as a Sparkle update check); verified before use,
/// cached so a received revocation sticks offline. Skipping the fetch never
/// clears the cache — EntitlementStore reads the cached list, not the network.
struct Blocklist: Codable, Equatable {
    let v: Int
    let key: Int
    let revoked: [UUID]
    let updated: String
    let sig: String

    func revokes(_ id: UUID) -> Bool { revoked.contains(id) }

    /// The signed message: comma-joined SORTED uuidStrings (matches licensegen).
    var signedMessage: Data {
        Data(revoked.map(\.uuidString).sorted().joined(separator: ",").utf8)
    }
}

struct BlocklistVerifier {
    let publicKeys: [Int: Curve25519.Signing.PublicKey]
    init(publicKeys: [Int: Curve25519.Signing.PublicKey] = LicenseKeys.production) {
        self.publicKeys = publicKeys
    }
    func verify(_ list: Blocklist) throws {
        guard let key = publicKeys[list.key] else { throw LicenseError.unknownSigningKey }
        guard let sig = Data(base64Encoded: list.sig),
              key.isValidSignature(sig, for: list.signedMessage)
        else { throw LicenseError.badSignature }
    }
}

struct BlocklistCache {
    let directory: URL
    private var url: URL { directory.appendingPathComponent("license-blocklist.json") }
    func load() -> Blocklist? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Blocklist.self, from: data)
    }
    func save(_ list: Blocklist) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(list).write(to: url, options: .atomic)
    }
}

enum BlocklistFetcher {
    /// Best-effort refresh: fetch, verify, cache, hand to the store. Any
    /// failure is silent — an unreachable blocklist must never break the app.
    static func refresh(verifier: BlocklistVerifier = BlocklistVerifier(),
                        cache: BlocklistCache,
                        apply: @MainActor @escaping (Blocklist) -> Void) {
        var request = URLRequest(url: LicensingConfig.blocklistURL)
        request.timeoutInterval = 10
        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data,
                  let list = try? JSONDecoder().decode(Blocklist.self, from: data),
                  (try? verifier.verify(list)) != nil else { return }
            cache.save(list)
            Task { @MainActor in apply(list) }
        }.resume()
    }
}
