import Foundation
import KeyboardShortcuts
import ServiceManagement

/// Per-tab settings reset, plus the aggregate Reset All (= every scope).
/// Each scope resets exactly the settings its Settings tab shows, so the
/// Reset button always matches what's on screen.
///
/// Deliberately NEVER touched here: encryption (a stateful data migration
/// managed on its own authenticated page, not a preference), the downloaded
/// redaction model, and per-capture/UI memory (window frames, zoom, sort
/// orders, strip sizes) — those are workspace state, not settings.
///
/// System-level side effects (login item, Sparkle, the KeyboardShortcuts
/// store) fire only against `.standard`, keeping suite-injected tests hermetic.
@MainActor
enum SettingsReset {

    /// General tab: theme, trash retention, launch at login, welcome tour,
    /// and (Direct) automatic update checks.
    static func resetGeneral(config: CaptureConfig, defaults: UserDefaults = .standard) {
        config.resetGeneralDefaults()
        WelcomePreference.setTourEnabled(true, into: defaults)
        if defaults === UserDefaults.standard {
            // Through the model, not SMAppService directly: it owns the value
            // the toggle renders, so a direct unregister would switch the
            // login item off while the switch kept drawing "on".
            LaunchAtLoginModel.shared.setEnabled(false)   // launch at login: off
            if UpdaterController.shared.updatesAreSupported {
                UpdaterController.shared.automaticallyChecksForUpdates = true
            }
        }
    }

    /// On-Device AI tab: the master AI toggle, Thorough scan, and
    /// smart-redaction auto-scan. The downloaded redaction model is
    /// deliberately not touched (see the type comment).
    static func resetAI(defaults: UserDefaults = .standard) {
        AIFeaturePreference(defaults: defaults).enabled = true
        ThoroughScanPreference(defaults: defaults).enabled = false
        SmartRedactionPreference.setAutoScan(false, into: defaults)
    }

    /// Capture tab: destination, save location, filename format, include
    /// title & app in filename, scrolling auto-scroll.
    static func resetCapture(config: CaptureConfig, defaults: UserDefaults = .standard) {
        config.resetCaptureDefaults()
        FilenameIncludesTitlePreference(defaults: defaults).resetToDefault()
        if defaults === UserDefaults.standard {
            // The configuration default: OFF while Enhanced Security is on.
            FilenameIncludesTitlePreference.applyEncryptionPrivacyDefault(
                encryptionEnabled: EncryptionSession.shared.isEnabled)
        }
        AutoScrollPreference.set(true, into: defaults)
    }

    /// Recording tab: format, frame rate, system audio, microphone, noise
    /// reduction, cursor, ask-before-recording.
    static func resetRecording(defaults: UserDefaults = .standard) {
        let p = RecordingPreference(defaults: defaults)
        p.format = .hevcMov
        p.frameRate = 30
        p.capturesSystemAudio = true
        p.capturesMicrophone = false
        p.reducesMicNoise = true
        p.showsCursor = true
        p.asksBeforeRecording = true
    }

    /// Shortcuts tab: every recorder row back to its default keybinding
    /// (rows without a default reset to unassigned).
    ///
    /// Also drops the edits remembered against the SELECTED layout and puts its
    /// table back — the tab shows one layout, so "Reset" means the defaults of
    /// the layout you are looking at. The selection itself survives: asking for
    /// defaults is not asking to be moved to the other layout.
    static func resetShortcuts(layoutStore: ShortcutLayoutStore = ShortcutLayoutStore()) {
        KeyboardShortcuts.reset([
            .captureUnified, .captureDelayed, .captureScroll, .captureRepeat, .captureFullscreen,
            .captureLive, .captureSaveAs, .openEditor, .openLibrary, .newFromClipboard, .lockNow,
            .recordToggle, .recordSelection, .recordPause,
        ])
        layoutStore.resetOverrides(for: layoutStore.selected)
    }

    /// Everything the five resettable tabs show.
    static func resetAll(config: CaptureConfig, defaults: UserDefaults = .standard) {
        resetGeneral(config: config, defaults: defaults)
        resetAI(defaults: defaults)
        resetCapture(config: config, defaults: defaults)
        resetRecording(defaults: defaults)
        if defaults === UserDefaults.standard {
            resetShortcuts()
            // Reset All means the shipped state, so the picker goes back to
            // Letters too — unlike the tab's own Reset, which keeps your layout.
            ShortcutLayoutStore().resetEverything()
        }
    }
}
