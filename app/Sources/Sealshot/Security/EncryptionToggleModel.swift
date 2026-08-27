import Foundation
import os.log

private let log = OSLog(subsystem: "com.seal-shot.sealshot", category: "encryption-toggle")

/// Observable state machine the Settings card binds to. All enable/disable
/// logic lives here (the view is a thin projection), so it is fully testable
/// with an injected session + identity store + temp save folder.
@Observable
@MainActor
final class EncryptionToggleModel {
    enum Phase: Equatable, CustomStringConvertible {
        case idle(enabled: Bool)
        case working(verb: String)
        case showingRecoveryCode(String)
        case failed(message: String)

        /// Redacts the recovery code so it never reaches logs or test output
        /// via string interpolation.
        var description: String {
            switch self {
            case .idle(let e): return "idle(enabled: \(e))"
            case .working(let v): return "working(\(v))"
            case .showingRecoveryCode: return "showingRecoveryCode(<redacted>)"
            case .failed(let m): return "failed(\(m))"
            }
        }
    }

    struct Progress: Equatable { let done: Int; let total: Int }

    private(set) var phase: Phase {
        didSet {
            // Mirror the "navigation should stay locked" state onto the shared
            // session so the shell can lock the top tabs + Settings sidebar. This
            // covers BOTH the migration (`.working`) AND the recovery-code ceremony
            // (`.showingRecoveryCode`): the enable flow presents the recovery sheet
            // the instant the migration ends, so if we cleared the lock at
            // `.working → .showingRecoveryCode`, the tab re-enable would land under
            // the modal sheet and be lost, and clearing again at `.idle` wouldn't
            // re-fire (the flag never changed). Holding the lock until `.idle`
            // means it clears exactly when the sheet is dismissed — re-enabling the
            // tabs with no sheet in the way — and also stops the user navigating
            // away mid-ceremony.
            let locked: Bool = {
                switch phase {
                case .working, .showingRecoveryCode: return true
                case .idle, .failed: return false
                }
            }()
            session.operationInProgress = locked
        }
    }
    private(set) var lastProgress: Progress?
    /// True after a partial enable (migrationIncomplete) — UI shows "Resume".
    private(set) var canResume = false

    @ObservationIgnored private let saveFolder: URL
    @ObservationIgnored private let session: EncryptionSession
    @ObservationIgnored private let identityStore: IdentityStore
    @ObservationIgnored private let authenticator: LocalAuthenticating
    @ObservationIgnored private let authorization: PrivacyAuthorizing
    @ObservationIgnored private let launchLock: LaunchLockPreference

    init(saveFolder: URL, session: EncryptionSession? = nil,
         identityStore: IdentityStore = KeychainIdentityStore(),
         authenticator: LocalAuthenticating = LocalAuthGate(),
         authorization: PrivacyAuthorizing? = nil,
         launchLock: LaunchLockPreference = LaunchLockPreference()) {
        self.saveFolder = saveFolder
        self.launchLock = launchLock
        let resolvedSession = session ?? EncryptionSession.shared
        self.session = resolvedSession
        self.identityStore = identityStore
        self.authenticator = authenticator
        // Resolved here (not as a default arg) because the shared instance is
        // @MainActor-isolated and default arguments evaluate nonisolated.
        self.authorization = authorization ?? PrivacyAuthorization.shared
        self.phase = .idle(enabled: resolvedSession.isEnabled)
        // NOTE: didSet does not fire for the assignment above (init), so a new
        // model never writes the mirror flag here. Deliberate: clearing it in
        // init would un-gate the tabs if a replacement model is created while a
        // PREVIOUS model's migration is still running (task-retained, view
        // torn down). The stale-flag case is handled by deinit instead.
    }

    /// The model lives as @State inside the Privacy settings card, which gets
    /// torn down whenever the page's owner-authorization lapses (locked
    /// placeholder swap) or the window closes. If that happens while phase is
    /// `.showingRecoveryCode`, nothing else would ever clear the mirrored
    /// flag — permanently disabling the tab switcher. A running migration
    /// can't hit this: its Task retains the model until a terminal phase.
    deinit {
        let session = self.session
        Task { @MainActor in session.operationInProgress = false }
    }

    /// The security boundary for any sensitive Privacy & Security operation.
    /// Honors a standing page-level authorization (so the page gate's single
    /// prompt covers this) but falls back to a fresh owner check when there is
    /// none — so a direct or future call site can't change posture unauthenticated.
    /// Fails closed.
    private func ensureAuthorized(reason: String) async -> Bool {
        if authorization.isAuthorized { return true }
        guard await authenticator.authenticate(reason: reason) else { return false }
        // A fresh check that passed IS a full owner authentication — stamp the
        // shared window so the page and its other controls unlock with it.
        authorization.grant()
        return true
    }

    /// Progress sink handed to the migrators. `SealMigrator`/`RecordingsMigrator`
    /// are nonisolated and run OFF the main actor, so this fires off-main — hop to
    /// the main actor so the observed `lastProgress` actually drives the SwiftUI
    /// progress bar. The main queue is FIFO, so the ordered per-file updates stay
    /// ordered (no backward flicker).
    private nonisolated func reportProgress(_ done: Int, _ total: Int) {
        DispatchQueue.main.async { [weak self] in
            self?.lastProgress = Progress(done: done, total: total)
        }
    }

    func enable() async {
        guard await ensureAuthorized(reason: "Authenticate to turn on Enhanced security") else {
            phase = .idle(enabled: session.isEnabled)
            return
        }
        phase = .working(verb: "Encrypting your library…")
        lastProgress = nil   // clear the previous run's value so the bar starts empty, not full
        canResume = false
        do {
            let code = try await EncryptionProvisioner.enable(
                saveFolder: saveFolder, session: session, identityStore: identityStore,
                progress: reportProgress)
            // A fresh security setup starts from the safe default: never
            // inherit "don't lock at launch" from a previous, now-retired key.
            launchLock.locksAtLaunch = true
            phase = .showingRecoveryCode(code)
        } catch let err as SealMigrator.Error {
            if case .migrationIncomplete(let failed, let converted) = err {
                canResume = true
                lastProgress = Progress(done: converted, total: converted + failed.count)
                phase = .failed(message: "\(failed.count) capture\(failed.count == 1 ? "" : "s") couldn't be encrypted. Fix them and resume.")
            } else {
                phase = .failed(message: String(describing: err))
            }
        } catch {
            phase = .failed(message: String(describing: error))
        }
    }

    /// User confirmed they saved the recovery code.
    func acknowledgeRecoveryCode() {
        phase = .idle(enabled: session.isEnabled)
    }

    func resume() async {
        phase = .working(verb: "Encrypting remaining captures…")
        lastProgress = nil
        do {
            try await EncryptionProvisioner.resumeMigration(
                saveFolder: saveFolder, session: session, progress: reportProgress)
            canResume = false
            phase = .idle(enabled: session.isEnabled)
        } catch let err as SealMigrator.Error {
            if case .migrationIncomplete(let failed, _) = err {
                phase = .failed(message: "\(failed.count) capture\(failed.count == 1 ? "" : "s") still couldn't be encrypted.")
            } else {
                phase = .failed(message: String(describing: err))
            }
        } catch {
            phase = .failed(message: String(describing: error))
        }
    }

    func disable() async {
        guard await ensureAuthorized(reason: "Authenticate to turn off Enhanced security") else {
            phase = .idle(enabled: session.isEnabled)
            return
        }
        phase = .working(verb: "Decrypting your library…")
        lastProgress = nil
        // disable() always succeeds — it decrypts what it can and quarantines the
        // rest. There is no failure path and no lockedOut dead-end any more.
        let summary = await EncryptionProvisioner.disable(
            saveFolder: saveFolder, session: session, identityStore: identityStore,
            progress: reportProgress)
        canResume = false   // a prior partial-enable's resume affordance is now moot
        if summary.quarantined > 0 {
            let n = summary.quarantined
            phase = .failed(message: "Encryption is off. \(n) capture\(n == 1 ? "" : "s") couldn’t be decrypted and \(n == 1 ? "was" : "were") moved — NOT deleted — to the “\(Quarantine.folderName)” folder in your save location. \(n == 1 ? "Its" : "Their") encrypted contents are intact and may be recoverable, so keep that folder unless you’re sure you don’t need \(n == 1 ? "it" : "them").")
        } else {
            phase = .idle(enabled: false)
        }
    }

    /// A one-line health summary for the Privacy & Security status row (nil when
    /// the feature is off). Read on body re-evaluation, like the toggle itself.
    var statusSummary: String? {
        session.consistencyStatus(saveFolder: saveFolder).settingsSummary
    }

    /// Reveal the existing recovery code (re-using the ceremony view via
    /// `.showingRecoveryCode`). Reached only from the page-auth-gated page.
    func viewRecoveryCode() async {
        guard await ensureAuthorized(reason: "Authenticate to view your recovery code") else { return }
        phase = .working(verb: "Retrieving your recovery code…")
        if let code = await EncryptionProvisioner.viewRecoveryCode(saveFolder: saveFolder, session: session) {
            phase = .showingRecoveryCode(code)
        } else {
            phase = .failed(message: "Couldn’t retrieve your recovery code on this Mac.")
        }
    }

    /// Rotate to a brand-new recovery code (the old one stops working) and show it.
    func regenerateRecoveryCode() async {
        guard await ensureAuthorized(reason: "Authenticate to generate a new recovery code") else { return }
        phase = .working(verb: "Generating a new recovery code…")
        if let code = await EncryptionProvisioner.regenerateRecoveryCode(saveFolder: saveFolder, session: session) {
            phase = .showingRecoveryCode(code)
        } else {
            phase = .failed(message: "Couldn’t generate a new recovery code on this Mac.")
        }
    }

    /// Rotate to a fresh identity + recovery code (revoking the old ones),
    /// re-keying all data forward, and show the new code. Page-auth-gated.
    func rotateKey() async {
        guard await ensureAuthorized(reason: "Authenticate to replace your encryption key") else { return }
        phase = .working(verb: "Replacing your encryption key…")
        if let summary = await EncryptionProvisioner.rotateKey(
            saveFolder: saveFolder, session: session, identityStore: identityStore) {
            phase = .showingRecoveryCode(summary.newRecoveryCode)
        } else {
            phase = .failed(message: "Couldn’t replace the encryption key. Unlock this Mac’s key first, then try again.")
        }
    }

    /// Dismiss a failure back to the current real state.
    func dismissError() {
        canResume = false
        phase = .idle(enabled: session.isEnabled)
    }
}
