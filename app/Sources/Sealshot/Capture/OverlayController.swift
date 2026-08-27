import AppKit
import os.log

private let log = OSLog(subsystem: "com.seal-shot.sealshot", category: "capture")

@MainActor
final class OverlayController {
    private var panels: [OverlayPanel] = []
    private var views: [(screen: NSScreen, view: SelectionView)] = []
    private var continuation: CheckedContinuation<OverlaySelection, Never>?
    /// Frozen frames feeding the crosshair loupe. Kept across spacebar cycles
    /// (the grab is per trigger, not per overlay showing); the coordinator
    /// replaces it at each new capture trigger.
    private var loupeFrames: FrozenFrameSet?

    /// Show the overlay across all attached screens and await a selection.
    ///
    /// Returns `.region` for a normal drag-release, `.cycle` if the user
    /// pressed spacebar to switch to window-picker mode, or `.cancelled`
    /// for any cancel path. `hints` are the crosshair badge's mode lines.
    func select(
        hints: [String] = CrosshairRender.Hints.region,
        hotkeyToken: SignpostMetrics.Token? = nil
    ) async -> OverlaySelection {
        if continuation != nil {
            os_log("OverlayController.select re-entry — ignoring", log: log, type: .info)
            if let token = hotkeyToken { SignpostMetrics.end(token) }
            return .cancelled
        }

        return await withCheckedContinuation { (cont: CheckedContinuation<OverlaySelection, Never>) in
            self.continuation = cont
            self.startSession(hints: hints, hotkeyToken: hotkeyToken)
        }
    }

    /// Best-effort loupe source: stored for (re-)application on session start
    /// and pushed to any live views. `nil` clears (a fresh trigger's grab is
    /// still in flight).
    func updateLoupeSource(_ frames: FrozenFrameSet?) {
        loupeFrames = frames
        for (screen, view) in views {
            view.loupeImage = frames?.frame(for: screen)?.image
        }
    }

    private func startSession(hints: [String], hotkeyToken: SignpostMetrics.Token?) {
        let screens = NSScreen.screens
        if screens.isEmpty {
            os_log("startSession: NSScreen.screens is empty — cancelling", log: log, type: .error)
            if let token = hotkeyToken { SignpostMetrics.end(token) }
            if let cont = continuation {
                continuation = nil
                cont.resume(returning: .cancelled)
            }
            return
        }
        for screen in screens {
            let panel = OverlayPanel(screen: screen)
            let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.hintLines = hints
            view.loupeImage = loupeFrames?.frame(for: screen)?.image
            view.onComplete = { [weak self] rect in
                self?.completeRegion(globalRect: rect, screen: screen)
            }
            view.onSpacebarCycle = { [weak self] in
                self?.completeCycle()
            }
            panel.contentView = view
            panel.initialFirstResponder = view
            // orderFrontRegardless joins the active Space even when a different
            // app is in native full-screen; orderFront would leave us behind it.
            panel.orderFrontRegardless()
            panels.append(panel)
            views.append((screen, view))
        }
        if let first = panels.first {
            first.makeKey()
            first.makeFirstResponder(first.contentView)
        }
        if let token = hotkeyToken { SignpostMetrics.end(token) }
    }

    private func completeRegion(globalRect: CGRect?, screen: NSScreen) {
        guard let cont = continuation else { return }
        continuation = nil
        for panel in panels { panel.close() }
        panels.removeAll()
        views.removeAll()
        if let rect = globalRect, !rect.isEmpty {
            cont.resume(returning: .region(SelectedRegion(globalRect: rect, screen: screen)))
        } else {
            cont.resume(returning: .cancelled)
        }
    }

    private func completeCycle() {
        guard let cont = continuation else { return }
        continuation = nil
        for panel in panels { panel.close() }
        panels.removeAll()
        views.removeAll()
        cont.resume(returning: .cycle)
    }
}
