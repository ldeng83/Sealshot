import SwiftUI
import AppKit
import ServiceManagement
import KeyboardShortcuts
import os.log

private let log = OSLog(subsystem: "com.seal-shot.sealshot", category: "settings")

/// The Settings tab: a section sidebar + card-grouped rows over the editor's
/// beehive backdrop. Each section is a titled card of title/subtitle rows with
/// a trailing control, divided by hairlines.
struct SettingsView: View {
    @Bindable var config: CaptureConfig

    enum Section: String, CaseIterable, Identifiable {
        case general = "General", capture = "Capture", recording = "Recording"
        case ai = "On-Device AI", shortcuts = "Shortcuts"
        // The case keeps its `license` name — the deep link and a dozen call
        // sites use it, and renaming a symbol is not worth the churn for a tab
        // label. The raw value IS the label (nothing persists it).
        case permissions = "Permissions", license = "Support"
        case privacy = "Privacy & Security", about = "About"
        var id: String { rawValue }

        /// Tabs whose header offers a Reset button (each resets exactly what
        /// it shows). Permissions/License/About have nothing to reset;
        /// Privacy & Security is stateful (encryption) and manages itself.
        var isResettable: Bool {
            switch self {
            case .general, .ai, .capture, .recording, .shortcuts: return true
            case .permissions, .license, .privacy, .about: return false
            }
        }
        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .ai: return "sparkles"
            case .capture: return "camera"
            case .recording: return "video"
            case .shortcuts: return "command"
            case .permissions: return "lock.shield"
            case .license: return "heart"
            case .privacy: return "lock.fill"
            case .about: return "info.circle"
            }
        }

        /// Tabs shown in the sidebar. License is Direct-only — the MAS build
        /// is always licensed via the App Store, so there's nothing to manage.
        static var visible: [Section] {
            AppInfo.edition == .direct ? allCases : allCases.filter { $0 != .license }
        }
    }

    @State private var section: Section = .general
    /// Published mirror of the login-item registration. Observed so the switch
    /// re-renders when the status changes — including from outside the app.
    @ObservedObject private var launchAtLogin = LaunchAtLoginModel.shared
    // Observed so the automatic-update switch re-reads the real preference
    // instead of keeping whatever a SwiftUI Toggle last drew.
    @ObservedObject private var updater = UpdaterController.shared
    /// Mirror of `WelcomePreference.tourEnabled()` — see `welcomeTourBinding`.
    @State private var welcomeTourOn = WelcomePreference.tourEnabled()
    @State private var showResetConfirm = false
    /// Non-nil presents the duplicate-shortcut alert (set by rejectIfDuplicate).
    @State private var duplicateShortcutMessage: String?
    /// Bindings snapshotted when a recorder starts recording, so a rejected
    /// duplicate restores the row's PREVIOUS key instead of clearing it.
    @State private var shortcutsBeforeRecording: [KeyboardShortcuts.Name: KeyboardShortcuts.Shortcut] = [:]
    /// Remembers per-layout bindings, so switching tabs restores what the user
    /// left there instead of overwriting it with the table.
    private let layoutStore = ShortcutLayoutStore()
    /// The layout the picker shows. STORED, not inferred from the live keys: a
    /// hand-edited key belongs to the layout it was edited under, not to a third
    /// "Custom" state the user has to interpret.
    @State private var selectedLayout: ShortcutLayout = ShortcutLayoutStore().selected
    @State private var systemOwnsScreenshotKeys = SystemScreenshotHotkeys.systemStillOwnsAny
    @State private var showResetAllConfirm = false
    // Text mirror of config.retentionDays for the editable days field; committed
    // (parsed + clamped) on Enter or focus loss, never while typing.
    @State private var retentionDaysText = ""
    @FocusState private var retentionFieldFocused: Bool
    /// Set when enabling "Capture microphone" finds access denied — drives an
    /// alert that points the user to System Settings.
    @State private var micPermissionDenied = false
    /// Privacy & Security holds sensitive controls (Enhanced security, recovery
    /// code, key revocation). The whole page is gated behind one fresh device-owner
    /// auth — authenticate once to view it, and every action on it is covered.
    /// Reset whenever the user navigates away, so re-entering re-prompts.
    @State private var privacyUnlocked = false
    /// Recovery-code path for unlocking Privacy & Security (an alternative to
    /// the device-owner prompt). Shown only when a recovery keystore exists.
    @State private var showRecoveryUnlock = false
    @State private var recoveryCodeInput = ""
    @State private var recoveryUnlockError: String?
    @State private var verifyingRecoveryCode = false
    /// Bumped when `AIAvailabilityWatcher` reports that Apple Intelligence
    /// availability actually changed (e.g. the user turned it on and came
    /// back from System Settings), so the AI-status row's direct read of
    /// `AIAvailability.status` re-renders instead of going stale until some
    /// unrelated row happens to redraw.
    @State private var aiAvailabilityRefreshToken = 0

    // Recording controls are backed by @AppStorage rather than a plain
    // Binding(get:set:) over UserDefaults: the latter has no observable backing,
    // so the switches desynced from the stored value when the Settings window
    // deactivated (clicking another app), redrawing a toggle to its default even
    // though the persisted value was unchanged. Keys and defaults mirror
    // `RecordingPreference` (which the recorder reads at capture time), so the
    // stored value is identical — this only keeps the controls in sync.
    // Same key as FilenameIncludesTitlePreference (read at capture time);
    // default true mirrors the preference's own default.
    @AppStorage("FilenameIncludesTitle") private var filenameTitleOn = true
    // Same key + default as ScratchCapturePreference (read at capture time).
    @AppStorage(ScratchCapturePreference.key) private var capturesAddToLibrary = true
    @AppStorage(ScratchCapturePreference.recordingKey) private var recordingsAddToLibrary = true
    // Same key + default as AutoScrollPreference (read at capture time). Must
    // be observable state: the previous computed Binding read UserDefaults
    // directly, so SwiftUI never re-rendered after a tap and the switch
    // visually snapped back ON while the stored value was already off.
    @AppStorage(AutoScrollPreference.key) private var autoScrollOn = true

    @AppStorage("recording.format") private var recordingFormat: RecordingFormat = .hevcMov
    /// Mirrors `RecordingWrapperPreference` — the opt-out key, so false keeps
    /// the package wrapper every existing install already has.
    @AppStorage("RecordingSavesPlainMovie") private var savesPlainMovie = false
    @State private var showPlainMovieConfirm = false
    @AppStorage("recording.frameRate") private var recordingFrameRate = 30
    @AppStorage("recording.systemAudio") private var capturesSystemAudio = true
    @AppStorage("recording.microphone") private var capturesMicrophone = false
    @AppStorage("recording.reduceMicNoise") private var reducesMicNoise = true
    @AppStorage("recording.showsCursor") private var showsCursor = true
    @AppStorage("recording.askBeforeRecording") private var asksBeforeRecording = true

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 200)
            Divider()
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Plain backdrop behind the whole pane (the opaque sidebar covers the
        // left, the opaque header band covers the top).
        .background(Color(nsColor: Theme.backdropColor))
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Section.visible) { s in
                Button {
                    if s != .privacy {
                        // Leaving the page no longer re-locks immediately: the
                        // unlock holds for the shared 5-minute window and
                        // re-derives on return. Only clear the transient
                        // recovery-code entry UI.
                        showRecoveryUnlock = false
                        recoveryCodeInput = ""
                        recoveryUnlockError = nil
                    }
                    section = s
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: s.symbol).frame(width: 18)
                        Text(s.rawValue)
                        Spacer()
                    }
                    .padding(.vertical, 6).padding(.horizontal, 10)
                    .background(section == s ? Color.primary.opacity(0.08) : .clear,
                                in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        // Lock section navigation while an encrypt/decrypt operation runs, so the
        // user can't leave Privacy & Security mid-migration (the top tabs are
        // disabled in parallel by the window controller).
        .disabled(EncryptionSession.shared.operationInProgress)
    }

    private var detail: some View {
        // Header band reads as elevated chrome (surface); the beehive backdrop is
        // confined to the scrollable cards below — matching the editor, where the
        // header sits on surface and only the canvas carries the hex texture.
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(detailTitle).font(.title2.bold())
                Spacer()
                // Every resettable tab resets exactly what it shows; General
                // additionally offers the aggregate Reset All.
                if section.isResettable {
                    Button("Reset") { showResetConfirm = true }
                }
                if section == .general {
                    Button("Reset All") { showResetAllConfirm = true }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 28)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: Theme.surfaceColor))

            Divider()

            ScrollView {
                // The scroll content fills the full pane width so the scroll
                // indicator tracks the pane's right edge; the cards stay capped
                // at 680 and centered via the flanking Spacers.
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    VStack(alignment: .leading, spacing: 22) {
                        switch section {
                        case .general: generalSection
                        case .ai: aiSection
                        case .capture: captureSection
                        case .recording: recordingSection
                        case .shortcuts: shortcutsSection
                        case .permissions: permissionsSection
                        case .license: licenseSection
                        case .privacy:
                            privacyContent
                        case .about: aboutSection
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(28)
                    .frame(maxWidth: 680, alignment: .leading)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Let labels and descriptions be selected/copied like a web page.
            .textSelection(.enabled)
        }
        .confirmationDialog("Reset \(section.rawValue) settings to defaults?",
                            isPresented: $showResetConfirm) {
            Button("Reset", role: .destructive) { resetCurrentSection() }
            Button("Cancel", role: .cancel) {}
        } message: {
            if section == .general {
                Text("Includes the save location (back to \(CaptureConfig.defaultSaveFolder.path)).")
            }
        }
        .confirmationDialog("Reset all settings to defaults?",
                            isPresented: $showResetAllConfirm) {
            Button("Reset All", role: .destructive) {
                SettingsReset.resetAll(config: config)
                welcomeTourOn = WelcomePreference.tourEnabled()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Resets General, On-Device AI, Capture, Recording, and Shortcuts — including the save location. Privacy & Security and the downloaded redaction model are not affected.")
        }
        // Attached to THIS window (not a screen-centered NSAlert, which lands
        // on the main display — invisible when Settings sits on another
        // monitor of a multi-display setup).
        .alert("That shortcut is already in use",
               isPresented: Binding(
                   get: { duplicateShortcutMessage != nil },
                   set: { if !$0 { duplicateShortcutMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(duplicateShortcutMessage ?? "")
        }
        // While a recorder field is recording, truly UNREGISTER our global
        // hotkeys. The library only pauses its callbacks (isPaused) — the
        // Carbon registrations stay alive and consume the keystroke at the
        // system level, so recording a combo Sealshot already owns (e.g.
        // ⌘⇧C) never reached the field: no commit, no duplicate warning,
        // nothing. The notification is the library's recorder lifecycle
        // signal; missing it degrades to the old behavior, never a crash.
        .onReceive(NotificationCenter.default.publisher(
            for: Notification.Name("KeyboardShortcuts_recorderActiveStatusDidChange"))) { note in
            let active = (note.userInfo?["isActive"] as? Bool) ?? false
            let names = ShortcutCatalog.all.map(\.name)
            if active {
                // Snapshot every row's binding so a rejected duplicate can
                // put the edited row back to what it held before recording.
                shortcutsBeforeRecording = Dictionary(uniqueKeysWithValues:
                    names.compactMap { name in
                        KeyboardShortcuts.getShortcut(for: name).map { (name, $0) }
                    })
                KeyboardShortcuts.disable(names)
            } else {
                KeyboardShortcuts.enable(names)
            }
        }
        // Belt-and-suspenders: never leave the app's hotkeys unregistered if
        // the Settings pane goes away mid-recording.
        .onDisappear { KeyboardShortcuts.enable(ShortcutCatalog.all.map(\.name)) }
        // Deep-link from the support reminder's "I Already Donated" button —
        // jump straight to the License tab rather than leaving the user to
        // find it themselves.
        .onReceive(NotificationCenter.default.publisher(for: .openLicenseSettings)) { _ in
            consumePendingSection(fallback: .license)
        }
        // Deep-link from the recovery-verify nudge's "Generate New…" action —
        // same dual mechanism as the License tab above (final-review fix:
        // the nudge previously only queued SettingsDeepLink.pendingSection,
        // which a mounted SettingsView's .onAppear never re-fires, silently
        // dropping the deep-link whenever Settings was already open).
        .onReceive(NotificationCenter.default.publisher(for: .openPrivacySettings)) { _ in
            consumePendingSection(fallback: .privacy)
        }
        // The AI-status row reads AIAvailability.status directly, which is a
        // poll with no push of its own — bump the token whenever the watcher
        // confirms it actually changed (e.g. returning from System Settings
        // after turning Apple Intelligence on) so the row re-renders instead
        // of staying stale until some unrelated row happens to redraw.
        .onReceive(NotificationCenter.default.publisher(for: .aiAvailabilityDidChange)) { _ in
            aiAvailabilityRefreshToken &+= 1
        }
        // Carried-over fix (Task 7 review): the .onReceive handlers above
        // only land while this view is already mounted. If a gate fired
        // before Settings had ever been opened this session, the request was
        // queued in SettingsDeepLink — consume it here so the window still
        // opens straight onto the right tab.
        .onAppear {
            consumePendingSection()
            // Idempotent — safe even if an editor window already started it.
            AIAvailabilityWatcher.shared.start()
        }
    }

    /// Applies `SettingsDeepLink.pendingSection` and clears it — the pending
    /// value is set BEFORE any deep-link notification posts, so by the time
    /// a listener fires it normally holds the section that triggered it.
    /// `fallback` covers the (unexpected) case of a notification with no
    /// value queued, so a deep-link is never silently ignored; `.onAppear`
    /// passes no fallback since an ordinary launch has nothing pending.
    private func consumePendingSection(fallback: Section? = nil) {
        if let pending = SettingsDeepLink.pendingSection {
            section = pending
            SettingsDeepLink.pendingSection = nil
        } else if let fallback {
            section = fallback
        }
    }

    private func resetCurrentSection() {
        switch section {
        case .general:
            SettingsReset.resetGeneral(config: config)
            // Reset writes the welcome-tour flag behind the mirror's back.
            welcomeTourOn = WelcomePreference.tourEnabled()
        case .ai: SettingsReset.resetAI()
        case .capture: SettingsReset.resetCapture(config: config)
        case .recording: SettingsReset.resetRecording()
        case .shortcuts: SettingsReset.resetShortcuts()
        case .permissions, .license, .privacy, .about: break
        }
    }

    private var detailTitle: String {
        section == .general ? "General Settings" : section.rawValue
    }

    /// Commit the typed retention value: parse, clamp to the allowed range, and
    /// write back. The text is always rewritten from config afterward so junk
    /// input reverts and out-of-range input snaps to the bound — including when
    /// the clamped result equals the current value (where the days onChange
    /// wouldn't fire).
    private func commitRetentionDaysText() {
        let trimmed = retentionDaysText.trimmingCharacters(in: .whitespaces)
        if let typed = Int(trimmed) {
            config.retentionDays = CaptureConfig.clampedRetention(typed)
        }
        retentionDaysText = "\(config.retentionDays)"
    }

    // MARK: General

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsCard("Appearance") {
                SettingsRow("Theme", "Match the system, or force light or dark.") {
                    Picker("", selection: $config.appearancePreference) {
                        Text("System").tag(AppearancePreference.system)
                        Text("Light").tag(AppearancePreference.light)
                        Text("Dark").tag(AppearancePreference.dark)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                }
            }

            // Save location lives on General (not Capture): it directs where
            // BOTH image captures and screen recordings are stored.
            SettingsCard("Storage") {
                SettingsRow("Save location",
                            "Where captures and recordings are saved. \(config.saveFolder.path)") {
                    HStack(spacing: 8) {
                        Button("Choose…") { chooseSaveFolder() }
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([config.saveFolder])
                        }
                    }
                }
            }

            SettingsCard("Trash") {
                SettingsRow("Auto-delete trashed captures",
                            "Trashed captures are purged after this many days (1–365).") {
                    HStack(spacing: 6) {
                        TextField("", text: $retentionDaysText)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                            .frame(width: 52)
                            .focused($retentionFieldFocused)
                            .onSubmit { commitRetentionDaysText() }
                        Stepper(value: $config.retentionDays, in: CaptureConfig.retentionDaysRange) {
                            Text("day\(config.retentionDays == 1 ? "" : "s")")
                        }
                    }
                    .onAppear { retentionDaysText = "\(config.retentionDays)" }
                    .onChange(of: config.retentionDays) { _, days in
                        retentionDaysText = "\(days)"
                    }
                    .onChange(of: retentionFieldFocused) { _, focused in
                        if !focused { commitRetentionDaysText() }
                    }
                }
            }

            SettingsCard("Startup") {
                SettingsRow("Launch at login",
                            launchAtLogin.requiresApproval
                            ? "Allow Sealshot in System Settings › General › Login Items to finish turning this on."
                            : "Open Sealshot automatically when you log in.") {
                    Toggle("", isOn: launchAtLoginBinding).labelsHidden().toggleStyle(.switch)
                }
                .onAppear { launchAtLogin.refresh(context: "settingsAppear") }
                SettingsDivider()
                SettingsRow("Show welcome tour cards",
                            "Show the first-launch welcome tour at startup.") {
                    HStack(spacing: 12) {
                        // Opens the tour whatever the toggle says, and leaves
                        // the preference alone — "show it to me now" is not
                        // "show it at every startup".
                        Button("Show Now") {
                            // Settings is a tab inside the editor window, so the
                            // key window is the editor — the same parent the
                            // first-launch tour uses.
                            WelcomeTourPresenter.present(above: NSApp.keyWindow)
                        }
                        Toggle("", isOn: welcomeTourBinding).labelsHidden().toggleStyle(.switch)
                    }
                }
                .onAppear { welcomeTourOn = WelcomePreference.tourEnabled() }
            }

            // `updatesAreSupported` is the static capability flag (true only in
            // Direct builds); `canCheckForUpdates` is transient readiness and
            // gates only the button — never the card's existence.
            if UpdaterController.shared.updatesAreSupported {
                SettingsCard("Updates") {
                    SettingsRow("Automatically check for updates",
                                "Checks once a day. Update checks are Sealshot's only network activity.") {
                        Toggle("", isOn: autoUpdateBinding).labelsHidden().toggleStyle(.switch)
                    }
                    SettingsDivider()
                    SettingsRow("Version \(UpdaterController.shared.currentVersionString)") {
                        Button("Check Now") { updater.checkForUpdates() }
                            .disabled(!UpdaterController.shared.canCheckForUpdates)
                    }
                }
                // Same guard the Launch at login row uses: re-read on appear, so
                // returning to Settings never shows a stale switch.
                .onAppear { updater.refreshPublishedState() }
            }
        }
    }

    // MARK: On-Device AI

    /// Everything AI in one place: the master toggle, then the Smart Redaction
    /// features it powers (auto-scan, Thorough scan, the downloadable enhanced
    /// model). All engines — Apple Intelligence, the downloaded model, and the
    /// rule-based fallbacks — run entirely on this Mac.
    private var aiSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsCard("On-Device AI") {
                SettingsRow("Use on-device AI",
                            "Auto-generates titles, keywords, and summaries, and helps Smart Redaction "
                                + "catch sensitive info the rules miss. Uses Apple Intelligence on supported "
                                + "Macs, a built-in fallback elsewhere — all on this Mac. Tags you add "
                                + "yourself stay editable either way.") {
                    Toggle("", isOn: aiEnabledBinding).labelsHidden().toggleStyle(.switch)
                }
                // Why the Apple Intelligence half is or isn't running. Reads
                // aiEnabledLive (not the binding) so flipping the toggle above
                // re-evaluates this row immediately.
                if let nudge = AINudgePolicy.presentation(for: AIAvailability.status,
                                                          aiToggleOn: aiEnabledLive) {
                    SettingsDivider()
                    AIStatusRow(nudge: nudge)
                }
            }

            SettingsCard("Smart Redaction") {
                SettingsRow("Scan captures automatically",
                            "Looks for emails, phone numbers, credit cards, and API keys whenever an image opens, and proposes redactions. All detection runs on this Mac.") {
                    Toggle("", isOn: smartRedactionAutoScanBinding).labelsHidden().toggleStyle(.switch)
                }
                // Thorough scan is an AI-only feature (RedactionBackstopGate
                // requires the master toggle) — hidden entirely when AI is off.
                if aiEnabledLive {
                    SettingsDivider()
                    thoroughScanRow
                }
                SettingsDivider()
                RedactionModelSettingsRow()
            }
        }
    }

    private var captureSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsCard("Capture Defaults") {
                SettingsRow("Default destination", "Where captures go after you take them.") {
                    Picker("", selection: $config.defaultOutput) {
                        Text("Clipboard").tag(CaptureOutput.clipboard)
                        Text("File").tag(CaptureOutput.file)
                        Text("Both").tag(CaptureOutput.both)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                }
                SettingsDivider()
                SettingsRow("Filename format",
                            "The app and window name are added automatically. Example: \(config.renderFilename(extension: "seal", subject: "Safari - Apple Start Page"))") {
                    HStack(spacing: 8) {
                        TextField("Filename format", text: $config.filenameFormat)
                            .textFieldStyle(.roundedBorder).frame(width: 220)
                        Button("Reset") {
                            config.filenameFormat = CaptureConfig.defaultFilenameFormat
                        }
                        .disabled(config.filenameFormat == CaptureConfig.defaultFilenameFormat)
                    }
                }
                SettingsDivider()
                SettingsRow("Add captures to Library",
                            "Off: captures still open in the editor and copy to the clipboard, but stay out of your Library. Keep one with \u{201C}Add to Library\u{201D} in its right-click menu; unkept captures are deleted after \(ScratchCapture.retentionDays) days.") {
                    Toggle("", isOn: $capturesAddToLibrary)
                        .labelsHidden().toggleStyle(.switch)
                }
                SettingsDivider()
                SettingsRow("Include title & app in filename",
                            "Name captures \u{201C}App Title date\u{201D} instead of date-only. The filename reveals the capture's title and app — turn off if that's sensitive. Enabling Enhanced Security turns this off by default.") {
                    Toggle("", isOn: $filenameTitleOn)
                        .labelsHidden().toggleStyle(.switch)
                }
            }

            // Auto-scroll doesn't exist in the sandboxed (MAS) build — no
            // toggle to show there.
            if !AccessibilityPermission.isSandboxed {
                SettingsCard("Scrolling Capture") {
                    SettingsRow("Auto-scroll",
                                "Sealshot scrolls the page for you and stops at the end. Requires Accessibility permission. Off: you scroll, ⏎ finishes.") {
                        Toggle("", isOn: $autoScrollOn).labelsHidden().toggleStyle(.switch)
                    }
                }
            }
        }
    }

    private func chooseSaveFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = config.saveFolder
        if panel.runModal() == .OK, let url = panel.url {
            config.saveFolder = url
        }
    }

    /// UpdaterController is not observable; this binding re-reads on body
    /// re-evaluation only. Sparkle-side external changes to the preference
    /// won't live-refresh the toggle — accepted for a settings pane.
    private var autoUpdateBinding: Binding<Bool> {
        Binding(
            get: { self.updater.automaticallyChecksForUpdates },
            set: { self.updater.automaticallyChecksForUpdates = $0 }
        )
    }

    private var smartRedactionAutoScanBinding: Binding<Bool> {
        Binding(
            get: { SmartRedactionPreference.autoScanEnabled() },
            set: { SmartRedactionPreference.setAutoScan($0) }
        )
    }

    private var aiEnabledBinding: Binding<Bool> {
        Binding(
            get: { AIFeaturePreference().enabled },
            set: { AIFeaturePreference().enabled = $0 }
        )
    }

    /// Live mirror of the AI toggle (same defaults key `AIFeaturePreference`
    /// uses) — @AppStorage so the Thorough-scan row shows/hides the moment
    /// the toggle above it flips.
    @AppStorage("ai.enabled") private var aiEnabledLive = true
    /// Same key as `ThoroughScanPreference` (read at scan time).
    @AppStorage("RedactionThoroughScan") private var thoroughEnabled = false

    /// Foundation-Model redaction backstop opt-in, shown under the AI toggle.
    /// Display gate is STATIC (macOS 26 + Apple silicon) so the row never
    /// flips when the dynamic FM-availability check momentarily returns false
    /// (which dropped the toggle on window switches). Whether the FM actually
    /// runs is enforced at scan time by RedactionBackstopGate.
    @ViewBuilder private var thoroughScanRow: some View {
        if #available(macOS 26, *), RedactionEngineLoader.isAppleSilicon {
            SettingsRow("Thorough scan",
                        "Also use Apple Intelligence to catch sensitive items the detectors miss. Slower.") {
                Toggle("", isOn: $thoroughEnabled)
                    .labelsHidden().toggleStyle(.switch)
            }
        } else {
            SettingsRow("Thorough scan", "Requires macOS 26 and Apple silicon.") { EmptyView() }
        }
    }

    /// Prompt for mic access when none has been granted; if it's already been
    /// denied, surface the alert that steers to System Settings.
    private func requestMicrophonePermission() {
        guard !RecordingPermission.microphoneAuthorized else { return }
        RecordingPermission.requestMicrophone { granted in
            MainActor.assumeIsolated { if !granted { micPermissionDenied = true } }
        }
    }

    /// The layout picker's selection. Setting it stores the choice and applies
    /// that layout's REMEMBERED bindings — its table with the edits made while it
    /// was selected. Switching away and back is therefore lossless, which is the
    /// whole point: the previous version rewrote the table on every switch, so a
    /// glance at the other layout cost the user their customizations.
    private var layoutSelection: Binding<ShortcutLayout> {
        Binding(
            get: { selectedLayout },
            set: { chosen in
                layoutStore.select(chosen)
                selectedLayout = chosen
                systemOwnsScreenshotKeys = SystemScreenshotHotkeys.systemStillOwnsAny
            }
        )
    }

    private func openKeyboardSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    private func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
    /// Reads the model's published value (never `SMAppService` directly) so
    /// every render diffs state SwiftUI owns — see `LaunchAtLoginModel`.
    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin.isEnabled },
            set: { launchAtLogin.setEnabled($0) }
        )
    }

    /// Linked to the welcome window's "don't show this again" checkbox via the
    /// shared `welcomeShown` flag: toggle on (tour shows) == checkbox unchecked.
    ///
    /// Reads the `@State` mirror rather than `WelcomePreference` directly, for
    /// the same reason as `launchAtLoginBinding`: a binding that polls storage
    /// SwiftUI can't observe lets the drawn switch drift from the stored value
    /// (the checkbox in the welcome window writes the same flag behind our
    /// back). `welcomeTourOn` is re-synced when the tab appears.
    private var welcomeTourBinding: Binding<Bool> {
        Binding(
            get: { welcomeTourOn },
            set: { enabled in
                welcomeTourOn = enabled
                WelcomePreference.setTourEnabled(enabled)
            }
        )
    }

    // MARK: Recording

    private var recordingSection: some View {
        SettingsCard("Recording") {
            SettingsRow("Add recordings to Library",
                        "Off: recordings stay out of your Library until you keep one \u{2014} they wait in the Scratch section and are deleted after \(ScratchCapture.retentionDays) days. Separate from the capture switch: an unkept recording is gigabytes, not kilobytes.") {
                Toggle("", isOn: $recordingsAddToLibrary)
                    .labelsHidden().toggleStyle(.switch)
            }
            SettingsDivider()
            SettingsRow("Format", "Container and codec for screen recordings.") {
                Picker("", selection: $recordingFormat) {
                    ForEach(RecordingFormat.allCases, id: \.self) { f in
                        Text(f.displayName).tag(f)
                    }
                }
                // fixedSize, not a fixed width: these labels need more than
                // 220pt, and an overflowing .frame(width:) spreads the excess
                // symmetrically — pushing this control's right edge past every
                // other row's, since SettingsRow right-aligns with a Spacer.
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            SettingsDivider()
            // Subtitle kept short on purpose: SettingsRow caps it at two lines
            // and truncates the MIDDLE, so a long sentence loses its own point.
            SettingsRow("Save recordings as",
                        "A package keeps tags, search and encryption. A movie file needs no export.") {
                Picker("", selection: Binding(
                    get: { savesPlainMovie },
                    set: { wantsPlain in
                        // Turning encryption off for recordings is the
                        // consequential direction — confirm it. Going back to
                        // packages is immediate.
                        if wantsPlain, EncryptionSession.shared.isEnabled {
                            showPlainMovieConfirm = true
                        } else {
                            savesPlainMovie = wantsPlain
                        }
                    })) {
                    Text("Package").tag(false)
                    Text("Movie file").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 220)
            }
            SettingsDivider()
            SettingsRow("Frame rate", "Frames per second.") {
                Picker("", selection: $recordingFrameRate) {
                    Text("30").tag(30); Text("60").tag(60)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 120)
            }
            SettingsDivider()
            SettingsRow("Capture system audio", "Record the audio your Mac plays.") {
                Toggle("", isOn: $capturesSystemAudio).labelsHidden().toggleStyle(.switch)
            }
            SettingsDivider()
            SettingsRow("Capture microphone",
                        "Mix your microphone into the recording. Requires Microphone permission.") {
                Toggle("", isOn: $capturesMicrophone).labelsHidden().toggleStyle(.switch)
                    // Check mic permission the moment the toggle is turned on, so the
                    // user grants it immediately instead of silently getting no mic at
                    // record time.
                    .onChange(of: capturesMicrophone) { _, enabled in
                        if enabled { requestMicrophonePermission() }
                    }
            }
            SettingsDivider()
            SettingsRow("Reduce microphone noise",
                        "Suppress background noise and level your voice while recording. Processed on your Mac.") {
                Toggle("", isOn: $reducesMicNoise).labelsHidden().toggleStyle(.switch)
            }
            SettingsDivider()
            SettingsRow("Show cursor", "Include the pointer in recordings.") {
                Toggle("", isOn: $showsCursor).labelsHidden().toggleStyle(.switch)
            }
            SettingsDivider()
            SettingsRow("Ask before each recording",
                        "Show a settings confirmation when a recording starts, where you can adjust audio, cursor, and countdown on the fly.") {
                Toggle("", isOn: $asksBeforeRecording).labelsHidden().toggleStyle(.switch)
            }
            SettingsDivider()
            SettingsRow("Encrypted with Enhanced Security",
                        savesPlainMovie
                            ? "Not while recordings are saved as movie files — those are written unencrypted. Switch back to Package to encrypt them."
                            : "When Enhanced Security is on, recordings are encrypted at rest and play back only after unlock.") {
                EmptyView()
            }
        }
        .confirmationDialog("Save recordings unencrypted?", isPresented: $showPlainMovieConfirm) {
            Button("Save as Movie Files", role: .destructive) { savesPlainMovie = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("New recordings will be plain movie files that anyone with access to this Mac — or to a backup or synced copy — can open. They also won't have tags, search or a summary. Your screenshots and existing recordings stay encrypted.")
        }
        .alert("Microphone access needed", isPresented: $micPermissionDenied) {
            Button("Open System Settings") { openMicrophoneSettings() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Sealshot doesn't have microphone access. Allow it in System Settings ▸ Privacy & Security ▸ Microphone, then your recordings will include your mic.")
        }
    }

    // MARK: Shortcuts

    private var shortcutsSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            layoutAndCaptureCards
        }
        // Entering the tab, and every app re-activation while on it — the
        // System Settings round-trip the warning row sends the user on ends
        // with exactly that re-activation, so the warning clears itself.
        .onAppear { refreshLayoutState() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshLayoutState()
        }
    }

    @ViewBuilder private var layoutAndCaptureCards: some View {
            SettingsCard("Layout") {
                SettingsRow("Shortcut layout") {
                    Picker("", selection: layoutSelection) {
                        // Two segments only. An edited key stays under the layout
                        // it was edited in, so there is no third state to name.
                        ForEach(ShortcutLayout.allCases, id: \.self) { layout in
                            Text(layout.title).tag(layout)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 260)
                }
                if selectedLayout == .numbers, systemOwnsScreenshotKeys {
                    SettingsDivider()
                    SettingsRow(
                        "⌘⇧3, ⌘⇧4 and ⌘⇧5 still belong to macOS",
                        "Sealshot never sees a key macOS handles first. Turn those "
                            + "off under Keyboard Shortcuts ▸ Screenshots and the "
                            + "whole row works."
                    ) {
                        Button("Open System Settings") { openKeyboardSettings() }
                    }
                }
            }

            SettingsCard("Capture") {
                // Region/window capture are hidden for now — only the unified
                // (merged) capture is exposed. Re-add their shortcutRow lines
                // here (with .captureRegion / .captureWindow) to bring them back.
                shortcutRow("Unified capture", .captureUnified)
                SettingsDivider()
                shortcutRow("Delayed capture", .captureDelayed)
                SettingsDivider()
                shortcutRow("Scrolling capture", .captureScroll)
                shortcutRow("Repeat last capture", .captureRepeat)
                SettingsDivider()
                shortcutRow("Capture fullscreen", .captureFullscreen)
                SettingsDivider()
                shortcutRow("Save-as capture", .captureSaveAs)
            }

            SettingsCard("Recording") {
                shortcutRow("Toggle recording", .recordToggle)
                SettingsDivider()
                shortcutRow("Record selection", .recordSelection)
                SettingsDivider()
                shortcutRow("Pause/resume recording",
                            "Pausing from the keyboard keeps the gesture out of the recording.",
                            .recordPause)
            }

            SettingsCard("App") {
                shortcutRow("Open editor", .openEditor)
                SettingsDivider()
                shortcutRow("Open Library", .openLibrary)
                SettingsDivider()
                shortcutRow("New from clipboard",
                            "Open the copied image as a new canvas, from any app.",
                            .newFromClipboard)
                SettingsDivider()
                shortcutRow("Lock now",
                            "Instantly lock the library. Works while Enhanced security is on.",
                            .lockNow)
            }
    }

    private func shortcutRow(_ title: String, _ name: KeyboardShortcuts.Name) -> some View {
        SettingsRow(title) {
            KeyboardShortcuts.Recorder(for: name) {
                rejectIfDuplicate($0, name: name)
                refreshLayoutState()
            }
        }
    }

    private func shortcutRow(_ title: String, _ subtitle: String,
                             _ name: KeyboardShortcuts.Name) -> some View {
        SettingsRow(title, subtitle) {
            KeyboardShortcuts.Recorder(for: name) {
                rejectIfDuplicate($0, name: name)
                refreshLayoutState()
            }
        }
    }

    /// In-app duplicate guard: the library's recorder already rejects combos
    /// taken by macOS or the main menu, but silently accepts one held by
    /// ANOTHER Sealshot row — both handlers would fire on one keystroke. So:
    /// refuse it the same way, clear the field, and name the owning row.
    private func rejectIfDuplicate(_ shortcut: KeyboardShortcuts.Shortcut?,
                                   name: KeyboardShortcuts.Name) {
        guard let shortcut,
              let owner = ShortcutCatalog.conflictingTitle(for: shortcut, excluding: name)
        else {
            // Accepted — including a deliberate clear, which is why this runs on
            // the nil path too. Remembered under the layout it was made in.
            layoutStore.record(shortcut, for: name, in: selectedLayout)
            return
        }
        // Put the row back to what it held before this recording (nil when
        // it was unassigned) — a rejected attempt must not cost the old key.
        KeyboardShortcuts.setShortcut(shortcutsBeforeRecording[name], for: name)
        duplicateShortcutMessage = "\(shortcut) is already used by “\(owner)”. "
            + "Remove or change that shortcut first. Your previous key was kept."
    }

    /// Called on every recorder change. The edit is remembered against the
    /// SELECTED layout, so switching away and back brings it with you; the
    /// picker's selection is untouched, because editing a key is not choosing a
    /// different layout.
    private func refreshLayoutState() {
        systemOwnsScreenshotKeys = SystemScreenshotHotkeys.systemStillOwnsAny
    }

    // MARK: Permissions

    /// The same live-status rows as the capture permission checklist, so
    /// the Settings page and the pop-up always look and behave identically.
    private var permissionsSection: some View {
        SettingsCard("Permissions") {
            PermissionStatusList(requirements: permissionRequirements)
                .padding(12)
        }
    }

    private var permissionRequirements: [PermissionRequirement] {
        PermissionRequirement.appRequirements()
    }

    // MARK: Support

    private var licenseSection: some View {
        SupportSettingsSection(entitlements: EntitlementStore.shared)
    }

    // MARK: Privacy & Security

    /// Privacy page body. The lock protects the standing posture — while
    /// Enhanced security is ON, viewing the page (and so disabling it, or the
    /// recovery controls) needs a fresh owner auth. With it OFF there is
    /// nothing to protect yet, so the page shows directly and the toggle
    /// itself runs the owner check on enable (EncryptionToggleModel's
    /// boundary), which also stamps the shared window.
    ///
    /// Lock state derives from the shared 5-minute authorization window:
    /// entering the page re-reads it (return within 5 minutes stays unlocked),
    /// and a lightweight poll keeps it live in both directions while the page
    /// is open — auto-lock the moment the window expires, and unlock-in-place
    /// after the enable toggle's own prompt granted the window.
    @ViewBuilder private var privacyContent: some View {
        Group {
            // Keep the settings card mounted while an encrypt/decrypt operation
            // runs. `enable` flips `isEnabled` true before migrating, but the
            // `privacyUnlocked` snapshot is only polled once a second — so without
            // this the card (and its live progress bar) would be swapped out for
            // the lock screen mid-migration, and the running model orphaned.
            if privacyUnlocked || !EncryptionSession.shared.isEnabled
                || EncryptionSession.shared.operationInProgress {
                privacySection
            } else {
                privacyLockedSection
            }
        }
        .onAppear { privacyUnlocked = PrivacyAuthorization.shared.isAuthorized }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                privacyUnlocked = PrivacyAuthorization.shared.isAuthorized
            }
        }
    }

    private var privacySection: some View {
        PrivacySecuritySettingsView(saveFolder: config.saveFolder)
    }

    /// Locked placeholder shown until the owner authenticates. A single auth
    /// here unlocks every sensitive control on the page for this visit —
    /// either the device-owner prompt (Touch ID / password) or, for an owner
    /// who can't use it, their recovery code.
    private var privacyLockedSection: some View {
        SettingsCard("Privacy & Security") {
            VStack(spacing: 14) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 34)).foregroundStyle(.secondary)
                Text("Authentication required")
                    .font(.headline)
                Text("These settings control encryption and recovery for your library. Authenticate to view and change them.")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 360)

                if showRecoveryUnlock {
                    recoveryUnlockEntry
                } else {
                    Button("Unlock…") { unlockPrivacy() }
                        .keyboardShortcut(.defaultAction)
                    if RecoveryUnlock.isAvailable(saveFolder: config.saveFolder) {
                        Button("Use recovery code instead") {
                            recoveryUnlockError = nil
                            showRecoveryUnlock = true
                        }
                        .buttonStyle(.link)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28).padding(.horizontal, 16)
        }
    }

    /// Inline recovery-code field shown when the user picks the recovery path.
    private var recoveryUnlockEntry: some View {
        VStack(spacing: 10) {
            TextField("XXXXX-XXXXX-XXXXX-XXXXX-XXXXX", text: $recoveryCodeInput)
                .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                .frame(maxWidth: 320)
                .disabled(verifyingRecoveryCode)
                .onSubmit { unlockWithRecoveryCode() }
            if let recoveryUnlockError {
                Text(recoveryUnlockError).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button("Back") {
                    showRecoveryUnlock = false
                    recoveryCodeInput = ""
                    recoveryUnlockError = nil
                }
                .disabled(verifyingRecoveryCode)
                Button("Unlock") { unlockWithRecoveryCode() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(recoveryCodeInput.isEmpty || verifyingRecoveryCode)
            }
        }
    }

    private func unlockPrivacy() {
        Task {
            if await LocalAuthGate().authenticate(
                reason: "Authenticate to view Privacy & Security settings") {
                grantPrivacyUnlock()
            }
        }
    }

    private func unlockWithRecoveryCode() {
        guard !recoveryCodeInput.isEmpty, !verifyingRecoveryCode else { return }
        let code = recoveryCodeInput
        let folder = config.saveFolder
        recoveryUnlockError = nil
        verifyingRecoveryCode = true
        Task {
            let ok = await RecoveryUnlock.verify(code: code, saveFolder: folder)
            verifyingRecoveryCode = false
            if ok {
                recoveryCodeInput = ""
                showRecoveryUnlock = false
                grantPrivacyUnlock()
            } else {
                recoveryUnlockError = "That recovery code didn't match. Check it and try again."
            }
        }
    }

    /// Stamp the shared authorization so sensitive operations on the page (the
    /// encryption toggle, and future controls) clear their own security-boundary
    /// check without prompting a second time, then reveal the page.
    private func grantPrivacyUnlock() {
        PrivacyAuthorization.shared.grant()
        privacyUnlocked = true
    }

    // MARK: About

    private var aboutSection: some View {
        SettingsCard("About") {
            SettingsRow("Sealshot", versionString) { EmptyView() }
            SettingsDivider()
            SettingsRow("Feedback", "Questions, bugs, ideas — straight to the developer.") {
                Button("Send Feedback…") { FeedbackComposer.present() }
            }
        }
    }

    private var versionString: String {
        "Version \(UpdaterController.shared.currentVersionString)"
    }
}

// MARK: - Reusable card / row

/// Titled card: an uppercase section header above a rounded surface container
/// that holds one or more rows (divided by `SettingsDivider`).
struct SettingsCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
                .padding(.leading, 2)
            VStack(spacing: 0) { content }
                .background(Color(nsColor: Theme.surfaceColor))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .stroke(Color(nsColor: Theme.surfaceBorderColor), lineWidth: 1))
        }
    }
}

/// One row inside a `SettingsCard`: title (+ optional subtitle) on the left, a
/// trailing control on the right.
struct SettingsRow<Trailing: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder var trailing: Trailing

    init(_ title: String, _ subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2).truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

/// Inset hairline between rows in a card.
struct SettingsDivider: View {
    var body: some View { Divider().padding(.leading, 14) }
}

/// A non-interactive explanation row inside a `SettingsCard`, with an optional
/// call to action. Unlike `SettingsRow` the body text wraps in full — the AI
/// status copy is a paragraph, not a caption.
struct AIStatusRow: View {
    let nudge: AINudge

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(nudge.title)
                Text(nudge.body)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            // No button when the link is unavailable — text-only guidance
            // beats a control that silently fails.
            if nudge.isActionable, AISystemSettingsLink.canOpen {
                Button("Open System Settings…") { AISystemSettingsLink.open() }
                    .fixedSize()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}
