import AppKit
import SwiftUI

/// Live-persisting view model for the pre-recording settings prompt. Every
/// change writes straight through to `RecordingPreference` (the general
/// defaults), so edits made "on the fly" stick for future recordings too.
@MainActor
final class RecordingSettingsModel: ObservableObject {
    private let pref: RecordingPreference
    @Published var systemAudio: Bool { didSet { pref.capturesSystemAudio = systemAudio } }
    @Published var micAudio: Bool     { didSet { pref.capturesMicrophone = micAudio } }
    @Published var showsCursor: Bool  { didSet { pref.showsCursor = showsCursor } }
    @Published var countdown: Int     { didSet { pref.countdownSeconds = countdown } }
    @Published var askBefore: Bool    { didSet { pref.asksBeforeRecording = askBefore } }

    init(pref: RecordingPreference) {
        self.pref = pref
        systemAudio = pref.capturesSystemAudio
        micAudio = pref.capturesMicrophone
        showsCursor = pref.showsCursor
        countdown = pref.countdownSeconds
        askBefore = pref.asksBeforeRecording
    }
}

/// Confirmation shown before a recording starts: a reminder of the current
/// settings that doubles as a quick editor for them.
struct RecordingSettingsPromptView: View {
    @ObservedObject var model: RecordingSettingsModel
    let onStart: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Recording settings").font(.headline)

            Toggle("Record system audio", isOn: $model.systemAudio)
            Toggle("Record microphone", isOn: $model.micAudio)
            Toggle("Show cursor", isOn: $model.showsCursor)

            HStack {
                Text("Countdown")
                Spacer()
                Picker("", selection: $model.countdown) {
                    Text("Off").tag(0)
                    Text("3s").tag(3)
                    Text("5s").tag(5)
                    Text("10s").tag(10)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }

            Divider()

            Toggle("Ask before each recording", isOn: $model.askBefore)
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Start Recording", action: onStart).keyboardShortcut(.defaultAction)
            }
            .padding(.top, 2)
        }
        .padding(20)
        .frame(width: 340)
    }
}

/// Presents `RecordingSettingsPromptView` as a floating panel and resolves to a
/// Start (true) / Cancel (false) decision. When the user has turned the prompt
/// off (`asksBeforeRecording == false`), `confirm()` returns true immediately
/// without showing anything.
@MainActor
final class RecordingSettingsPromptController {
    private let pref: RecordingPreference
    private var panel: NSPanel?
    private var continuation: CheckedContinuation<Bool, Never>?

    init(pref: RecordingPreference = RecordingPreference()) { self.pref = pref }

    func confirm() async -> Bool {
        guard pref.asksBeforeRecording else { return true }
        guard panel == nil else { return false }   // ignore re-entry while shown
        return await withCheckedContinuation { cont in
            continuation = cont
            present()
        }
    }

    private func present() {
        let model = RecordingSettingsModel(pref: pref)
        let view = RecordingSettingsPromptView(
            model: model,
            onStart: { [weak self] in self?.finish(true) },
            onCancel: { [weak self] in self?.finish(false) })
        let host = NSHostingController(rootView: view)
        let panel = NSPanel(contentViewController: host)
        // `.nonactivatingPanel` is the key to overlaying a full-screen app (often
        // ANOTHER app the user is recording) on the CURRENT Space: it lets the
        // panel become key WITHOUT activating Sealshot, which would otherwise
        // swipe to Sealshot's own Space (on another display) and drag the prompt
        // there. `.screenSaver` clears the full-screen window's high effective
        // level; `.canJoinAllSpaces` shows it on whatever Space is up now. All
        // mirrors the capture overlay, which already floats over full-screen apps.
        panel.styleMask = [.titled, .nonactivatingPanel]
        panel.title = "Record"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // Size the panel to its content BEFORE centering. The hosting
        // controller's fitting size isn't applied until a layout pass, so
        // centering first would use a placeholder size and the window would
        // settle off-center once SwiftUI lays out.
        host.view.layoutSubtreeIfNeeded()
        panel.setContentSize(host.view.fittingSize)
        Self.center(panel)   // the pointer's screen — where the user is recording
        panel.orderFrontRegardless()
        panel.makeKey()      // for Return/Esc; nonactivating, so no Space swipe
        self.panel = panel
    }

    /// Place the panel dead-center of the screen the user is on. `NSWindow`'s own
    /// `center()` sits slightly ABOVE center (documented). The screen under the
    /// pointer is where the user just triggered the recording, preferred over
    /// `NSScreen.main` for multi-display setups.
    private static func center(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { panel.center(); return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2,
                                     y: visible.midY - size.height / 2))
    }

    private func finish(_ proceed: Bool) {
        panel?.orderOut(nil)
        panel = nil
        continuation?.resume(returning: proceed)
        continuation = nil
    }
}
