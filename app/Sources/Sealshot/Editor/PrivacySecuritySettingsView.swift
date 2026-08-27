import SwiftUI

/// Settings → Privacy & Security card. Hosts the encryption toggle, runs the
/// EncryptionToggleModel, and presents the recovery-key ceremony + disable
/// confirmation. The toggle reflects model.phase, never a naked bool.
struct PrivacySecuritySettingsView: View {
    @State private var model: EncryptionToggleModel
    @State private var showEnableConfirm = false
    @State private var showDisableConfirm = false
    @State private var showRegenerateConfirm = false
    @State private var showRotateConfirm = false
    @State private var showArchiveRestore = false
    /// Locked Archive snapshot — the row shows only while the archive holds a
    /// restorable keystore seed. Refreshed on appear and after the restore
    /// sheet closes.
    @State private var archiveStatus = LockedArchiveRestore.Status(
        archivedPackages: 0, hasKeystore: false)
    @State private var showLaunchLockOffConfirm = false
    /// Mirrors `RecordingWrapperPreference`'s opt-out key. Read here so the
    /// enable-encryption dialog can warn that recordings are exempt.
    @AppStorage("RecordingSavesPlainMovie") private var savesPlainMovie = false
    /// Mirrors `LaunchLockPreference` in view state. A Toggle bound straight to
    /// UserDefaults has nothing observable behind it, so the switch can fail to
    /// re-render after a write (and after a cancelled dialog it must visibly
    /// stay put) — the mirror is what SwiftUI actually watches.
    @State private var locksAtLaunch = LaunchLockPreference().locksAtLaunch
    // `let` works because IdleLockPreference.minutes uses a nonmutating set.
    private let idlePref = IdleLockPreference()
    private let launchLockPref = LaunchLockPreference()
    private let saveFolder: URL

    init(saveFolder: URL) {
        self.saveFolder = saveFolder
        _model = State(initialValue: EncryptionToggleModel(saveFolder: saveFolder))
    }

    private var isEnabled: Bool {
        if case .idle(let enabled) = model.phase { return enabled }
        if case .showingRecoveryCode = model.phase { return true }
        if case .working = model.phase { return true }
        return EncryptionSession.shared.isEnabled
    }

    private var isBusy: Bool {
        if case .working = model.phase { return true }
        return false
    }

    var body: some View {
        SettingsCard("Privacy & Security") {
            SettingsRow("Enhanced security",
                        "Encrypts everything Sealshot stores on this Mac and locks viewing behind Touch ID.") {
                Toggle("", isOn: Binding(
                    get: { isEnabled },
                    set: { wantOn in
                        if wantOn { showEnableConfirm = true }
                        else { showDisableConfirm = true }
                    }))
                .labelsHidden().toggleStyle(.switch).disabled(isBusy)
            }
            SettingsDivider()
            whenOnExplanation
            if isBusy, let p = model.lastProgress, p.total > 0 {
                SettingsDivider()
                SettingsRow(workingVerb) {
                    ProgressView(value: Double(p.done), total: Double(p.total))
                        .frame(width: 160)
                }
            }
            if model.canResume {
                SettingsDivider()
                SettingsRow("Some captures weren't encrypted", failedMessage) {
                    Button("Resume") { Task { await model.resume() } }
                }
            }
            // Status + recovery code + idle-lock — only when encryption is on and
            // not mid-operation.
            if isEnabled && !isBusy {
                if let status = model.statusSummary {
                    SettingsDivider()
                    SettingsRow("Status", status) { EmptyView() }
                }
                SettingsDivider()
                SettingsRow("Recovery code",
                            "View your recovery code, or generate a new one (the old one stops working).") {
                    HStack(spacing: 8) {
                        Button("View…") { Task { await model.viewRecoveryCode() } }
                        Button("Generate New…") { showRegenerateConfirm = true }
                    }
                }
                SettingsDivider()
                SettingsRow("Replace encryption key",
                            "Rotate to a brand-new key if you think the old key or recovery code was exposed. Your captures stay readable; the old key and recovery code stop working.") {
                    Button("Replace Key…") { showRotateConfirm = true }
                }
                SettingsDivider()
                // The active idle timer that reads this preference is a follow-up;
                // this row persists the setting now so RelockController can honour it.
                SettingsRow("Auto-lock when idle",
                            "Lock automatically after a period of inactivity.") {
                    Picker("", selection: idleLockBinding) {
                        Text("Off").tag(0)
                        Text("1 min").tag(1)
                        Text("5 min").tag(5)
                        Text("15 min").tag(15)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                }
                SettingsDivider()
                SettingsRow("Lock when Sealshot starts",
                            "Require Touch ID each time Sealshot opens. When off, Sealshot opens ready to use — your captures stay encrypted on disk, but anyone using this Mac can view them.") {
                    Toggle("", isOn: Binding(
                        get: { locksAtLaunch },
                        set: { wantOn in
                            if wantOn {
                                setLocksAtLaunch(true)      // tightening: no ceremony
                            } else {
                                showLaunchLockOffConfirm = true
                            }
                        }))
                    .labelsHidden().toggleStyle(.switch)
                }
            }
            // Locked Archive restore — independent of the encryption toggle:
            // the archive can hold restorable items whether or not encryption
            // is currently on (the guided reset turns it off; the user may or
            // may not have re-enabled it since).
            if archiveStatus.hasKeystore {
                SettingsDivider()
                SettingsRow("Locked Archive", lockedArchiveDescription) {
                    Button("Restore…") { showArchiveRestore = true }
                }
            }
        }
        .onAppear {
            refreshArchiveStatus()
            // Re-read on appear: the preference can change elsewhere (a
            // re-enable resets it) while this view is alive but off-screen.
            locksAtLaunch = launchLockPref.locksAtLaunch
        }
        // The archive can change independently of this sheet — e.g. a
        // guided lockout reset or a disable-time quarantine run from the
        // lock screen while this pane sits in the background — so refresh
        // on the shared lock-state notification too, not just on appear.
        .onReceive(NotificationCenter.default.publisher(for: .encryptionLockStateDidChange)) { _ in
            refreshArchiveStatus()
        }
        .sheet(isPresented: $showArchiveRestore) {
            LockedArchiveRestoreView(saveFolder: saveFolder) { _ in
                showArchiveRestore = false
                refreshArchiveStatus()
            }
        }
        .sheet(isPresented: showingRecoveryBinding) {
            if case .showingRecoveryCode(let code) = model.phase {
                RecoveryKeyCeremonyView(code: code) { model.acknowledgeRecoveryCode() }
            }
        }
        .confirmationDialog("Turn on Enhanced security?", isPresented: $showEnableConfirm) {
            Button("Turn On") { Task { await model.enable() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            // The plain-movie recording setting survives turning encryption on,
            // and silently exempts every future recording — a screen recording
            // is often the most sensitive capture someone owns. Say so here,
            // where the user is deciding, rather than letting "encrypts
            // everything" stand when it isn't true.
            Text(savesPlainMovie
                 ? "This encrypts everything Sealshot stores on this Mac and locks viewing behind Touch ID — EXCEPT recordings. Settings ▸ Recording is set to save those as movie files, which are always written unencrypted. Switch it to Package to encrypt them too."
                 : "This encrypts everything Sealshot stores on this Mac and locks viewing behind Touch ID.")
        }
        .confirmationDialog("Turn off Enhanced security?", isPresented: $showDisableConfirm) {
            Button("Turn Off", role: .destructive) { Task { await model.disable() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your captures will no longer be encrypted on this Mac, and viewing won't require Touch ID.")
        }
        .confirmationDialog("Turn off lock at startup?", isPresented: $showLaunchLockOffConfirm) {
            Button("Turn Off", role: .destructive) { setLocksAtLaunch(false) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Sealshot will open ready to use, without asking for Touch ID. Your captures stay encrypted on disk, but anyone using this Mac can open Sealshot and view them.")
        }
        .confirmationDialog("Generate a new recovery code?", isPresented: $showRegenerateConfirm) {
            Button("Generate New Code", role: .destructive) { Task { await model.regenerateRecoveryCode() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your current recovery code will stop working. Save the new one somewhere safe.")
        }
        .confirmationDialog("Replace your encryption key?", isPresented: $showRotateConfirm) {
            Button("Replace Key", role: .destructive) { Task { await model.rotateKey() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your captures are re-keyed to a new key and stay readable. The old key and recovery code stop working, and you'll get a new recovery code to save.")
        }
        .alert("Encryption error", isPresented: showingErrorBinding) {
            Button("OK") { model.dismissError() }
        } message: { Text(failedMessage) }
    }

    private var lockedArchiveDescription: String {
        let n = archiveStatus.archivedPackages
        return "\(n) item\(n == 1 ? "" : "s") from a previous reset. Restore with the recovery code from before that reset."
    }

    private func refreshArchiveStatus() {
        archiveStatus = LockedArchiveRestore.status(saveFolder: saveFolder)
    }

    private var workingVerb: String {
        if case .working(let v) = model.phase { return v }
        return ""
    }

    private var failedMessage: String {
        if case .failed(let m) = model.phase { return m }
        return ""
    }

    private var showingRecoveryBinding: Binding<Bool> {
        Binding(
            get: { if case .showingRecoveryCode = model.phase { return true }; return false },
            set: { _ in })
    }

    private var showingErrorBinding: Binding<Bool> {
        Binding(
            get: { if case .failed = model.phase { return true }; return false },
            set: { if !$0 { model.dismissError() } })
    }

    /// Single writer for the launch-lock preference: store first, then mirror,
    /// so a cancelled confirmation leaves both untouched and the switch visibly
    /// stays on.
    private func setLocksAtLaunch(_ newValue: Bool) {
        launchLockPref.locksAtLaunch = newValue
        locksAtLaunch = newValue
    }

    private var idleLockBinding: Binding<Int> {
        Binding(
            get: { idlePref.minutes },
            set: { idlePref.minutes = $0 })
    }

    /// What the toggle changes, spelled out — visible in both states so the
    /// user knows what they're enabling (or already have). Lists only what
    /// the toggle itself controls: Spotlight exclusion and folder
    /// permissions are applied at launch regardless (StorageHardening), and
    /// auto-lock has its own row.
    private var whenOnBullets: [String] {
        var bullets = [
            "Stored captures are encrypted on disk",
            "The search index, undo history, and extracted text are encrypted too",
            "Viewing requires Touch ID, Apple Watch, or your Mac's password — capturing always works, even while locked",
            "A recovery key is shown once at setup, in case this Mac's keys are ever lost",
        ]
        // The exemption belongs in the standing list, not only in the dialog
        // that turns encryption on: someone who set movie files months ago
        // needs to see it whenever they read this card.
        if savesPlainMovie {
            bullets.append("EXCEPT recordings — Settings ▸ Recording saves those as movie files, which are never encrypted")
        }
        return bullets
    }

    private var whenOnExplanation: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("When on:")
            ForEach(whenOnBullets, id: \.self) { bullet in
                HStack(alignment: .top, spacing: 6) {
                    Text("•")
                    Text(bullet)
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
