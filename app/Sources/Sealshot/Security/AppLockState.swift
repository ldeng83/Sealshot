import AppKit
import Combine

/// One observable source of truth for "is the app locked" — encryption is ON and
/// the session isn't unlocked. Menus and commands bind to `isLocked` to disable
/// actions that touch existing/decrypted content while locked (soft lock: new
/// captures/recordings stay enabled, writing a write-only encrypted `.seal`).
@MainActor
final class AppLockState: ObservableObject {
    static let shared = AppLockState()

    @Published private(set) var isLocked: Bool = AppLockState.compute()

    private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: .encryptionLockStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.isLocked = AppLockState.compute() }
        }
    }

    private static func compute() -> Bool {
        EncryptionSession.shared.isEnabled && !EncryptionSession.shared.isUnlocked
    }
}
