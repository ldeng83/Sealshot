import Foundation
import Security
import LocalAuthentication

/// Where the identity private key lives between unlocks. `load()` is the
/// auth gate: the Keychain implementation runs a Touch ID / password check
/// before returning the key.
protocol IdentityStore {
    func save(_ identity: IdentityKey) throws
    /// nil when no identity is stored OR the user cancelled/failed auth. The
    /// Keychain implementation prompts for Touch ID (or password) when an
    /// item exists; it never prompts when there is nothing to unlock.
    func load() async throws -> IdentityKey?
    /// Whether an identity is stored AND reachable by this app on this Mac —
    /// synchronous, never prompts. Lets the UI tell "locked, can unlock" apart
    /// from "enabled but the key isn't on this Mac" (keychain reset, migration,
    /// or a differently-signed build) so the lock screen can steer to recovery
    /// instead of dead-ending on an Unlock button that can never prompt.
    func hasStoredIdentity() -> Bool
    /// Same as `load()` but WITHOUT the Touch ID / password gate.
    ///
    /// Exactly one production caller: the launch-time unlock a user opts into
    /// by turning off "Lock when Sealshot starts". Named this bluntly on
    /// purpose — a promptless read of the identity key should be obvious in a
    /// diff and trivially greppable during a security audit. Do not route
    /// ordinary unlocks through it.
    ///
    /// Synchronous by design, and deliberately left without a default
    /// implementation: it runs before the first window exists (an async hop
    /// would let the lock overlay flash for a frame on every launch), and
    /// every conformer should have to decide what a promptless read means for
    /// it rather than inherit one silently.
    func loadWithoutUserPresence() throws -> IdentityKey?
    func delete() throws

    // Generation-scoped variants. Production (session / provisioner / recovery)
    // uses these so each generation binds to its OWN keychain item — two
    // generations can coexist without clobbering each other, the precondition
    // for safe recovery/rotation. The default implementations below are
    // generation-agnostic (correct for in-memory/test stores); the Keychain
    // store overrides them to use a per-generation item.
    func save(_ identity: IdentityKey, for generation: KeyGeneration) throws
    func load(for generation: KeyGeneration) async throws -> IdentityKey?
    func loadWithoutUserPresence(for generation: KeyGeneration) throws -> IdentityKey?
    func hasStoredIdentity(for generation: KeyGeneration) -> Bool
    func delete(for generation: KeyGeneration) throws
}

extension IdentityStore {
    func save(_ identity: IdentityKey, for generation: KeyGeneration) throws { try save(identity) }
    func load(for generation: KeyGeneration) async throws -> IdentityKey? { try await load() }
    func loadWithoutUserPresence(for generation: KeyGeneration) throws -> IdentityKey? {
        try loadWithoutUserPresence()
    }
    func hasStoredIdentity(for generation: KeyGeneration) -> Bool { hasStoredIdentity() }
    func delete(for generation: KeyGeneration) throws { try delete() }
}

/// Test/preview implementation — no Keychain, no prompts. Mirrors the Keychain
/// store's generation-awareness: a legacy single slot plus per-generation slots,
/// so two generations coexist (and rotation's `delete(for: oldGen)` leaves the new
/// one intact). The per-generation reads fall back to the legacy slot, so tests
/// that just `save(identity)` and `load(for:)` still work.
final class InMemoryIdentityStore: IdentityStore {
    private var legacy: Data?
    private var perGeneration: [UUID: Data] = [:]

    func save(_ identity: IdentityKey) throws { legacy = identity.rawRepresentation }
    /// No-arg load reads the legacy slot, falling back to any per-generation slot
    /// (so tests that `save(_:for:)` then `load()` still find the identity).
    func load() async throws -> IdentityKey? {
        guard let raw = legacy ?? perGeneration.values.first else { return nil }
        return try IdentityKey(rawRepresentation: raw)
    }
    /// Nothing to skip — this store never prompts — so it mirrors `load()`.
    func loadWithoutUserPresence() throws -> IdentityKey? {
        guard let raw = legacy ?? perGeneration.values.first else { return nil }
        return try IdentityKey(rawRepresentation: raw)
    }
    func loadWithoutUserPresence(for generation: KeyGeneration) throws -> IdentityKey? {
        if let raw = perGeneration[generation.id] { return try IdentityKey(rawRepresentation: raw) }
        return try loadWithoutUserPresence()
    }
    func hasStoredIdentity() -> Bool { legacy != nil || !perGeneration.isEmpty }
    /// No-arg delete clears EVERYTHING (legacy + all generations) — tests use it
    /// to simulate "the key is gone from this Mac".
    func delete() throws { legacy = nil; perGeneration.removeAll() }

    func save(_ identity: IdentityKey, for generation: KeyGeneration) throws {
        perGeneration[generation.id] = identity.rawRepresentation
    }
    func load(for generation: KeyGeneration) async throws -> IdentityKey? {
        if let raw = perGeneration[generation.id] { return try IdentityKey(rawRepresentation: raw) }
        return try await load()
    }
    func hasStoredIdentity(for generation: KeyGeneration) -> Bool {
        perGeneration[generation.id] != nil || legacy != nil
    }
    func delete(for generation: KeyGeneration) throws { perGeneration[generation.id] = nil }
}

/// Production store: a generic-password Keychain item (this-device-only, not
/// synced/backed-up) gated by an APP-ENFORCED Touch ID / password check in
/// `load()`. NOTE: the biometric gate is enforced by this app via LAContext,
/// NOT by the OS at the Keychain layer — there is no Secure-Enclave ACL on
/// the item (that path needs a keychain-access-groups entitlement +
/// provisioning, which fails on locally-signed builds). An attacker already
/// executing code as the logged-in user could read the item without the
/// prompt; the gate defends against someone at an unlocked machine, not
/// against in-process compromise. See the spec's threat-model note.
final class KeychainIdentityStore: IdentityStore {
    enum Error: Swift.Error { case unexpectedStatus(OSStatus) }

    private let service = "com.seal-shot.sealshot.identity"
    /// Legacy single-slot account (no-arg API). Generation-scoped items use
    /// `account(for:)` so multiple generations coexist.
    private let legacyAccount = "identity-x25519"
    private func account(for generation: KeyGeneration) -> String {
        "identity-x25519-\(generation.id.uuidString)"
    }

    // MARK: - No-arg (legacy slot)

    func save(_ identity: IdentityKey) throws { try save(identity, account: legacyAccount) }
    func load() async throws -> IdentityKey? { try await load(account: legacyAccount) }
    func loadWithoutUserPresence() throws -> IdentityKey? {
        try read(account: legacyAccount)
    }
    func hasStoredIdentity() -> Bool { itemExists(account: legacyAccount) }
    func delete() throws { try delete(account: legacyAccount) }

    // MARK: - Generation-scoped

    func save(_ identity: IdentityKey, for generation: KeyGeneration) throws {
        try save(identity, account: account(for: generation))
    }
    func load(for generation: KeyGeneration) async throws -> IdentityKey? {
        try await load(account: account(for: generation))
    }
    func loadWithoutUserPresence(for generation: KeyGeneration) throws -> IdentityKey? {
        try read(account: account(for: generation))
    }
    func hasStoredIdentity(for generation: KeyGeneration) -> Bool {
        itemExists(account: account(for: generation))
    }
    func delete(for generation: KeyGeneration) throws {
        try delete(account: account(for: generation))
    }

    // MARK: - Account-parameterized implementation

    private func save(_ identity: IdentityKey, account: String) throws {
        try? delete(account: account)
        // Plain this-device-only item — NO SecAccessControl. An access-control
        // object would force the data-protection keychain, which needs a
        // keychain-access-groups entitlement + provisioning profile and fails
        // with errSecMissingEntitlement (-34018) on locally-signed builds.
        // The Touch ID gate is enforced by load() via LAContext instead.
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: identity.rawRepresentation,
        ]
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else { throw Error.unexpectedStatus(status) }
    }

    private func load(account: String) async throws -> IdentityKey? {
        // No prompt when there's nothing to unlock: check existence first.
        guard itemExists(account: account) else { return nil }
        // App-enforced biometric/password gate (no Secure-Enclave ACL on the
        // item — see save()). Cancel/failure → nil (stay locked).
        guard await authenticate() else { return nil }
        return try read(account: account)
    }

    /// The bare Keychain read, with NO auth gate in front of it. Two callers:
    /// `load()`, which gates first, and `loadWithoutUserPresence()`, which is
    /// the launch unlock the user explicitly opted into. Because the item
    /// carries no `SecAccessControl` (see `save()`), this succeeds unprompted
    /// — the key is still this-device-only and still needs the macOS account
    /// to be logged in.
    private func read(account: String) throws -> IdentityKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return try IdentityKey(rawRepresentation: data)
        case errSecItemNotFound:
            return nil
        default:
            throw Error.unexpectedStatus(status)
        }
    }

    /// Existence probe with no data return and no auth — never prompts.
    private func itemExists(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: false,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// Touch ID (or Apple Watch / account password) via LocalAuthentication.
    /// `.deviceOwnerAuthentication` falls back to password on Macs without
    /// biometrics. Returns false on cancel or failure.
    private func authenticate() async -> Bool {
        let context = LAContext()
        let reason = "Unlock your encrypted captures"
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else {
            // No biometric/password available to evaluate — treat as denied
            // rather than silently bypassing the gate.
            return false
        }
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in
                continuation.resume(returning: ok)
            }
        }
    }

    private func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Error.unexpectedStatus(status)
        }
    }
}
