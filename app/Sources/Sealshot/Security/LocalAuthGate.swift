import Foundation
import LocalAuthentication

/// Gates a sensitive action behind a fresh device-owner authentication (Touch
/// ID / Apple Watch / the Mac's password). Injectable so callers stay testable
/// without triggering a real biometric prompt.
@MainActor
protocol LocalAuthenticating {
    /// Returns true only if the owner authenticates. `reason` is shown in the
    /// system prompt. Returns false on cancel, failure, or when no
    /// biometric/password is available to evaluate (fail closed).
    func authenticate(reason: String) async -> Bool
}

/// Production gate. Uses a FRESH `LAContext` every call (no reuse window) so it
/// always prompts — even when the encryption session is already unlocked, which
/// is exactly the case we want to re-verify before changing the security state.
/// `.deviceOwnerAuthentication` falls back to the account password on Macs
/// without biometrics.
@MainActor
struct LocalAuthGate: LocalAuthenticating {
    /// Stateless, so it can be a default argument in a nonisolated context.
    nonisolated init() {}

    func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else {
            return false   // nothing to evaluate — deny rather than silently bypass
        }
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in
                continuation.resume(returning: ok)
            }
        }
    }
}
