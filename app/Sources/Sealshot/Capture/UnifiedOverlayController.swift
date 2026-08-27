import AppKit
import ScreenCaptureKit
import KeyboardShortcuts
import os.log

private let log = OSLog(subsystem: "com.seal-shot.sealshot", category: "capture")

/// The unified capture overlay: one interactive session where hovering
/// highlights the window under the cursor (click to capture it) and dragging
/// selects an area (dim appears on drag). Every panel shows its display's
/// FROZEN image as the backdrop (grabbed at trigger time), so the user selects
/// from a still screen and the result is cropped from those pixels. Mirrors
/// `WindowPickerController`'s lifecycle (activating panels, Esc/mouse
/// monitors); candidates are a one-shot snapshot, not a poll.
@MainActor
final class UnifiedOverlayController {
    enum Result {
        case window(SCWindow, NSScreen, SignpostMetrics.Token)
        case region(SelectedRegion)
        case cancelled
    }

    private var panels: [WindowPickerPanel] = []
    private var views: [UnifiedSelectionView] = []
    private var continuation: CheckedContinuation<Result, Never>?
    /// True while a session is on screen (the coordinator's busy gate).
    var isRunning: Bool { continuation != nil }
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var didBecomeActiveObserver: NSObjectProtocol?

    /// Run a selection session over the frozen frames: each display's panel
    /// shows its frozen image as the backdrop, so the user picks a window or
    /// area from a still screen. Candidates are a one-shot snapshot (frames
    /// can't move on a frozen screen — no polling).
    /// `dragOnly` drops the click-candidates (windows + detected boundaries)
    /// so only a drag selects — scroll capture uses it to make the user
    /// choose exactly the area their scrolling content occupies, instead of
    /// grabbing a whole window with its fixed chrome.
    func select(
        frames: FrozenFrameSet,
        hints: [String] = CrosshairRender.Hints.unified,
        dragOnly: Bool = false,
        hotkeyToken: SignpostMetrics.Token? = nil
    ) async -> Result {
        if continuation != nil {
            os_log("UnifiedOverlay.select re-entry — ignoring", log: log, type: .info)
            if let token = hotkeyToken { SignpostMetrics.end(token) }
            return .cancelled
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<Result, Never>) in
            self.continuation = cont
            self.startSession(frames: frames, hints: hints, dragOnly: dragOnly,
                              hotkeyToken: hotkeyToken)
        }
    }

    /// Called from the global Esc hotkey (`.pickerCancel`) while a session is
    /// active — lets the user cancel after Cmd+Tabbing to another app.
    func cancelFromGlobalEsc() {
        guard continuation != nil else { return }
        completeCancel()
    }

    private func startSession(frames: FrozenFrameSet, hints: [String], dragOnly: Bool,
                              hotkeyToken: SignpostMetrics.Token?) {
        let screens = NSScreen.screens
        if screens.isEmpty {
            os_log("UnifiedOverlay startSession: NSScreen.screens empty", log: log, type: .error)
            if let token = hotkeyToken { SignpostMetrics.end(token) }
            if let cont = continuation {
                continuation = nil
                cont.resume(returning: .cancelled)
            }
            return
        }

        NSApp.activate(ignoringOtherApps: true)

        for screen in screens {
            // Opaque only when this screen actually has a frozen backdrop to
            // cover it; without one the panel must stay transparent or it
            // would paint the display black.
            let panel = WindowPickerPanel(screen: screen,
                                          opaque: frames.frame(for: screen) != nil)
            let size = screen.frame.size
            let view = UnifiedSelectionView(frame: NSRect(origin: .zero, size: size))
            view.hintLines = hints
            view.loupeImage = frames.frame(for: screen)?.image
            view.onWindow = { [weak self] win in
                self?.completeWindow(win, screen: screen)
            }
            view.onRegion = { [weak self] globalRect in
                self?.completeRegion(globalRect: globalRect, screen: screen)
            }
            view.onCancel = { [weak self] in
                self?.completeCancel()
            }
            view.onAreaDragStarted = { [weak self, weak view] in
                self?.clearOthers(except: view)
            }

            // Frozen backdrop: the display's image at trigger time sits behind
            // the (transparent) selection view, so the screen appears to stop
            // and every selection mode crops from these pixels.
            let container = NSView(frame: NSRect(origin: .zero, size: size))
            container.wantsLayer = true
            if let frame = frames.frame(for: screen) {
                // Hand the frozen frame straight to CoreAnimation as layer
                // contents instead of wrapping it in an NSImage/NSImageView.
                // The old path went through AppKit's image drawing on first
                // display — one full-screen (~7 megapixel) decode-and-scale on
                // the very frame the user is waiting to see, which is what made
                // the overlay feel like it dragged as it appeared. As layer
                // contents the texture is uploaded once and never redrawn: the
                // backdrop is frozen, so it should cost nothing after that.
                let backdrop = NSView(frame: container.bounds)
                backdrop.wantsLayer = true
                backdrop.layer?.contents = frame.image
                backdrop.layer?.contentsGravity = .resize
                // Nothing shows through the frozen screen, so let the
                // compositor skip blending what is behind it.
                backdrop.layer?.isOpaque = true
                backdrop.autoresizingMask = [.width, .height]
                container.addSubview(backdrop)
            }
            view.autoresizingMask = [.width, .height]
            container.addSubview(view)

            panel.contentView = container
            panel.initialFirstResponder = view
            // orderFrontRegardless (not orderFront): when a different app is in
            // native full-screen, orderFront drops the panel onto our own Space
            // behind the full-screen window. orderFrontRegardless is what
            // actually joins the active full-screen Space.
            panel.orderFrontRegardless()
            panels.append(panel)
            views.append(view)
        }
        // One-shot candidate snapshot — window frames are frozen with the
        // pixels. Drag-only sessions (scroll capture) feed NO click
        // candidates — windows and boundaries alike — so hover highlights
        // nothing and only a drag selects.
        if !dragOnly {
            for view in views { view.setCandidates(frames.windows) }
        }

        // Detect boundary candidates on each frozen image off the main thread
        // and push them when ready (hover works with windows meanwhile).
        let windowFacts = frames.windows.map {
            (id: $0.windowID, frame: $0.frame,
             bundleID: $0.owningApplication?.bundleIdentifier)
        }
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        for (index, screen) in screens.enumerated() where !dragOnly && index < views.count {
            guard let frame = frames.frame(for: screen) else { continue }
            let image = frame.image
            let viewSize = screen.frame.size
            let screenFrame = screen.frame
            let view = views[index]
            Task.detached(priority: .userInitiated) {
                let pixelRects = BoundaryDetector.detect(in: image)
                let localRects = pixelRects.map {
                    FrozenFrameCrop.viewLocalRect(
                        pixelRect: $0, viewSize: viewSize,
                        imageWidth: image.width, imageHeight: image.height)
                }
                // Window/app-scale areas only — fine-grained elements are
                // intentionally not hover candidates.
                let windowScale = BoundaryCandidates.windowScaleRects(localRects)
                // Permission-free browser fallback: pixel-split each browser
                // window's chrome from its page body on the frozen pixels.
                // Consumed only when the AX probe yields nothing (no
                // Accessibility grant / no usable tree) — AX stays
                // authoritative. See UnifiedSelectionView.hoverBoundaryRects.
                var browserContent: [UInt32: CGRect] = [:]
                let pixelsPerPoint = CGFloat(image.width) / max(viewSize.width, 1)
                for fact in windowFacts where BrowserIdentifier.isBrowser(fact.bundleID) {
                    let local = FrozenFrameCrop.windowViewLocalRect(
                        windowFrame: fact.frame, screenFrame: screenFrame,
                        primaryMaxY: primaryMaxY)
                    // The chrome band must be fully on this screen (a top
                    // edge that's clipped can't be split meaningfully).
                    guard local.maxY <= viewSize.height + 0.5, local.minX >= -0.5,
                          local.maxX <= viewSize.width + 0.5,
                          local.width >= 320, local.height >= 200,
                          let windowImage = FrozenFrameCrop.crop(
                            image, viewLocal: local, viewSize: viewSize),
                          let chrome = BrowserChromeSplit.chromeHeight(
                            in: windowImage, pixelsPerPoint: pixelsPerPoint)
                    else { continue }
                    // View-local is bottom-left origin: shaving the chrome
                    // off the TOP keeps the bottom edge, shrinks the height.
                    let content = CGRect(x: local.minX, y: local.minY,
                                         width: local.width,
                                         height: local.height - chrome)
                    if content.height >= AXElementProbe.minElementSize.height {
                        browserContent[fact.id] = content
                    }
                }
                let fallbacks = browserContent
                await MainActor.run { [weak view] in
                    view?.setBoundaryRects(windowScale)
                    view?.setBrowserContentRects(fallbacks)
                }
            }
        }
        if let first = panels.first, let firstView = views.first {
            // makeKey (not makeKeyAndOrderFront): the panels are already on the
            // active Space via orderFrontRegardless above; makeKeyAndOrderFront
            // would re-order through the path that fails to join a full-screen
            // Space. Just take key for the Esc/Space responder chain.
            first.makeKey()
            first.makeFirstResponder(firstView)
        }
        if let token = hotkeyToken { SignpostMetrics.end(token) }

        KeyboardShortcuts.setShortcut(.init(.escape, modifiers: []), for: .pickerCancel)
        installEventMonitors()
        installActivationObserver()
    }

    /// A new selection started on `active`'s display — clear every OTHER
    /// display's hover highlight AND any adjustable box, so only one selection
    /// exists at a time across screens.
    private func clearOthers(except active: UnifiedSelectionView?) {
        for view in views where view !== active {
            view.clearHighlight()
            view.exitAdjust()
        }
    }

    private func installActivationObserver() {
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
        guard let first = panels.first, let firstView = views.first else { return }
        first.makeKeyAndOrderFront(nil)
        first.makeFirstResponder(firstView)
        first.invalidateCursorRects(for: firstView)
    }

    private func installEventMonitors() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { // Esc
                Task { @MainActor in self.completeCancel() }
                return nil
            }
            return event
        }
        // Handled INLINE, not through `Task { @MainActor }`. These monitor
        // callbacks already run on the main thread, so the hop only deferred
        // the work to a later run-loop turn: a burst of events queued a burst
        // of tasks that then ran together, and each read the same current
        // `NSEvent.mouseLocation`, collapsing into ONE crosshair position.
        // Measured at ~4 events per distinct position, which capped the
        // crosshair at ~22 updates/s while the display refreshed at 55.
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            guard let self else { return event }
            MainActor.assumeIsolated { self.notifyMouseMoved() }
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated { self.notifyMouseMoved() }
        }
    }

    @MainActor
    private func notifyMouseMoved() {
        for view in views { view.handleMouseMoved() }
    }

    private func tearDown() {
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
        KeyboardShortcuts.setShortcut(nil, for: .pickerCancel)
    }

    private func completeWindow(_ win: SCWindow, screen: NSScreen) {
        guard let cont = continuation else { return }
        continuation = nil
        tearDown()
        let captureSpan = SignpostMetrics.begin("unified-to-window-capture")
        cont.resume(returning: .window(win, screen, captureSpan))
    }

    private func completeRegion(globalRect: CGRect?, screen: NSScreen) {
        guard let cont = continuation else { return }
        continuation = nil
        tearDown()
        if let rect = globalRect, !rect.isEmpty {
            cont.resume(returning: .region(SelectedRegion(globalRect: rect, screen: screen)))
        } else {
            cont.resume(returning: .cancelled)
        }
    }

    private func completeCancel() {
        guard let cont = continuation else { return }
        continuation = nil
        tearDown()
        cont.resume(returning: .cancelled)
    }
}
