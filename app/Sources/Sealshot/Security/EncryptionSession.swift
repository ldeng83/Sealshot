import Foundation
import CryptoKit
import Observation
import os.log

private let log = OSLog(subsystem: "com.seal-shot.sealshot", category: "encryption")

extension Notification.Name {
    /// Posted (main thread) whenever the session locks or unlocks, for
    /// AppKit observers outside a SwiftUI Observation scope.
    static let encryptionLockStateDidChange = Notification.Name("EncryptionLockStateDidChange")
}

/// Process-wide encryption state: whether the feature is on (internal flag —
/// no UI until Phase 2), whether the session is unlocked, and the per-store
/// content keys. Content keys are generated once per store, wrapped to the
/// identity public key, and persisted as capsule files; unwrapping needs the
/// unlocked identity. Main-actor: all callers are UI-adjacent stores.
@Observable
@MainActor
final class EncryptionSession {
    /// Stores with their own content key + capsule file.
    enum Store: String, CaseIterable {
        case libraryIndex = "library-index"
        case history = "history"
        case recordings = "recordings"
    }

    static let shared = EncryptionSession(
        identityStore: KeychainIdentityStore(),
        capsuleFolder: defaultCapsuleFolder,
        defaults: .standard)

    static var defaultCapsuleFolder: URL {
        AppSupportDirectory.subdirectory("keys")
    }

    /// Internal Phase 1 flag — becomes the Settings toggle's backing store in
    /// Phase 2. Default off.
    nonisolated static let enabledKey = "EncryptionAtRestEnabled"

    @ObservationIgnored private let identityStore: IdentityStore
    /// Module-internal (not private) so `LockoutReset` can archive this
    /// session's actual keyring/capsule files before `retireKeyMaterial`
    /// deletes them — production and tests may each use a different folder.
    @ObservationIgnored let capsuleFolder: URL
    @ObservationIgnored private let defaults: UserDefaults
    private var identity: IdentityKey?
    @ObservationIgnored private var keyCache: [Store: SymmetricKey] = [:]
    private(set) var publicKey: IdentityPublicKey?
    /// The generation new data is wrapped under, from the keyring's active
    /// record. Nil when the feature is off or no keyring has been written yet.
    private(set) var activeGeneration: KeyGeneration?

    /// Creates an encryption session bound to the given identity store and
    /// capsule folder. The active generation, its public key, and the matching
    /// per-generation keychain identity all come from `keyring.json`; capsules
    /// are stamped with the generation so divergence is detected (see
    /// `contentKey(for:)`) rather than silently throwing on a stale capsule.
    init(identityStore: IdentityStore, capsuleFolder: URL, defaults: UserDefaults) {
        self.identityStore = identityStore
        self.capsuleFolder = capsuleFolder
        self.defaults = defaults
        if let active = Keyring.read(fromFolder: capsuleFolder)?.active {
            self.activeGeneration = active.generation
            self.publicKey = active.publicKey
        }
    }

    var isEnabled: Bool {
        get { defaults.bool(forKey: Self.enabledKey) }
        set { defaults.set(newValue, forKey: Self.enabledKey) }
    }

    var isUnlocked: Bool { identity != nil }

    /// True while an enable/disable (encrypt/decrypt) operation is running.
    /// Observed by the shell so the top Editor/Library/Settings tabs and the
    /// Settings section sidebar are disabled — the user can't navigate away and
    /// interrupt the migration mid-flight. Set by `EncryptionToggleModel`.
    var operationInProgress: Bool = false

    /// Whether the identity key is reachable on this Mac (already in memory, or
    /// stored in the keychain for this build). When false while `isEnabled` is
    /// true, the captures can only be reopened via the recovery key — the lock
    /// screen uses this to steer there instead of a dead Unlock button.
    var identityAvailable: Bool {
        if identity != nil { return true }
        if let active = activeGeneration { return identityStore.hasStoredIdentity(for: active) }
        return identityStore.hasStoredIdentity()
    }

    /// Record a provisioning's public key + generation in the keyring (append,
    /// set active) for encrypt-anytime use across relaunches. Appends to any
    /// existing keyring so old generations stay addressable — never clobbers.
    func provision(publicKey: IdentityPublicKey, generation: KeyGeneration) throws {
        try FileManager.default.createDirectory(at: capsuleFolder, withIntermediateDirectories: true)
        self.publicKey = publicKey
        self.activeGeneration = generation
        let record = GenerationRecord(generation: generation,
                                      publicKeyRaw: publicKey.rawRepresentation, retiredAt: nil)
        let keyring = Keyring.read(fromFolder: capsuleFolder)?.appending(record)
            ?? Keyring.initial(record)
        try keyring.write(toFolder: capsuleFolder)
    }

    /// Fetch the identity for the active generation (Keychain implementation
    /// prompts for user presence). Returns false when no identity exists or auth
    /// was denied.
    @discardableResult
    func unlock() async throws -> Bool {
        guard identity == nil else { return true }
        let loaded: IdentityKey?
        if let active = activeGeneration {
            loaded = try await identityStore.load(for: active)
        } else {
            loaded = try await identityStore.load()
        }
        guard let loaded else {
            os_log("unlock failed: no identity or auth denied", log: log, type: .error)
            return false
        }
        identity = loaded
        os_log("session unlocked", log: log, type: .info)
        NotificationCenter.default.post(name: .encryptionLockStateDidChange, object: self)
        return true
    }

    /// Unlock at launch with NO Touch ID / password prompt, for users who
    /// turned off "Lock when Sealshot starts". Same contract as `unlock()` —
    /// idempotent, posts `.encryptionLockStateDidChange`, returns false and
    /// leaves the session locked when the key can't be read.
    ///
    /// The only caller is `AppDelegate`'s launch path, guarded by
    /// `LaunchUnlockPolicy`. Everything else must go through `unlock()`.
    ///
    /// Synchronous on purpose: it runs before the first window is built, so an
    /// async hop would let the lock overlay appear and vanish a frame later.
    @discardableResult
    func unlockWithoutPresence() throws -> Bool {
        guard identity == nil else { return true }
        let loaded: IdentityKey?
        if let active = activeGeneration {
            loaded = try identityStore.loadWithoutUserPresence(for: active)
        } else {
            loaded = try identityStore.loadWithoutUserPresence()
        }
        guard let loaded else {
            os_log("launch unlock failed: no identity on this Mac", log: log, type: .error)
            return false
        }
        identity = loaded
        os_log("session unlocked at launch (lock-at-startup off)", log: log, type: .info)
        NotificationCenter.default.post(name: .encryptionLockStateDidChange, object: self)
        return true
    }

    /// Unlock with an identity the caller already holds in memory — used only
    /// by the enable flow, which just generated and persisted the key. Going
    /// through `unlock()` instead would re-load it from the keychain and
    /// auth-prompt the user for a key the app never let go of.
    func adopt(_ identity: IdentityKey) {
        self.identity = identity
        publicKey = identity.publicKey
        os_log("session unlocked (adopted provisioning identity)", log: log, type: .info)
        NotificationCenter.default.post(name: .encryptionLockStateDidChange, object: self)
    }

    func lock() {
        // Note: clearing these references does not zero the heap copies of the
        // key bytes — SymmetricKey/IdentityKey do not guarantee zeroing on
        // dealloc in the Swift/CryptoKit runtime. This is accepted under an
        // app-process threat model where the attacker cannot inspect live
        // process memory; full in-memory zeroing is a Phase 2+ hardening item.
        identity = nil
        keyCache = [:]
        os_log("session locked", log: log, type: .info)
        NotificationCenter.default.post(name: .encryptionLockStateDidChange, object: self)
    }

    /// The unlocked identity, for pending-queue draining. Nil while locked.
    func unlockedIdentityForDrain() -> IdentityKey? { identity }

    /// Drops every cached content key so the next `contentKey(for:)` call
    /// re-reads each store's capsule from disk instead of serving a value
    /// cached before that capsule changed underneath it. Used by
    /// `LockedArchiveRestore`, which moves/re-wraps capsule files directly —
    /// a session that already cached a store's key earlier in the same
    /// process (entirely plausible: the app writes history/index entries as
    /// the user works, well before they ever find an old recovery code)
    /// would otherwise keep vending that stale key after a restore.
    func invalidateContentKeyCache() {
        keyCache = [:]
    }

    /// Re-wrap every store capsule from `oldIdentity` to `newPublic`+`generation`
    /// (content keys unchanged — data is NOT re-encrypted). Used by key rotation.
    /// Throws on any failure so the caller can treat rotation as transactional.
    func rekeyStoreCapsules(to newPublic: IdentityPublicKey,
                            generation: KeyGeneration,
                            using oldIdentity: IdentityKey) throws {
        for store in Store.allCases {
            let url = capsuleFolder.appendingPathComponent("\(store.rawValue).capsule")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let capsule = try JSONDecoder().decode(KeyCapsule.self, from: try Data(contentsOf: url))
            let key = try oldIdentity.unwrap(capsule: capsule)
            let rewrapped = try newPublic.wrap(contentKey: key, generation: generation)
            try JSONEncoder().encode(rewrapped).write(to: url, options: .atomic)
        }
    }

    /// Mark a generation retired in the keyring (kept for audit) and delete its
    /// keychain item. Used after rotation re-keys everything forward.
    func retireGeneration(_ generation: KeyGeneration, identityStore: IdentityStore, at date: Date) {
        if let keyring = Keyring.read(fromFolder: capsuleFolder) {
            try? keyring.retiring(generation.id, at: date).write(toFolder: capsuleFolder)
        }
        try? identityStore.delete(for: generation)
    }

    /// Classify this session's on-disk encryption state (see `EncryptionConsistency`),
    /// using the session's own capsule folder / identity store / defaults. The lock
    /// screen uses this to choose unlock vs recovery vs the turn-off escape.
    func consistencyStatus(saveFolder: URL) -> ConsistencyStatus {
        EncryptionConsistency.check(saveFolder: saveFolder, capsuleFolder: capsuleFolder,
                                    identityStore: identityStore, defaults: defaults)
    }

    /// Every identity reachable on this Mac, keyed by generation id: the in-memory
    /// key (if unlocked) plus a best-effort keychain load for each keyring
    /// generation that has a stored item. Used by `disable` to decrypt across
    /// generations. May prompt once for the keychain items; a cancelled prompt
    /// just yields fewer keys (those packages get quarantined instead).
    func reachableIdentities() async -> [UUID: IdentityKey] {
        var result: [UUID: IdentityKey] = [:]
        if let active = activeGeneration, let identity { result[active.id] = identity }
        guard let keyring = Keyring.read(fromFolder: capsuleFolder) else { return result }
        for record in keyring.generations where result[record.generation.id] == nil {
            guard identityStore.hasStoredIdentity(for: record.generation) else { continue }
            if let loaded = try? await identityStore.load(for: record.generation) {
                result[record.generation.id] = loaded
            }
        }
        return result
    }

    /// Delete ALL on-disk and keychain key material: every per-generation keychain
    /// item in the keyring (plus the legacy item), the keyring, the store capsules,
    /// and the legacy `public.key`; then clear in-memory state. Used by `disable`
    /// after decrypting/quarantining. Never throws — turning encryption off must
    /// always complete.
    func retireKeyMaterial(identityStore: IdentityStore) {
        if let keyring = Keyring.read(fromFolder: capsuleFolder) {
            for record in keyring.generations {
                try? identityStore.delete(for: record.generation)
            }
        }
        try? identityStore.delete()   // legacy single-slot item
        let fm = FileManager.default
        let names = Store.allCases.map { "\($0.rawValue).capsule" } + [Keyring.filename, "public.key"]
        for name in names {
            try? fm.removeItem(at: capsuleFolder.appendingPathComponent(name))
        }
        publicKey = nil
        activeGeneration = nil
        identity = nil
        keyCache = [:]
    }

    /// The content key for `store`: nil when the feature is off or the
    /// session is locked. Generates + persists the capsule on first use.
    /// A capsule from before key generations existed, which is to be thrown
    /// away rather than honoured.
    ///
    /// `KeyCapsule` says so itself — a v1 capsule has no `generationID`, "so
    /// FAILS to decode — callers treat that as 'no usable capsule' (wipe-ok, no
    /// backward compat)". `contentKey` did not: it let the decode error escape,
    /// and a capsule left behind by an earlier enable then made turning
    /// Enhanced Security back on fail HALFWAY. Keys were provisioned and the
    /// flag was on, but `enable` threw before it could purge the plaintext
    /// index or migrate a single package, so the library called itself
    /// encrypted while all of it sat in the clear.
    ///
    /// Deliberately narrow: only a file that positively identifies itself as
    /// pre-v2 is discardable. A v2 capsule that fails to decode is corrupt, not
    /// legacy, and minting a fresh key over it would abandon whatever the old
    /// key still protects — so that keeps throwing.
    private static func isDiscardableLegacyCapsule(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        if (try? JSONDecoder().decode(KeyCapsule.self, from: data)) != nil { return false }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let fields = object as? [String: Any] else { return false }
        // Absent `version` means 2 (see `KeyCapsule.version`), so only an
        // explicit sub-2 version marks a capsule as legacy.
        return (fields["version"] as? Int).map { $0 < 2 } ?? false
    }

    func contentKey(for store: Store) throws -> SymmetricKey? {
        guard isEnabled else { return nil }
        if let cached = keyCache[store] { return cached }
        guard let identity else { return nil }
        // Enabled + unlocked but no keyring → no generation to stamp/check. Vend
        // nothing rather than write an unstamped capsule.
        guard let generation = activeGeneration else { return nil }

        let capsuleURL = capsuleFolder.appendingPathComponent("\(store.rawValue).capsule")
        let key: SymmetricKey
        if FileManager.default.fileExists(atPath: capsuleURL.path),
           !Self.isDiscardableLegacyCapsule(at: capsuleURL) {
            // An existing capsule must decode and unwrap. A generation mismatch
            // is surfaced as a TYPED, catchable error — not an opaque HPKE
            // failure — so callers (and #2's always-can-disable) can react to a
            // diverged library instead of crashing on it.
            let data = try Data(contentsOf: capsuleURL)
            let capsule = try JSONDecoder().decode(KeyCapsule.self, from: data)
            guard capsule.generationID == generation.id else {
                throw EncryptionError.generationMismatch(
                    expected: generation.id, found: capsule.generationID)
            }
            key = try identity.unwrap(capsule: capsule)
        } else {
            key = SymmetricKey(size: .bits256)
            let capsule = try identity.publicKey.wrap(contentKey: key, generation: generation)
            try FileManager.default.createDirectory(at: capsuleFolder, withIntermediateDirectories: true)
            try JSONEncoder().encode(capsule).write(to: capsuleURL, options: .atomic)
        }
        keyCache[store] = key
        return key
    }
}
