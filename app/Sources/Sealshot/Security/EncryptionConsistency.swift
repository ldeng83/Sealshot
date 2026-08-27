import Foundation

/// The classification a startup/post-toggle check produces for the encryption
/// state. Makes divergence a first-class, actionable state instead of an
/// uncaught HPKE failure. Sub-project #2's always-can-disable consumes this.
enum ConsistencyStatus: Equatable {
    /// Feature off — nothing to check.
    case off
    /// Active generation's identity is reachable on this Mac; capsules match it.
    case consistent(KeyGeneration)
    /// Active generation's identity is NOT on this Mac, but its escrow is present
    /// → the recovery code can restore it.
    case recoverable(KeyGeneration)
    /// An actionable problem (see `Divergence`).
    case diverged(Divergence)
}

extension ConsistencyStatus {
    /// One-line health summary for the Privacy & Security status row. Nil when
    /// the feature is off (no row shown).
    var settingsSummary: String? {
        switch self {
        case .off: return nil
        case .consistent: return "On — keys are healthy on this Mac."
        case .recoverable: return "On — the key isn’t on this Mac; recover with your code."
        case .diverged: return "Needs attention — open the lock screen to recover or turn encryption off."
        }
    }
}

enum Divergence: Equatable {
    /// Capsules exist but `keyring.json` is missing or malformed.
    case noKeyring
    /// A store capsule is stamped with a generation absent from the keyring.
    case orphanCapsule(store: String, stampedGeneration: UUID)
    /// The active generation has neither a keychain identity nor an escrow —
    /// unrecoverable without one of them.
    case noIdentityNoEscrow(KeyGeneration)
}

/// Classifies the encryption state in O(generations): reads only `keyring.json`,
/// the store-capsule headers, and `keystore.json` — it NEVER enumerates the
/// packages. Cheap enough to run at every launch and after each enable/disable.
enum EncryptionConsistency {
    static func check(saveFolder: URL,
                      capsuleFolder: URL,
                      identityStore: IdentityStore,
                      defaults: UserDefaults) -> ConsistencyStatus {
        guard defaults.bool(forKey: EncryptionSession.enabledKey) else { return .off }

        let existingCapsules = EncryptionSession.Store.allCases
            .map { capsuleFolder.appendingPathComponent("\($0.rawValue).capsule") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }

        guard let keyring = Keyring.read(fromFolder: capsuleFolder), let active = keyring.active else {
            // No (or malformed) keyring: clean if nothing is encrypted, else diverged.
            return existingCapsules.isEmpty ? .off : .diverged(.noKeyring)
        }

        // Any store capsule stamped with a generation the keyring doesn't know
        // about is an orphan (data wrapped under a key we can't account for).
        let knownIDs = Set(keyring.generations.map(\.generation.id))
        for url in existingCapsules {
            guard let data = try? Data(contentsOf: url),
                  let capsule = try? JSONDecoder().decode(KeyCapsule.self, from: data)
            else { continue }   // unreadable / legacy capsule — ignore (wipe-ok)
            if !knownIDs.contains(capsule.generationID) {
                return .diverged(.orphanCapsule(
                    store: url.deletingPathExtension().lastPathComponent,
                    stampedGeneration: capsule.generationID))
            }
        }

        // Identity reachability for the active generation.
        if identityStore.hasStoredIdentity(for: active.generation) {
            return .consistent(active.generation)
        }
        if let keystore = Keystore.read(fromFolder: saveFolder),
           keystore.generation == active.generation {
            return .recoverable(active.generation)
        }
        return .diverged(.noIdentityNoEscrow(active.generation))
    }
}
