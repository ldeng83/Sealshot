import AppKit
import AVFoundation
import ScreenCaptureKit
import KeyboardShortcuts
import CryptoKit
import os.log

private let log = OSLog(subsystem: "com.seal-shot.sealshot", category: "recording")

private let iso8601: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

extension Notification.Name {
    /// Posted with the finished recording's file URL as `object`.
    static let recordingDidFinish = Notification.Name("recordingDidFinish")
}

/// Orchestrates a recording session: permission preflight → source → start;
/// manages stop/pause via the menu-bar controls and the global shortcut.
///
/// FIRST CUT: records fullscreen of the display under the cursor. Region/window
/// source selection (reusing the capture overlay) is the next increment.
/// UNVERIFIED end-to-end — needs on-device smoke testing.
@MainActor
final class RecordingCoordinator {
    private let pref = RecordingPreference()
    /// Package-or-plain-movie choice, read at finalize time so a change made
    /// mid-recording applies to the recording being finished.
    private let wrapperPref = RecordingWrapperPreference()
    /// Resolved fresh per recording — the save location can change in
    /// Settings mid-session, and a captured URL would strand new recordings
    /// in the old folder until relaunch.
    private let saveFolderProvider: @MainActor () -> URL
    private var saveFolder: URL { saveFolderProvider() }
    private var recorder: ScreenRecorder?
    /// UIs that react to recording lifecycle (menu-bar item, floating HUD).
    /// Weakly held; they call back via `toggle()`/`togglePause()`.
    private let observers = NSHashTable<AnyObject>.weakObjects()

    func addObserver(_ observer: RecordingStateObserver) { observers.add(observer) }

    private func forEachObserver(_ body: (RecordingStateObserver) -> Void) {
        for case let observer as RecordingStateObserver in observers.allObjects { body(observer) }
    }
    /// Shared with CaptureCoordinator so the pre-roll countdown reuses the same
    /// panel and global-Esc cancel wiring.
    private let countdown: CaptureCountdownController
    /// Reuses the capture overlay to pick a region/window to record. Returns nil
    /// on cancel. Injected so the coordinator stays decoupled from capture.
    private let sourcePicker: () async -> RecordingSession.Source?
    /// Called when a recording is about to begin (any entry point: shortcut,
    /// toolbar, menu) so the caller can hide UI that shouldn't be recorded
    /// (e.g. the editor window). Fires before the source picker / countdown.
    var onWillBegin: (() -> Void)?
    /// Optional pre-roll confirmation (the settings prompt). Returns true to
    /// proceed, false to cancel. nil = proceed without prompting.
    var confirmSettings: (() async -> Bool)?
    /// Called when a pending recording is aborted before it starts (source
    /// picker cancelled, or the pre-roll countdown cancelled). Lets the caller
    /// restore UI it hid in anticipation (e.g. re-show the editor window).
    var onAborted: (() -> Void)?
    /// Instant Screen Recording preflight. `CGPreflightScreenCaptureAccess` can
    /// serve a STALE cached "granted" to a running process after a revocation,
    /// so a true result is only trusted once `screenRecordingLiveCheck` confirms
    /// it. A false result is authoritative (not granted) and — critically —
    /// avoids touching ScreenCaptureKit, which would fire the system dialog on a
    /// notDetermined state (consent must come only from the checklist's Enable).
    /// Injected for testing.
    var screenRecordingPreflight: () -> Bool = { CGPreflightScreenCaptureAccess() }
    /// Honest functional check: asks ScreenCaptureKit what a capture would do
    /// right now, catching a stale preflight grant. Only consulted when the
    /// preflight is already true, so it never fires the dialog on a fresh state.
    /// Injected for testing.
    var screenRecordingLiveCheck: () async -> Bool = { await ScreenRecordingPermission.liveGranted() }
    /// Presents the shared permission checklist (same UI as still capture) when
    /// Screen Recording is denied. The closure it receives restarts this
    /// recording once permission is granted. Wired by AppDelegate to the
    /// capture coordinator, which owns the checklist window.
    var showPermissionChecklist: ((@escaping () -> Void) -> Void)?

    init(saveFolder: @escaping @MainActor () -> URL,
         countdown: CaptureCountdownController,
         sourcePicker: @escaping () async -> RecordingSession.Source?) {
        self.saveFolderProvider = saveFolder
        self.countdown = countdown
        self.sourcePicker = sourcePicker
    }

    func registerShortcut() {
        KeyboardShortcuts.onKeyUp(for: .recordToggle) { [weak self] in self?.toggle() }
        KeyboardShortcuts.onKeyUp(for: .recordSelection) { [weak self] in self?.beginSelection() }
        // togglePause guards on a live recorder, so this is a no-op when idle.
        KeyboardShortcuts.onKeyUp(for: .recordPause) { [weak self] in self?.togglePause() }
    }

    var isRecording: Bool { recorder != nil }

    /// Non-zero while a recording start flow is in its pre-roll — the config
    /// prompt, display pick, and countdown — before `recorder` exists.
    private var startingSessions = 0

    /// The busy-gate view of this coordinator: recording OR anywhere in the
    /// start flow. Capture triggers check this (via AppDelegate wiring), so a
    /// screen capture can't fire while the recording-setup prompt is up.
    var isBusy: Bool { recorder != nil || startingSessions > 0 }

    /// Whether a capture session (overlay, countdown, scroll) owns the screen —
    /// injected from CaptureCoordinator in AppDelegate. Blocks recording STARTS
    /// only; stopping/pausing a running recording always works.
    var isCaptureSessionActive: () -> Bool = { false }

    func toggle(display: NSScreen? = nil) {
        if isRecording {
            // ⌘⇧V (full-screen) only stops a full-screen recording; while a
            // selection recording runs it's a no-op (⌘⇧R stops that one).
            if activeRecordingMode == .fullScreen { Task { await self.stop() } }
        } else {
            begin(display: display)
        }
    }

    /// Unconditionally stop the running recording, whatever its mode — the HUD
    /// Stop button and the "Stop Recording" menu item, which aren't tied to a
    /// start shortcut. No-op when idle.
    func stopRecording() {
        if isRecording { Task { await self.stop() } }
    }

    /// Record the full display under the cursor (the ⇧⌘V fast path).
    private var displayPicker: DisplayPickerController?

    /// `display` nil + multiple monitors = show the click-a-monitor overlay; nil +
    /// a single monitor records it. A chosen `NSScreen` records that monitor.
    /// (Recording is per-display — no All-Displays.)
    func begin(display: NSScreen? = nil) {
        guard !isBusy, !countdown.isRunning, !isCaptureSessionActive() else { return }
        startingSessions += 1
        Task { @MainActor in
            // Once the flow exits, either recorder != nil carries the busy
            // state or the start was aborted/cancelled and the gate reopens.
            defer { startingSessions -= 1 }
            // Permission first: surface the shared checklist (like still
            // capture) BEFORE hiding the editor or showing the recording-setup
            // prompt, so a denied Screen Recording grant never reaches
            // ScreenCaptureKit as a raw error after the setup popup.
            guard await ensureScreenRecordingPermission(retry: { [weak self] in self?.begin(display: display) }) else { return }
            onWillBegin?()
            guard await confirmToRecord() else { onAborted?(); return }
            do {
                // Multi-monitor with no chosen display: let the user click a screen
                // (recording is per-display — no All-Displays).
                var chosen = display
                if chosen == nil, NSScreen.screens.count > 1 {
                    let picker = DisplayPickerController()
                    self.displayPicker = picker
                    // Recording streams live, so no freeze — just pick a display.
                    let pick = await picker.pick(allowAllDisplays: false, freeze: false)
                    self.displayPicker = nil
                    guard let pick else { onAborted?(); return }   // cancelled
                    chosen = pick.screen
                }
                let scDisplay = try await resolveDisplay(chosen)
                await prepareAndStart(source: .display(scDisplay))
            } catch {
                presentError("Couldn't start recording", error)
            }
        }
    }

    /// The chosen `NSScreen`'s `SCDisplay`, falling back to the cursor's display.
    private func resolveDisplay(_ screen: NSScreen?) async throws -> SCDisplay {
        guard let screen else { return try await displayUnderCursor() }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        if let id = DisplayResolver.displayID(for: screen),
           let match = DisplayResolver.match(displayID: id, in: content.displays) {
            return match
        }
        return try await displayUnderCursor()
    }

    /// Run the optional settings prompt; proceed when there's none.
    private func confirmToRecord() async -> Bool {
        guard let confirmSettings else { return true }
        return await confirmSettings()
    }

    /// True when Screen Recording is genuinely usable right now. The preflight
    /// alone can report a stale "granted" after a revocation, so a positive
    /// preflight is confirmed against the live ScreenCaptureKit check. When not
    /// granted, surfaces the shared permission checklist (whose Enable buttons
    /// drive the system consent) and returns false so the caller stops — the
    /// checklist's action restarts the recording once granted.
    private func ensureScreenRecordingPermission(retry: @escaping () -> Void) async -> Bool {
        if screenRecordingPreflight(), await screenRecordingLiveCheck() { return true }
        os_log("recording blocked on Screen Recording — surfacing checklist", log: log, type: .info)
        showPermissionChecklist?(retry)
        return false
    }

    /// Record a region or window chosen via the capture overlay.
    func beginSelection() {
        // ⌘⇧R toggles a SELECTION recording: while one runs, this stops it;
        // while a full-screen recording runs, it's a no-op (⌘⇧V stops that one).
        if isRecording {
            if activeRecordingMode == .selection { Task { await self.stop() } }
            return
        }
        guard !isBusy, !countdown.isRunning, !isCaptureSessionActive() else { return }
        startingSessions += 1
        Task { @MainActor in
            defer { startingSessions -= 1 }
            guard await ensureScreenRecordingPermission(retry: { [weak self] in self?.beginSelection() }) else { return }
            onWillBegin?()
            guard await confirmToRecord() else { onAborted?(); return }
            guard let source = await sourcePicker() else {   // cancelled / unavailable
                onAborted?()
                return
            }
            await prepareAndStart(source: source)
        }
    }

    /// Shared pre-roll for either entry point: resolve mic permission, run the
    /// optional countdown, then start recording the given source.
    private func prepareAndStart(source: RecordingSession.Source) async {
        // Microphone: re-check access at every recording start (the user may have
        // revoked it in System Settings since enabling the toggle). Prompt if
        // undecided; if it's actually off, surface it instead of silently
        // recording without the mic.
        if pref.capturesMicrophone, !RecordingPermission.microphoneAuthorized {
            _ = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                RecordingPermission.requestMicrophone { c.resume(returning: $0) }
            }
            if !RecordingPermission.microphoneAuthorized {
                os_log("mic permission not granted at record start", log: log, type: .info)
                if !confirmRecordWithoutMic() { return }   // user chose to fix it first
            }
        }
        let seconds = pref.countdownSeconds
        if seconds > 0 {
            countdown.start(
                seconds: seconds,
                onComplete: { [weak self] in Task { @MainActor in await self?.startRecorder(source: source) } },
                onCancel: { [weak self] in self?.onAborted?() })
        } else {
            await startRecorder(source: source)
        }
    }

    /// The screen being recorded, resolved at recorder start and cleared on
    /// stop. The recording HUD reads this to appear on the recorded display
    /// (where the user's attention is; the HUD is excluded from the capture).
    private(set) var activeRecordingScreen: NSScreen?

    /// How the running recording was STARTED, so each shortcut only stops the
    /// kind it starts: ⌘⇧V (full-screen) stops a full-screen recording, ⌘⇧R
    /// (selection) stops a region/window recording. Resolved at recorder start,
    /// cleared on stop.
    enum RecordingMode { case fullScreen, selection }
    private(set) var activeRecordingMode: RecordingMode?

    /// The NSScreen a recording source lives on: display/region match by
    /// displayID; a window resolves to the screen containing its frame's
    /// midpoint. Nil when no connected screen matches (HUD falls back to main).
    nonisolated static func screen(for source: RecordingSession.Source,
                                   screens: [NSScreen]) -> NSScreen? {
        func byID(_ display: SCDisplay) -> NSScreen? {
            screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                    .uint32Value == display.displayID
            }
        }
        switch source {
        case .display(let d), .region(let d, _):
            return byID(d)
        case .window(let w):
            // SCWindow frames are top-left-origin global coords; NSScreen frames
            // are bottom-left. Match by X-midpoint plus flipped Y-midpoint.
            let totalHeight = screens.first.map { $0.frame.maxY } ?? 0
            let mid = NSPoint(x: w.frame.midX, y: totalHeight - w.frame.midY)
            return screens.first { $0.frame.contains(mid) } ?? screens.first
        }
    }

    /// Build the session and start the recorder for `source`. Always records to a
    /// temp `.mov` in the system temp directory; the final `.seal` is assembled at
    /// finalize time. Both encrypted and plaintext paths use the same temp strategy
    /// so `stop()` is unified. The crypto context is resolved at finalize (not here)
    /// so enabled-but-locked sessions write a write-only encrypted `.seal` —
    /// consistent with how image captures behave (no block-on-locked guard).
    private func startRecorder(source: RecordingSession.Source) async {
        guard recorder == nil else { return }
        activeRecordingScreen = Self.screen(for: source, screens: NSScreen.screens)
        // `.display` = the full-screen ⌘⇧V path; a region/window comes from the
        // selection picker (⌘⇧R). Drives which shortcut may stop this recording.
        if case .display = source { activeRecordingMode = .fullScreen } else { activeRecordingMode = .selection }

        let recordURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rec-\(UUID().uuidString).\(pref.format.fileExtension)")

        do {
            let session = RecordingSession(
                source: source, outputURL: recordURL, format: pref.format,
                frameRate: pref.frameRate, capturesSystemAudio: pref.capturesSystemAudio,
                capturesMicrophone: pref.capturesMicrophone && RecordingPermission.microphoneAuthorized,
                reducesMicNoise: pref.reducesMicNoise,
                showsCursor: pref.showsCursor)
            let recorder = ScreenRecorder()
            recorder.onError = { [weak self] err in self?.handleError(err) }
            self.recorder = recorder
            try await recorder.start(session)
            forEachObserver { $0.recordingDidStart() }
        } catch {
            self.recorder = nil
            activeRecordingMode = nil
            presentError("Couldn't start recording", error)
        }
    }

    private func stop() async {
        guard let recorder else { return }
        let url = await recorder.stop()
        self.recorder = nil
        activeRecordingScreen = nil
        activeRecordingMode = nil
        forEachObserver { $0.recordingDidStop() }
        guard let recorded = url else { return }
        await finalize(recorded: recorded)
    }

    /// Assemble the video `.seal` from the plaintext temp recording.
    ///
    /// Always writes to `saveFolder/<base>.seal` via `VideoSealPackageIO.write`.
    /// The crypto context is resolved here (on the main actor) via
    /// `SealPackageCryptoContext.current()` — consistent with image captures.
    /// The heavy encrypt runs in a `Task.detached` off the main actor.
    ///
    /// On failure, the temp is kept so the recording isn't lost.
    private func finalize(recorded: URL) async {
        // 1. Thumbnail (from plaintext temp before any encryption).
        let thumbnail = await RecordingThumbnail.frame(for: recorded)
            .flatMap { try? CaptureOutputWriter.encodePNG($0) }

        // 2. Probe duration + frame size + audio via AVURLAsset.
        let asset = AVURLAsset(url: recorded)
        let duration: Double
        let frameSize: CGSize
        let hasAudio: Bool
        do {
            let cmDuration = try await asset.load(.duration)
            duration = cmDuration.seconds

            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            guard let firstTrack = videoTracks.first else {
                presentError("Couldn't finalize recording",
                             message: "No video track found. The recording was kept at \(recorded.path).")
                return
            }
            frameSize = try await firstTrack.load(.naturalSize)
            guard frameSize.width > 0, frameSize.height > 0 else {
                presentError("Couldn't finalize recording",
                             message: "Video track has zero dimensions. The recording was kept at \(recorded.path).")
                return
            }

            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            hasAudio = !audioTracks.isEmpty
        } catch {
            presentError("Couldn't read recording metadata",
                         message: "The recording was kept at \(recorded.path). (\(error))")
            return
        }

        // 3. Build the manifest using the pure static helper.
        let manifest = RecordingCoordinator.makeRecordingManifest(
            durationSeconds: duration,
            frameSize: frameSize,
            hasAudio: hasAudio,
            now: Date())

        // 4. Resolve the final destination — the MAIN save folder (alongside
        // images), or Scratch/ when recordings are set to bypass the Library.
        let destination = ScratchCapture.destination(
            saveFolder: saveFolder,
            addToLibrary: ScratchCapturePreference().recordingsAddToLibrary)
        try? FileManager.default.createDirectory(at: destination,
                                                 withIntermediateDirectories: true)
        let baseName = makeBaseName(in: destination)
        let stem = destination.appendingPathComponent((baseName as NSString).deletingPathExtension)

        // 4a. Plain-movie mode (Settings ▸ Recording): keep the movie the
        // recorder already produced instead of wrapping it, so it needs no
        // export before it can be sent anywhere. MOVE rather than copy — these
        // are gigabytes, and the temp and the save folder are usually the same
        // volume, where a move is O(1). Everything downstream (notifications,
        // Finder reveal) is identical to the package path, so the strip, the
        // Library and the undo timeline see the same events.
        if wrapperPref.wrapper == .plainMovie {
            let movieURL = stem.appendingPathExtension(pref.format.fileExtension)
            do {
                try FileManager.default.moveItem(at: recorded, to: movieURL)
            } catch {
                // Same contract as the package path: the temp survives, so the
                // recording is never lost to a failed finalize.
                presentError("Couldn't finalize recording",
                             message: "The recording was kept at \(recorded.path). (\(error))")
                return
            }
            NotificationCenter.default.post(name: .recordingDidFinish, object: movieURL)
            NotificationCenter.default.post(name: .captureFilesImported, object: [movieURL],
                                            userInfo: ["kind": "capture"])
            NSWorkspace.shared.activateFileViewerSelecting([movieURL])
            countTowardsSupportNudge()
            return
        }

        let sealURL = stem.appendingPathExtension("seal")

        // 5. Resolve the crypto context on the main actor.
        let crypto = SealPackageCryptoContext.current()
        let uti = pref.format.uti

        // 6. Write the video .seal off the main actor (GB encrypt must not block main).
        // SealPackageCryptoContext is Sendable; SealManifest is a pure value type whose
        // members are all Codable/Equatable structs — the compiler infers Sendable.
        do {
            try await Task.detached(priority: .userInitiated) {
                try VideoSealPackageIO.write(
                    to: sealURL,
                    payloadTempURL: recorded,
                    originalUTI: uti,
                    manifest: manifest,
                    thumbnailPNG: thumbnail,
                    crypto: crypto)
            }.value

            // VideoSealPackageIO.write consumed the temp; post success notification.
            // This one fires for scratch recordings TOO: it drives the HUD
            // finishing, the editor opening the video, and the floating panel's
            // handoff — suppress it and the recording appears to vanish.
            NotificationCenter.default.post(name: .recordingDidFinish, object: sealURL)
            // The LIBRARY announcement (index, strips, undo timeline) is the one
            // a scratch recording skips — same rule as a scratch capture.
            if !ScratchCapture.isScratch(sealURL) {
                NotificationCenter.default.post(name: .captureFilesImported, object: [sealURL],
                                                userInfo: ["kind": "capture"])
            }
            // Reveal in Finder — a .seal is a single Finder item (directory package).
            NSWorkspace.shared.activateFileViewerSelecting([sealURL])
            countTowardsSupportNudge()
        } catch {
            presentError("Couldn't finalize recording",
                         message: "The recording was kept at \(recorded.path). (\(error))")
        }
    }

    /// A recording that finalized counts as work done, the same as a capture.
    /// Only the SUCCESS paths call this: a failed finalize is not something to
    /// follow with a request for money.
    private func countTowardsSupportNudge() {
        SupportNudge.recordCreationAndAskIfDue(isBusy: { [weak self] in
            guard let self else { return false }
            return self.isBusy || self.isCaptureSessionActive()
        })
    }

    // MARK: - Pure manifest factory (testable)

    /// Builds a `SealManifest` for a screen recording from probed asset properties.
    ///
    /// Pure / static so it can be unit-tested without AVAsset/SCK integration.
    /// `nonisolated` so tests can call it synchronously without @MainActor context.
    nonisolated static func makeRecordingManifest(
        durationSeconds: Double,
        frameSize: CGSize,
        hasAudio: Bool,
        now: Date
    ) -> SealManifest {
        // Local formatter: this is `nonisolated`, so don't reach for the shared
        // (non-Sendable) `iso8601` instance — keeps us clean under strict concurrency.
        let fmt = ISO8601DateFormatter()
        let stamp = fmt.string(from: now)
        return SealManifest(
            version: SealManifest.currentVersion,
            createdISO8601: stamp,
            modifiedISO8601: stamp,
            sourceSize: SealManifest.Size(
                width: Int(frameSize.width),
                height: Int(frameSize.height)),
            sourceApp: nil,
            enhanceParams: nil,
            captureKind: .screenRecording,
            video: VideoInfo(durationSeconds: durationSeconds, hasAudio: hasAudio))
    }

    func togglePause() {
        guard let recorder else { return }
        if recorder.isPaused { recorder.resume(); forEachObserver { $0.recordingPausedChanged(false) } }
        else { recorder.pause(); forEachObserver { $0.recordingPausedChanged(true) } }
    }

    private func handleError(_ error: Error) {
        Task { @MainActor in
            // SCK reports a normal user-initiated stop (e.g. the macOS menu-bar
            // / Control Center "Stop" control) as .userStopped — that's not a
            // failure. Finalize and save it like our own Stop, no error alert.
            if Self.isUserStopped(error) {
                await self.stop()
                return
            }
            _ = await self.recorder?.stop()
            self.recorder = nil
            self.activeRecordingScreen = nil
            self.activeRecordingMode = nil
            self.forEachObserver { $0.recordingDidStop() }
            self.presentError("Recording stopped", error)
        }
    }

    /// SCK's "the user stopped the stream" (code -3817) — the OS-level Stop
    /// control, not an error.
    static func isUserStopped(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == SCStreamError.errorDomain
            && ns.code == SCStreamError.Code.userStopped.rawValue
    }

    // MARK: - Helpers

    /// The SCDisplay whose bounds contain the mouse, else the first display.
    private func displayUnderCursor() async throws -> SCDisplay {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }),
           let id = DisplayResolver.displayID(for: screen),
           let match = DisplayResolver.match(displayID: id, in: content.displays) {
            return match
        }
        guard let first = content.displays.first else { throw RecordingError.noContent }
        return first
    }

    private func recordingsFolder() -> URL {
        let dir = saveFolder.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A timestamped, de-collided base filename (with the format's extension)
    /// for a recording in `dir`. Dedupes against the `.seal` package form so
    /// encrypted and plain recordings in `saveFolder` never collide.
    private func makeBaseName(in dir: URL) -> String {
        let fm = FileManager.default
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' h_mm_ss a"
        let stamp = formatter.string(from: Date())
        return RecordingFilename.make(stamp: stamp, format: pref.format, exists: { name in
            let seal = (name as NSString).deletingPathExtension + ".seal"
            return fm.fileExists(atPath: dir.appendingPathComponent(name).path)
                || fm.fileExists(atPath: dir.appendingPathComponent(seal).path)
        })
    }

    /// Mic is enabled but access isn't granted at record start. Let the user
    /// fix it (and skip this recording) or record without the mic. Returns true
    /// to proceed without the mic, false to abort so they can grant access.
    private func confirmRecordWithoutMic() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Microphone access is off"
        alert.informativeText = "Sealshot can't record your microphone. Allow it in System Settings ▸ Privacy & Security ▸ Microphone, or record without your mic."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Record Without Mic")
        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
            return false
        }
        return true
    }

    private func presentError(_ title: String, _ error: Error) {
        presentError(title, message: String(describing: error))
    }

    private func presentError(_ title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}
