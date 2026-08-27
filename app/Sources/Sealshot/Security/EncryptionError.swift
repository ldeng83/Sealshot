import Foundation

/// Typed encryption-layer failures. The key one for the generation-aware model
/// is `generationMismatch`: a capsule stamped with a generation other than the
/// active one. Surfacing it as a catchable, typed error — instead of letting an
/// opaque `CryptoKitError.authenticationFailure` escape `contentKey(for:)` —
/// is what lets callers (and sub-project #2's always-can-disable) react to a
/// diverged library instead of crashing on it.
enum EncryptionError: Error, Equatable {
    /// A stored capsule belongs to a different generation than the active one.
    case generationMismatch(expected: UUID, found: UUID)
}
