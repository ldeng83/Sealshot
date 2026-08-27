import SwiftUI
import AppKit

/// Borderless, non-activating floating panel that hosts the Quick Look preview.
/// It is sized to the whole screen and fully transparent — the dim + centered
/// card are drawn by SwiftUI (`QuickLookOverlayContent`), so it reads like the
/// old in-window overlay (no window chrome) while still letting the card grow
/// larger than the app window. Never-key so the main editor window keeps the
/// keyboard and first responder (which also stops the video's AVPlayerView from
/// stealing focus to the search field).
final class QuickLookFloatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The panel can never become key, so EVERY click on it is a "first mouse" —
/// and NSView refuses those by default, which silently ate the overlay's
/// click-away tap-catcher (clicking the dim never dismissed). Accepting first
/// mouse delivers clicks (dismiss, the Open-in-Editor button) on the first
/// click, with no activation dance.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Bridges `viewModel.quickLookOpen` to the floating panel's lifecycle. Placed as
/// a `.background` of the Library so it has a host window to attach to.
struct QuickLookPanelPresenter: NSViewRepresentable {
    @Bindable var viewModel: LibraryViewModel
    /// Read as stored values so SwiftUI re-invokes `updateNSView` when they change.
    let isPresented: Bool
    let selectionKey: URL?

    func makeCoordinator() -> Coordinator { Coordinator(viewModel: viewModel) }
    func makeNSView(context: Context) -> NSView { context.coordinator.anchor }

    func updateNSView(_ nsView: NSView, context: Context) {
        let present = isPresented
        DispatchQueue.main.async {
            context.coordinator.sync(isPresented: present, host: nsView.window)
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.dismiss()
    }

    @MainActor final class Coordinator {
        let viewModel: LibraryViewModel
        let anchor = NSView()
        /// Coordinator-owned so it survives content builds and can be torn down
        /// (stopping video) when the panel closes.
        let loader = QuickLookPreviewLoader()
        private var panel: QuickLookFloatingPanel?

        init(viewModel: LibraryViewModel) { self.viewModel = viewModel }

        func sync(isPresented: Bool, host: NSWindow?) {
            if isPresented, let host {
                if panel == nil { present(host: host) }
            } else {
                if panel != nil { dismiss() }
            }
        }

        private func present(host: NSWindow) {
            let screenFrame = (host.screen ?? NSScreen.main)?.visibleFrame
                ?? host.frame
            let p = QuickLookFloatingPanel(
                contentRect: screenFrame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered, defer: false)
            p.isFloatingPanel = true
            p.level = .floating
            p.isOpaque = false
            // The dim is the WINDOW background (behind everything, incl. the
            // video surface) — not a SwiftUI layer, which AVPlayerView's layer
            // would otherwise sink below and appear dimmed by.
            p.backgroundColor = NSColor.black.withAlphaComponent(0.32)
            p.hasShadow = false
            p.hidesOnDeactivate = false
            p.ignoresMouseEvents = false
            p.contentView = FirstMouseHostingView(rootView:
                QuickLookOverlayContent(viewModel: viewModel, loader: loader))
            p.setFrame(screenFrame, display: true)
            p.orderFront(nil)
            panel = p
            // The Space key (routed by the main window) toggles video playback
            // through the active loader while the panel is up.
            viewModel.quickLookLoader = loader
        }

        func dismiss() {
            viewModel.quickLookLoader = nil
            loader.teardown()
            if let p = panel {
                p.orderOut(nil)
                panel = nil
            }
        }
    }
}
