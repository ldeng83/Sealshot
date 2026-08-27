import AppKit
import ScreenCaptureKit
import KeyboardShortcuts
import os.log

private let log = OSLog(subsystem: "com.seal-shot.sealshot", category: "capture")

@MainActor
final class WindowPickerController {
    enum PickerResult {
        case picked(window: SCWindow, screen: NSScreen, captureSpan: SignpostMetrics.Token)
        case cycle  // user pressed spacebar to switch back to region overlay
        case cancelled
    }

    private var panels: [WindowPickerPanel] = []
    private var views: [WindowHighlightView] = []
    private var continuation: CheckedContinuation<PickerResult, Never>?
    /// True while a session is on screen (the coordinator's busy gate).
    var isRunning: Bool { continuation != nil }
    private var refreshTask: Task<Void, Never>?
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var didBecomeActiveObserver: NSObjectProtocol?

    /// Show picker overlays across all screens and await a selection.
    /// Returns `.picked` on success, `.cycle` if the user pressed spacebar
    /// to switch back to region overlay, or `.cancelled` for any cancel path.
    ///
    /// If `hotkeyToken` is supplied, ends that span once panels are on-screen.
    func selectWindow(hotkeyToken: SignpostMetrics.Token? = nil) async -> PickerResult {
        if continuation != nil {
            os_log("selectWindow re-entry — ignoring", log: log, type: .info)
            if let token = hotkeyToken { SignpostMetrics.end(token) }
            return .cancelled
        }

        return await withCheckedContinuation { (cont: CheckedContinuation<PickerResult, Never>) in
            self.continuation = cont
            self.startSession(hotkeyToken: hotkeyToken)
        }
    }

    private func startSession(hotkeyToken: SignpostMetrics.Token?) {
        let screens = NSScreen.screens
        if screens.isEmpty {
            os_log("WindowPicker startSession: NSScreen.screens empty", log: log, type: .error)
            if let token = hotkeyToken { SignpostMetrics.end(token) }
            if let cont = continuation {
                continuation = nil
                cont.resume(returning: .cancelled)
            }
            return
        }

        NSApp.activate(ignoringOtherApps: true)

        for screen in screens {
            let panel = WindowPickerPanel(screen: screen)
            let view = WindowHighlightView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.onClick = { [weak self] picked in
                self?.complete(picked: picked, screen: screen)
            }
            view.onCancel = { [weak self] in
                self?.complete(picked: nil, screen: screen)
            }
            view.onSpacebar = { [weak self] in
                self?.completeCycle()
            }
            panel.contentView = view
            panel.initialFirstResponder = view
            // orderFrontRegardless joins the active Space even when a different
            // app is in native full-screen; orderFront would leave us behind it.
            panel.orderFrontRegardless()
            panels.append(panel)
            views.append(view)
        }
        if let first = panels.first {
            first.makeKey()
            first.makeFirstResponder(first.contentView)
        }
        if let token = hotkeyToken { SignpostMetrics.end(token) }

        // Bind plain Esc as a system-wide hotkey for the picker session.
        // The handler in `CaptureCoordinator.init` calls `cancelFromGlobalEsc`.
        // The binding is cleared in `tearDown()` so Esc returns to its
        // normal per-app behavior the instant the session ends.
        KeyboardShortcuts.setShortcut(
            .init(.escape, modifiers: []),
            for: .pickerCancel
        )

        installEventMonitors()
        installActivationObserver()
        startCandidateRefresh()
    }

    /// Called from the global Esc hotkey while a picker session is active.
    func cancelFromGlobalEsc() {
        guard continuation != nil else { return }
        guard let screen = panels.first?.screen ?? NSScreen.main else { return }
        complete(picked: nil, screen: screen)
    }

    private func installActivationObserver() {
        // When the user Cmd+Tabs back to Sealshot, AppKit doesn't
        // automatically restore the picker panel as key (we have no main
        // window). Symptom: cursor reverts to arrow + Esc goes nowhere until
        // the user clicks our panel. Force the panel back to key on every
        // didBecomeActive.
        didBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.restorePanelKeyStatus() }
        }
    }

    @MainActor
    private func restorePanelKeyStatus() {
        guard let first = panels.first else { return }
        first.makeKeyAndOrderFront(nil)
        first.makeFirstResponder(first.contentView)
        first.invalidateCursorRects(for: first.contentView ?? NSView())
    }

    private func installEventMonitors() {
        // Local keyDown monitor: catches Esc reliably even when the panel's
        // firstResponder chain isn't routing events. Returning nil swallows.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { // Esc
                Task { @MainActor in self.cancelFromMonitor() }
                return nil
            }
            return event
        }

        // Local mouseMoved monitor: drives hover-outline updates when our
        // app is active.
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            guard let self else { return event }
            Task { @MainActor in self.notifyMouseMoved() }
            return event
        }

        // Global mouseMoved monitor: keeps the hover-outline tracing when the
        // user Cmd+Tabs to another app to bring a minimized window forward.
        // Global monitors for `.mouseMoved` don't require accessibility.
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.notifyMouseMoved() }
        }
    }

    @MainActor
    private func cancelFromMonitor() {
        // Find any view to call complete via; screen here is just a label
        // (controller wipes panels/views uniformly on cancel).
        guard let screen = panels.first?.screen ?? NSScreen.main else { return }
        complete(picked: nil, screen: screen)
    }

    @MainActor
    private func notifyMouseMoved() {
        for view in views { view.handleMouseMoved() }
    }

    private func startCandidateRefresh() {
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshCandidates()
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    private func refreshCandidates() async {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let filtered = await WindowCandidateProvider.current(ownPID: ownPID)
        await MainActor.run {
            for view in self.views {
                view.setCandidates(filtered)
            }
        }
    }

    private func tearDown() {
        refreshTask?.cancel()
        refreshTask = nil
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
        if let m = mouseMonitor { NSEvent.removeMonitor(m) }
        mouseMonitor = nil
        if let m = globalMouseMonitor { NSEvent.removeMonitor(m) }
        globalMouseMonitor = nil
        if let obs = didBecomeActiveObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        didBecomeActiveObserver = nil
        for panel in panels { panel.close() }
        panels.removeAll()
        views.removeAll()
        // Clear the dynamic Esc binding so we don't keep stealing Esc
        // system-wide outside picker sessions.
        KeyboardShortcuts.setShortcut(nil, for: .pickerCancel)
    }

    private func complete(picked: SCWindow?, screen: NSScreen) {
        guard let cont = continuation else { return }
        continuation = nil
        tearDown()
        if let win = picked {
            let captureSpan = SignpostMetrics.begin("picker-to-window-capture")
            cont.resume(returning: .picked(window: win, screen: screen, captureSpan: captureSpan))
        } else {
            cont.resume(returning: .cancelled)
        }
    }

    private func completeCycle() {
        guard let cont = continuation else { return }
        continuation = nil
        tearDown()
        cont.resume(returning: .cycle)
    }
}
