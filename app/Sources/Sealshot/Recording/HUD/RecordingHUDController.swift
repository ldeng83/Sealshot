import AppKit

/// Owns the floating recording HUD panel — a draggable dot shown while
/// recording. Created on demand (recordingDidStart), removed on stop. Floats
/// over full-screen apps via the same panel recipe as the countdown ring, but
/// accepts mouse events (hover/click/drag). Tracks pause-excluded elapsed on a
/// 1 s timer and persists its on-screen position.
@MainActor
final class RecordingHUDController: NSObject, RecordingStateObserver {
    private let recording: RecordingCoordinator
    private var panel: NSPanel?
    private var view: RecordingHUDView?
    private var timer: Timer?
    private var labelPanel: NSPanel?
    private var chevronPanel: NSPanel?

    /// Entrance tuning: the HUD slides up from below its resting spot,
    /// overshoots a touch, and settles; the dot pulses; a chevron bounces
    /// toward the pill under the "Recording" caption. The pill stays
    /// expanded (Pause/Stop visible) for the WHOLE recording — controls
    /// must always be findable, so there is no collapse.
    private enum Entrance {
        static let slideDistance: CGFloat = 120
        static let slideDuration: TimeInterval = 0.42
        static let overshoot: CGFloat = 8
        static let settleDuration: TimeInterval = 0.13
        static let pulses = 3
        static let labelVisibleSeconds: TimeInterval = 1.8
        static let chevronBounces = 5
        static let chevronGap: CGFloat = 8        // pill edge → chevron panel
        static let labelGap: CGFloat = 6          // chevron panel → caption
    }

    /// True when the caption+chevron stack fits above the pill; false parks it
    /// below (HUD dragged near the top of the screen) with the chevron flipped
    /// to point up at the pill. Pure for testing.
    nonisolated static func entranceStackAbove(hudMaxY: CGFloat, stackHeight: CGFloat,
                                               screenTopY: CGFloat) -> Bool {
        hudMaxY + stackHeight <= screenTopY
    }

    // Pause-excluded elapsed accounting (mirrors the menu-bar item).
    private var accumulated: TimeInterval = 0
    private var segmentStart: Date?
    private var paused = false

    init(recording: RecordingCoordinator) {
        self.recording = recording
        super.init()
        recording.addObserver(self)
    }

    // MARK: - RecordingStateObserver

    func recordingDidStart() { show() }
    func recordingDidStop() { hide() }

    func recordingPausedChanged(_ paused: Bool) {
        if paused, let start = segmentStart { accumulated += Date().timeIntervalSince(start); segmentStart = nil }
        else if !paused, segmentStart == nil { segmentStart = Date() }
        self.paused = paused
        var s = view?.state ?? RecordingHUDState()
        s.isPaused = paused
        view?.state = s
        tick()
    }

    // MARK: - Show / hide

    private func show() {
        accumulated = 0; segmentStart = Date(); paused = false

        let v = RecordingHUDView(frame: .zero)
        v.autoresizingMask = [.width, .height]
        v.onPause = { [weak self] in self?.recording.togglePause() }
        v.onStop = { [weak self] in self?.recording.stopRecording() }
        v.onExpansionChange = { [weak self] in self?.resizeToFit() }
        v.onMoved = { [weak self] in self?.persistPosition() }

        // Expanded (Pause/Stop visible) for the whole recording — the user
        // must always be able to see the controls, so the pill never
        // collapses to the bare dot.
        var s = v.state; s.setGraceExpanded(true); v.state = s

        let p = NSPanel(contentRect: NSRect(origin: .zero, size: v.desiredSize),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .screenSaver
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.ignoresMouseEvents = false
        p.contentView = v

        positionPanel(p, size: v.desiredSize)
        panel = p; view = v
        animateEntrance(panel: p, view: v)
        startTimer()
        tick()
    }

    private func hide() {
        timer?.invalidate(); timer = nil
        labelPanel?.orderOut(nil); labelPanel = nil
        chevronPanel?.orderOut(nil); chevronPanel = nil
        panel?.orderOut(nil)
        panel = nil; view = nil
        accumulated = 0; segmentStart = nil; paused = false
    }

    // MARK: - Entrance (slide up + pulse + "Recording" label)

    /// Slide the HUD up from below its resting spot while fading in, overshoot
    /// a few points, settle back, and pulse the dot. Motion + the transient
    /// label exist because the resting pill is small enough to miss entirely.
    private func animateEntrance(panel p: NSPanel, view v: RecordingHUDView) {
        let final = p.frame.origin
        let size = p.frame.size
        p.setFrameOrigin(NSPoint(x: final.x, y: final.y - Entrance.slideDistance))
        p.alphaValue = 0
        p.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Entrance.slideDuration
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
            p.animator().alphaValue = 1
            p.animator().setFrame(
                NSRect(origin: NSPoint(x: final.x, y: final.y + Entrance.overshoot), size: size),
                display: true)
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.panel === p else { return }   // stopped mid-entrance
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = Entrance.settleDuration
                    p.animator().setFrame(NSRect(origin: final, size: size), display: true)
                }, completionHandler: nil)
            }
        })

        v.beginEntrancePulse(count: Entrance.pulses)
        presentCaptionAndChevron(hudFrame: NSRect(origin: final, size: size))
    }

    /// Lay out the transient "Recording" caption + bouncing chevron pointing at
    /// the pill. The stack normally sits above the pill (chevron pointing down);
    /// when the HUD is parked near the top of the screen it flips below with
    /// the chevron pointing up. Both are mouse-transparent.
    private func presentCaptionAndChevron(hudFrame: NSRect) {
        let caption = makeCaptionPanel()
        let labelSize = caption.frame.size
        let chevSize = RecordingChevronView.panelSize
        let stackHeight = Entrance.chevronGap + chevSize.height + Entrance.labelGap + labelSize.height

        let screen = NSScreen.screens.first { $0.frame.intersects(hudFrame) } ?? NSScreen.main
        let above = Self.entranceStackAbove(
            hudMaxY: hudFrame.maxY, stackHeight: stackHeight,
            screenTopY: screen?.visibleFrame.maxY ?? .greatestFiniteMagnitude)

        let chevY = above ? hudFrame.maxY + Entrance.chevronGap
                          : hudFrame.minY - Entrance.chevronGap - chevSize.height
        let labelY = above ? chevY + chevSize.height + Entrance.labelGap
                           : chevY - Entrance.labelGap - labelSize.height

        showChevron(pointsDown: above,
                    origin: NSPoint(x: hudFrame.midX - chevSize.width / 2, y: chevY))
        presentCaption(caption,
                       origin: NSPoint(x: hudFrame.midX - labelSize.width / 2, y: labelY))
    }

    /// Sized (unpositioned) caption panel for the transient "Recording" text.
    private func makeCaptionPanel() -> NSPanel {
        let label = NSTextField(labelWithString: "Recording")
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .white
        label.sizeToFit()

        let padH: CGFloat = 12, padV: CGFloat = 5
        let size = NSSize(width: label.frame.width + padH * 2,
                          height: label.frame.height + padV * 2)
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(white: 0.11, alpha: 0.85).cgColor
        container.layer?.cornerRadius = 8
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor(white: 1, alpha: 0.12).cgColor
        label.setFrameOrigin(NSPoint(x: padH, y: padV))
        container.addSubview(label)

        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .screenSaver
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.ignoresMouseEvents = true
        p.contentView = container
        return p
    }

    /// Fade the caption in at `origin`; fade out + close after `labelVisibleSeconds`.
    private func presentCaption(_ p: NSPanel, origin: NSPoint) {
        p.setFrameOrigin(origin)
        p.alphaValue = 0
        p.orderFrontRegardless()
        labelPanel = p

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            p.animator().alphaValue = 1
        }, completionHandler: nil)

        Timer.scheduledTimer(withTimeInterval: Entrance.labelVisibleSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.labelPanel === p else { return }
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.35
                    p.animator().alphaValue = 0
                }, completionHandler: { [weak self] in
                    MainActor.assumeIsolated {
                        p.orderOut(nil)
                        if let self, self.labelPanel === p { self.labelPanel = nil }
                    }
                })
            }
        }
    }

    /// White chevron that bounces toward the pill `chevronBounces` times, then
    /// fades out and closes. Shadow-free (a glyph, not a card).
    private func showChevron(pointsDown: Bool, origin: NSPoint) {
        let v = RecordingChevronView(pointsDown: pointsDown)
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: RecordingChevronView.panelSize),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .screenSaver
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.ignoresMouseEvents = true
        p.contentView = v
        p.setFrameOrigin(origin)
        p.orderFrontRegardless()
        chevronPanel = p

        v.onFinished = { [weak self] in
            guard let self, self.chevronPanel === p else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                p.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    p.orderOut(nil)
                    if let self, self.chevronPanel === p { self.chevronPanel = nil }
                }
            })
        }
        v.beginBounce(count: Entrance.chevronBounces)
    }

    // MARK: - Layout / position

    private func resizeToFit() {
        guard let panel, let view else { return }
        panel.setContentSize(view.desiredSize)   // keeps top-left fixed → grows rightward
        view.needsDisplay = true
    }

    /// The HUD lives on the RECORDED screen by default — that's where the
    /// user's attention is, and the HUD is excluded from the capture
    /// (SelfExcludingContentFilter) so it can't spoil the footage.
    ///
    /// Drag memory has two modes, decided by WHERE the user parked it:
    /// - dragged within the recording screen → the offset FOLLOWS whichever
    ///   screen is recorded next (clamped to fit).
    /// - dragged to a DIFFERENT monitor → PINNED to that monitor at that
    ///   offset, regardless of the recorded screen ("keep the controls over
    ///   here"). If the pinned monitor is gone, fall back to follow mode.
    private func positionPanel(_ panel: NSPanel, size: NSSize) {
        let recorded = recording.activeRecordingScreen ?? NSScreen.main ?? NSScreen.screens.first
        let f = recorded?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        guard let saved = RecordingHUDPosition.load() else {
            panel.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.minY + 80))
            return
        }
        if case .pinned(let displayID) = saved.mode,
           let pinnedScreen = Self.screen(withDisplayID: displayID) {
            panel.setFrameOrigin(Self.clampedOrigin(offset: saved.offset,
                                                    screenFrame: pinnedScreen.frame, size: size))
            return
        }
        panel.setFrameOrigin(Self.clampedOrigin(offset: saved.offset, screenFrame: f, size: size))
    }

    /// Apply a screen-relative offset onto `screenFrame`, keeping the whole
    /// HUD on that screen (a spot saved on a large monitor must still fit a
    /// smaller one). Pure for testing.
    nonisolated static func clampedOrigin(offset: NSPoint, screenFrame f: NSRect,
                                          size: NSSize) -> NSPoint {
        NSPoint(x: min(max(f.minX + offset.x, f.minX), max(f.maxX - size.width, f.minX)),
                y: min(max(f.minY + offset.y, f.minY), max(f.maxY - size.height, f.minY)))
    }

    private static func screen(withDisplayID id: UInt32) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                .uint32Value == id
        }
    }

    private static func displayID(of screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
            .uint32Value
    }

    private func persistPosition() {
        guard let origin = panel?.frame.origin else { return }
        // The screen the HUD was parked on (drags can land it on any monitor).
        let screen = NSScreen.screens.first {
            $0.frame.intersects(NSRect(origin: origin, size: panel?.frame.size ?? .zero))
        } ?? NSScreen.main
        guard let screen else { return }
        let f = screen.frame
        let offset = NSPoint(x: origin.x - f.minX, y: origin.y - f.minY)
        // Parked on the recording screen = a relative preference that follows
        // the recording; parked anywhere else = deliberately pinned there.
        let onRecordingScreen = screen == recording.activeRecordingScreen
        if onRecordingScreen {
            RecordingHUDPosition.save(.init(mode: .followRecording, offset: offset))
        } else if let id = Self.displayID(of: screen) {
            RecordingHUDPosition.save(.init(mode: .pinned(displayID: id), offset: offset))
        } else {
            RecordingHUDPosition.save(.init(mode: .followRecording, offset: offset))
        }
    }

    // MARK: - Elapsed timer

    private func startTimer() {
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer = t
        RunLoop.main.add(t, forMode: .common)
    }

    private func tick() {
        guard let view else { return }
        var total = accumulated
        if let start = segmentStart { total += Date().timeIntervalSince(start) }
        let secs = Int(total)
        guard view.state.elapsedSeconds != secs else { return }
        var s = view.state; s.elapsedSeconds = secs; view.state = s
        resizeToFit()   // width may change (e.g. 9:59 → 10:00)
    }
}

/// Remembered HUD position (UserDefaults): an offset WITHIN a screen, plus
/// the mode that says which screen that is — `followRecording` re-applies it
/// to whichever screen is recorded; `pinned` targets one specific monitor
/// (chosen by dragging the HUD off the recording screen). The old
/// absolute-origin keys are intentionally not read.
enum RecordingHUDPosition {
    enum Mode: Equatable {
        case followRecording
        case pinned(displayID: UInt32)
    }
    struct Saved: Equatable {
        var mode: Mode
        var offset: NSPoint
    }

    private static let kx = "recordingHUDOffsetX"
    private static let ky = "recordingHUDOffsetY"
    private static let kPinned = "recordingHUDPinnedDisplayID"   // absent = follow

    static func load() -> Saved? {
        let d = UserDefaults.standard
        guard d.object(forKey: kx) != nil, d.object(forKey: ky) != nil else { return nil }
        let offset = NSPoint(x: d.double(forKey: kx), y: d.double(forKey: ky))
        if let pinned = d.object(forKey: kPinned) as? NSNumber {
            return Saved(mode: .pinned(displayID: pinned.uint32Value), offset: offset)
        }
        return Saved(mode: .followRecording, offset: offset)
    }

    static func save(_ saved: Saved) {
        let d = UserDefaults.standard
        d.set(Double(saved.offset.x), forKey: kx)
        d.set(Double(saved.offset.y), forKey: ky)
        switch saved.mode {
        case .followRecording: d.removeObject(forKey: kPinned)
        case .pinned(let id): d.set(NSNumber(value: id), forKey: kPinned)
        }
    }
}
