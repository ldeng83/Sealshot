import AppKit
import AVFoundation
import AVKit
import os

private let log = OSLog(subsystem: "com.seal-shot.sealshot", category: "video-player")

/// A video surface with a fully custom, auto-hiding transport bar. Uses
/// `AVPlayerView` with `controlsStyle = .none` (Apple's controls hidden) rather
/// than a raw `AVPlayerLayer`: the player view composites overlaid subviews
/// (our controls, the center play button) reliably on top, whereas a bare
/// `AVPlayerLayer`'s video surface paints OVER sibling layers once the first
/// frame loads (which was hiding the center play button).
///
/// Owns the periodic time observer, the end-of-item observer, and the auto-hide
/// timer; the `AVPlayer` itself (and, for encrypted recordings, its
/// `SealedRecordingPlayer`) is owned by the caller. Call `teardown()` before
/// discarding so the observers and timer are removed.
final class CanvasVideoPlayerView: NSView, NSGestureRecognizerDelegate {

    private let player: AVPlayer
    private let onClose: () -> Void
    private let onCaptureFrame: () -> Void
    /// Right-click menu for the video surface, supplied by the host. Without
    /// one, a right-click on a paused recording used to hit Apple's Live Text
    /// menu (now disabled) and would otherwise hit nothing at all.
    var contextMenuProvider: (() -> NSMenu?)?

    private let playerView = AVPlayerView()
    /// Magnifying host for the video surface. The document (`videoDocument`,
    /// holding the player view) stays at NATIVE pixel size; zoom is GPU
    /// magnification only — never a frame resize (the reverted pitfall).
    private let zoomScroll = VideoZoomScrollView()
    private let videoDocument = NSView()
    /// Clip-view origin at pan start (drag-to-pan when zoomed in).
    private var panStartOrigin: NSPoint = .zero
    /// Large centered play affordance shown over the poster frame while paused
    /// — the recording opens paused on its first frame, not auto-playing.
    /// Backed by a frosted `NSVisualEffectView` circle: a plain layer-backed
    /// view in the player's content-overlay gets painted over by the video
    /// surface, whereas a visual-effect view composites above it (same reason
    /// the transport bar stays visible).
    private let bigPlayBackdrop = NSVisualEffectView()
    private let bigPlayButton = NSButton()
    private let controlBar = NSVisualEffectView()
    private let scrubber = VideoScrubber()
    private let playPauseButton = NSButton()
    private let muteButton = NSButton()
    private let loopButton = NSButton()
    private let speedButton = NSButton()
    private let volumeSlider = NSSlider()
    private let elapsedLabel = NSTextField(labelWithString: "0:00")
    private let durationLabel = NSTextField(labelWithString: "0:00")

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var hideTimer: Timer?
    private var trackingArea: NSTrackingArea?

    private var duration: Double = 0
    private var frameStep: Double = 1.0 / 30.0   // refined from the video track
    private var currentSpeed: Float = 1.0
    private var isLooping = false
    private var isScrubbing = false
    /// True once the item has played to the end (and we're not looping) — the
    /// next "play" restarts from zero rather than no-opping at the tail.
    private var atEnd = false

    /// `showsCornerCamera` puts the frame-grab button in the top-right corner —
    /// used only as a fallback when there's no right sidebar to host it (the
    /// empty editor). When a sidebar is present it owns the frame-grab button.
    private let showsCornerCamera: Bool

    init(player: AVPlayer,
         onClose: @escaping () -> Void,
         onCaptureFrame: @escaping () -> Void,
         showsCornerCamera: Bool) {
        self.player = player
        self.onClose = onClose
        self.onCaptureFrame = onCaptureFrame
        self.showsCornerCamera = showsCornerCamera
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        buildVideoLayer()
        buildControls()
        observePlayer()
        loadTrackInfo()
        updatePlayPauseIcon()
        revealControls()
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    // MARK: - Layout

    private func buildVideoLayer() {
        playerView.player = player
        playerView.controlsStyle = .none
        playerView.videoGravity = .resizeAspect
        // Apple's Live Text on paused frames is ON by default, and it swallows
        // the right-click: the system menu (Look Up / Translate / Search With
        // Google / Copy Subject) appears instead of Sealshot's, and the video
        // is the user's OWN recording, not a web page to search. Sealshot has
        // its own text recognition for that, on its own terms.
        if #available(macOS 13.0, *) { playerView.allowsVideoFrameAnalysis = false }
        playerView.allowsPictureInPicturePlayback = false
        playerView.translatesAutoresizingMaskIntoConstraints = false

        // Player pinned inside a native-size document container; the container
        // is the zoom scroll view's document, so zoom is pure magnification.
        videoDocument.addSubview(playerView)
        NSLayoutConstraint.activate([
            playerView.leadingAnchor.constraint(equalTo: videoDocument.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: videoDocument.trailingAnchor),
            playerView.topAnchor.constraint(equalTo: videoDocument.topAnchor),
            playerView.bottomAnchor.constraint(equalTo: videoDocument.bottomAnchor),
        ])
        zoomScroll.documentView = videoDocument
        zoomScroll.translatesAutoresizingMaskIntoConstraints = false
        // Added first so the transport chrome (added later, directly on self)
        // overlays on top of it — and stays UNMAGNIFIED while the video zooms.
        addSubview(zoomScroll)
        NSLayoutConstraint.activate([
            zoomScroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            zoomScroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            zoomScroll.topAnchor.constraint(equalTo: topAnchor),
            zoomScroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Click the bare video to toggle play/pause. A delegate gates the
        // gesture so it only fires on the video itself — without it the
        // recognizer swallows single clicks meant for the overlay controls
        // (buttons/scrubber), so only drags reached them.
        let click = NSClickGestureRecognizer(target: self, action: #selector(togglePlay))
        click.delegate = self
        playerView.addGestureRecognizer(click)

        // Drag pans the zoomed video (a drag is not a click, so this coexists
        // with the play/pause click). When the content fits the viewport the
        // clip's centering clamp makes the pan a no-op.
        let pan = NSPanGestureRecognizer(target: self, action: #selector(panVideo(_:)))
        videoDocument.addGestureRecognizer(pan)
    }

    /// Drag-to-pan: shift the clip origin opposite the drag so the content
    /// follows the cursor. Translation is measured in the (stable) outer view
    /// and divided by the magnification to land in document coordinates.
    @objc private func panVideo(_ gesture: NSPanGestureRecognizer) {
        let clip = zoomScroll.contentView
        switch gesture.state {
        case .began:
            panStartOrigin = clip.bounds.origin
        case .changed:
            let t = gesture.translation(in: self)
            let z = max(zoomScroll.magnification, 0.0001)
            // NOTE for smoke test: content must FOLLOW the cursor. If the
            // vertical direction is inverted at runtime (flipped-coordinate
            // mismatch), negate `t.y` here.
            clip.scroll(to: NSPoint(x: panStartOrigin.x - t.x / z,
                                    y: panStartOrigin.y - t.y / z))
            zoomScroll.reflectScrolledClipView(clip)
        default:
            break
        }
    }

    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    // MARK: - Controls

    private func buildControls() {
        // Host the controls on the OUTER view, ABOVE the zoom scroll view —
        // they must stay unmagnified while the video zooms. They are
        // NSVisualEffectView-backed, which is what reliably composites above
        // the video surface (plain layer-backed views got painted over when
        // they lived inside the player; as siblings above the scroll view
        // they are further from the video surface still).
        let host: NSView = self

        // Frame-grab normally lives in the right sidebar; only fall back to a
        // top-right corner button when there's no sidebar. (Esc closes.)
        var camera: NSButton?
        if showsCornerCamera {
            let c = cornerButton("camera.fill", tip: "Save current frame as an image",
                                 action: #selector(captureTapped))
            host.addSubview(c)
            camera = c
        }

        // Big centered play button over the poster frame (visible while paused),
        // on a frosted-circle backdrop so it composites above the video.
        let bigSize: CGFloat = 64
        bigPlayBackdrop.material = .hudWindow
        bigPlayBackdrop.blendingMode = .withinWindow
        bigPlayBackdrop.state = .active
        bigPlayBackdrop.wantsLayer = true
        bigPlayBackdrop.layer?.cornerRadius = bigSize / 2
        bigPlayBackdrop.maskImage = Self.circleMask(diameter: bigSize)
        bigPlayBackdrop.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(bigPlayBackdrop)

        let bigConfig = NSImage.SymbolConfiguration(pointSize: 26, weight: .semibold)
        bigPlayButton.image = NSImage(systemSymbolName: "play.fill",
                                      accessibilityDescription: "Play")?
            .withSymbolConfiguration(bigConfig)
        bigPlayButton.isBordered = false
        bigPlayButton.bezelStyle = .regularSquare
        // Image-only so the triangle stays centered when the button is sized to
        // fill the whole circular backdrop (below) — the entire circle, not just
        // the triangle, is the click target.
        bigPlayButton.imagePosition = .imageOnly
        bigPlayButton.contentTintColor = .white
        bigPlayButton.target = self
        bigPlayButton.action = #selector(togglePlay)
        bigPlayButton.translatesAutoresizingMaskIntoConstraints = false
        bigPlayBackdrop.addSubview(bigPlayButton)

        controlBar.material = .hudWindow
        controlBar.blendingMode = .withinWindow
        controlBar.state = .active
        controlBar.wantsLayer = true
        controlBar.layer?.cornerRadius = 10
        controlBar.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(controlBar)

        configureBarButton(playPauseButton, symbol: "pause.fill",
                           tip: "Play / Pause (Space)", action: #selector(togglePlay))
        let jumpStart = makeBarButton("backward.end.fill", tip: "Jump to start",
                                      action: #selector(jumpToStart))
        let jumpEnd = makeBarButton("forward.end.fill", tip: "Jump to end",
                                    action: #selector(jumpToEnd))
        let frameBack = makeBarButton("backward.frame.fill", tip: "Previous frame (hold to repeat)",
                                      action: #selector(stepBack), repeating: true)
        let frameFwd = makeBarButton("forward.frame.fill", tip: "Next frame (hold to repeat)",
                                     action: #selector(stepForward), repeating: true)
        configureBarButton(loopButton, symbol: "repeat", tip: "Loop",
                           action: #selector(toggleLoop))
        configureBarButton(muteButton, symbol: "speaker.wave.2.fill", tip: "Mute",
                           action: #selector(toggleMute))
        speedButton.title = "1×"
        configureBarButton(speedButton, symbol: nil, tip: "Playback speed",
                           action: #selector(showSpeedMenu))
        speedButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        speedButton.contentTintColor = .white

        for label in [elapsedLabel, durationLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            label.textColor = .white
            label.translatesAutoresizingMaskIntoConstraints = false
        }

        scrubber.translatesAutoresizingMaskIntoConstraints = false
        scrubber.onScrub = { [weak self] fraction in self?.scrub(to: fraction, ended: false) }
        scrubber.onScrubEnd = { [weak self] fraction in self?.scrub(to: fraction, ended: true) }

        volumeSlider.minValue = 0
        volumeSlider.maxValue = 1
        volumeSlider.floatValue = player.volume
        volumeSlider.target = self
        volumeSlider.action = #selector(volumeChanged)
        volumeSlider.controlSize = .small
        volumeSlider.translatesAutoresizingMaskIntoConstraints = false

        // Transport cluster with play centered in the 5-button group:
        //   [jumpStart] [frameBack] [play] [frameFwd] [jumpEnd] [elapsed]
        //   [=== scrubber ===] [duration] [speed] [loop] [mute] [volume]
        let leftCluster = NSStackView(views: [jumpStart, frameBack, playPauseButton,
                                              frameFwd, jumpEnd, elapsedLabel])
        let rightCluster = NSStackView(views: [durationLabel, speedButton, loopButton,
                                               muteButton, volumeSlider])
        for s in [leftCluster, rightCluster] {
            s.orientation = .horizontal
            s.spacing = 8
            s.alignment = .centerY
            s.translatesAutoresizingMaskIntoConstraints = false
        }
        leftCluster.setHuggingPriority(.required, for: .horizontal)
        rightCluster.setHuggingPriority(.required, for: .horizontal)

        let row = NSStackView(views: [leftCluster, scrubber, rightCluster])
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        controlBar.addSubview(row)

        if let camera {
            NSLayoutConstraint.activate([
                camera.topAnchor.constraint(equalTo: host.topAnchor, constant: 10),
                camera.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -10),
                camera.widthAnchor.constraint(equalToConstant: 26),
                camera.heightAnchor.constraint(equalToConstant: 26),
            ])
        }

        NSLayoutConstraint.activate([
            bigPlayBackdrop.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            bigPlayBackdrop.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            bigPlayBackdrop.widthAnchor.constraint(equalToConstant: 64),
            bigPlayBackdrop.heightAnchor.constraint(equalToConstant: 64),
            // Fill the whole circular backdrop so clicking anywhere on the
            // circle plays — not just the small triangle glyph.
            bigPlayButton.leadingAnchor.constraint(equalTo: bigPlayBackdrop.leadingAnchor),
            bigPlayButton.trailingAnchor.constraint(equalTo: bigPlayBackdrop.trailingAnchor),
            bigPlayButton.topAnchor.constraint(equalTo: bigPlayBackdrop.topAnchor),
            bigPlayButton.bottomAnchor.constraint(equalTo: bigPlayBackdrop.bottomAnchor),

            controlBar.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 14),
            controlBar.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -14),
            controlBar.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -14),
            controlBar.heightAnchor.constraint(equalToConstant: 44),

            row.leadingAnchor.constraint(equalTo: controlBar.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: controlBar.trailingAnchor, constant: -12),
            row.centerYAnchor.constraint(equalTo: controlBar.centerYAnchor),

            scrubber.heightAnchor.constraint(equalToConstant: 16),
            volumeSlider.widthAnchor.constraint(equalToConstant: 70),
        ])
        // The scrubber is the only element that should stretch.
        scrubber.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    /// Round white SF-Symbol button for the top corners (matches the existing
    /// overlay style).
    private func cornerButton(_ symbol: String, tip: String, action: Selector) -> NSButton {
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(config)
        let button = NSButton(image: image ?? NSImage(), target: self, action: action)
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.contentTintColor = .white
        button.toolTip = tip
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    private func makeBarButton(_ symbol: String, tip: String, action: Selector,
                               repeating: Bool = false) -> NSButton {
        let b = repeating ? HoldRepeatButton() : NSButton()
        configureBarButton(b, symbol: symbol, tip: tip, action: action)
        return b
    }

    private func configureBarButton(_ b: NSButton, symbol: String?, tip: String, action: Selector) {
        if let symbol {
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
                .withSymbolConfiguration(config)
        }
        b.target = self
        b.action = action
        b.isBordered = false
        b.bezelStyle = .regularSquare
        b.contentTintColor = .white
        b.toolTip = tip
        b.imagePosition = symbol == nil ? .noImage : .imageOnly
        b.translatesAutoresizingMaskIntoConstraints = false
    }

    // MARK: - Player observation

    private func observePlayer() {
        let interval = CMTime(seconds: 0.2, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: interval, queue: .main) { [weak self] time in
            self?.tick(time)
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem, queue: .main) { [weak self] _ in
            self?.playedToEnd()
        }
    }

    private func loadTrackInfo() {
        guard let item = player.currentItem else { return }
        let asset = item.asset
        Task { @MainActor in
            let secs = (try? await asset.load(.duration).seconds) ?? 0
            if secs.isFinite, secs > 0 { duration = secs }
            durationLabel.stringValue = VideoPlaybackMath.timeLabel(duration)
            if let track = try? await asset.loadTracks(withMediaType: .video).first {
                if let fps = try? await track.load(.nominalFrameRate), fps > 0 {
                    frameStep = 1.0 / Double(fps)
                }
                if let ns = try? await track.load(.naturalSize),
                   ns.width > 0, ns.height > 0 {
                    zoomScroll.setVideoSize(CGSize(width: abs(ns.width),
                                                   height: abs(ns.height)))
                }
            }
        }
    }

    private func tick(_ time: CMTime) {
        let t = time.seconds
        elapsedLabel.stringValue = VideoPlaybackMath.timeLabel(t)
        if !isScrubbing {
            scrubber.played = VideoPlaybackMath.fraction(forTime: t, duration: duration)
        }
        scrubber.buffered = bufferedFraction()
        if t > 0 { atEnd = false }
        updatePlayPauseIcon()
    }

    private func bufferedFraction() -> Double {
        guard duration > 0,
              let range = player.currentItem?.loadedTimeRanges.first?.timeRangeValue else { return 0 }
        let end = range.start.seconds + range.duration.seconds
        return VideoPlaybackMath.fraction(forTime: end, duration: duration)
    }

    private func playedToEnd() {
        if isLooping {
            player.seek(to: .zero)
            player.play()
            applyRate()
        } else {
            atEnd = true
            updatePlayPauseIcon()
            revealControls(autoHide: false)   // surface controls at the tail
        }
    }

    private func updatePlayPauseIcon() {
        let playing = player.rate != 0
        let symbol = playing ? "pause.fill" : "play.fill"
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        playPauseButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol)?
            .withSymbolConfiguration(config)
        // Poster affordance: big center play button only while paused.
        bigPlayBackdrop.isHidden = playing
    }

    /// A solid white circle image used as the visual-effect backdrop's mask, so
    /// the frosted material clips to a circle (corner radius alone doesn't clip
    /// an `NSVisualEffectView`).
    private static func circleMask(diameter: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: diameter, height: diameter))
        image.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: diameter, height: diameter)).fill()
        image.unlockFocus()
        image.capInsets = NSEdgeInsets(top: diameter / 2 - 1, left: diameter / 2 - 1,
                                       bottom: diameter / 2 - 1, right: diameter / 2 - 1)
        image.resizingMode = .stretch
        return image
    }

    // MARK: - Actions

    @objc private func captureTapped() { onCaptureFrame() }

    /// Only recognize the click-to-toggle gesture on the bare video — never on
    /// the overlay controls, which handle their own clicks. (Otherwise the
    /// recognizer swallows button/scrubber clicks and only drags get through.)
    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer,
                           shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
        let point = convert(event.locationInWindow, from: nil)
        var hit = playerView.hitTest(point)
        while let v = hit, v !== playerView {
            if v is NSControl || v is VideoScrubber { return false }
            hit = v.superview
        }
        return true
    }

    /// Begin playback (auto-play when opened via a deliberate play affordance,
    /// e.g. the strip's play badge). No-op if already playing.
    func play() {
        guard player.rate == 0 else { return }
        if atEnd { player.seek(to: .zero); atEnd = false }
        player.play()
        applyRate()
        scheduleAutoHide()
        updatePlayPauseIcon()
    }

    @objc func togglePlay() {
        if player.rate != 0 {
            player.pause()
            revealControls(autoHide: false)
        } else {
            if atEnd { player.seek(to: .zero); atEnd = false }
            player.play()
            applyRate()
            scheduleAutoHide()
        }
        updatePlayPauseIcon()
    }

    private func applyRate() {
        // Setting rate also starts playback; only meaningful while playing.
        if player.rate != 0 { player.rate = currentSpeed }
    }

    @objc private func jumpToStart() { seek(toTime: 0) }
    @objc private func jumpToEnd() { seek(toTime: duration) }
    @objc private func stepBack() { stepFrame(by: -frameStep) }
    @objc private func stepForward() { stepFrame(by: frameStep) }

    private func stepFrame(by delta: Double) {
        player.pause()
        updatePlayPauseIcon()
        let target = VideoPlaybackMath.clampedSeek(player.currentTime().seconds + delta,
                                                   duration: duration)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        revealControls(autoHide: false)
    }

    private func seek(toTime t: Double) {
        let target = VideoPlaybackMath.clampedSeek(t, duration: duration)
        atEnd = false
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        scrubber.played = VideoPlaybackMath.fraction(forTime: target, duration: duration)
    }

    private func scrub(to fraction: Double, ended: Bool) {
        isScrubbing = !ended
        let target = VideoPlaybackMath.time(forFraction: fraction, duration: duration)
        atEnd = false
        elapsedLabel.stringValue = VideoPlaybackMath.timeLabel(target)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        revealControls(autoHide: ended && player.rate != 0)
    }

    @objc private func toggleLoop() {
        isLooping.toggle()
        loopButton.contentTintColor = isLooping ? .controlAccentColor : .white
    }

    @objc private func toggleMute() {
        player.isMuted.toggle()
        let symbol = player.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill"
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        muteButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol)?
            .withSymbolConfiguration(config)
    }

    @objc private func volumeChanged() {
        player.volume = volumeSlider.floatValue
        if player.volume > 0 && player.isMuted { toggleMute() }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenuProvider?() ?? super.menu(for: event)
    }

    /// Pop a menu so the user picks a speed directly (vs cycling).
    @objc private func showSpeedMenu() {
        let menu = NSMenu()
        for speed in VideoPlaybackMath.speeds {
            let item = NSMenuItem(title: VideoPlaybackMath.speedLabel(speed),
                                  action: #selector(selectSpeed(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = speed
            item.state = (speed == currentSpeed) ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: menu.item(at: 0),
                   at: NSPoint(x: 0, y: speedButton.bounds.height + 4), in: speedButton)
    }

    @objc private func selectSpeed(_ sender: NSMenuItem) {
        guard let speed = sender.representedObject as? Float else { return }
        currentSpeed = speed
        speedButton.title = VideoPlaybackMath.speedLabel(speed)
        applyRate()
    }

    // MARK: - Zoom (forwarded to the magnifying scroll view)

    /// The transport bar and big play button sit ABOVE the zoom scroll view
    /// as siblings, so scroll/pinch events over them bubble to THIS view and
    /// never reach the scroll view. Forward them, so ⌘-scroll zoom, scroll
    /// pan, and pinch keep working while hovering the chrome — pre-play the
    /// big play button covers the viewport centre, which otherwise made zoom
    /// appear dead until playback started.
    override func scrollWheel(with event: NSEvent) {
        zoomScroll.scrollWheel(with: event)
    }

    override func magnify(with event: NSEvent) {
        zoomScroll.magnify(with: event)
    }

    var zoom: CGFloat { zoomScroll.zoom }
    var onZoomChanged: ((CGFloat) -> Void)? {
        get { zoomScroll.onZoomChanged }
        set { zoomScroll.onZoomChanged = newValue }
    }
    func zoomIn() { zoomScroll.zoomIn() }
    func zoomOut() { zoomScroll.zoomOut() }
    func setZoom(_ z: CGFloat) { zoomScroll.setZoom(z) }
    func fitToWindow() { zoomScroll.fitToWindow() }
    func actualSize() { zoomScroll.actualSize() }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49: togglePlay()                                   // space
        case 53: onClose()                                      // esc
        default: super.keyDown(with: event)                    // ←/→ handled by the window (strip nav)
        }
    }

    // MARK: - Auto-hide

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        revealControls()
    }

    /// Show the controls; when `autoHide` (default) and playing, fade them back
    /// out after a short idle delay.
    private func revealControls(autoHide: Bool = true) {
        hideTimer?.invalidate()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            controlBar.animator().alphaValue = 1
        }
        if autoHide { scheduleAutoHide() }
    }

    private func scheduleAutoHide() {
        hideTimer?.invalidate()
        guard player.rate != 0 else { return }   // keep visible while paused
        hideTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
            guard let self, self.player.rate != 0 else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.35
                self.controlBar.animator().alphaValue = 0
            }
        }
    }

    // MARK: - Teardown

    /// Remove observers and the timer. Call before discarding the view.
    func teardown() {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        hideTimer?.invalidate()
        hideTimer = nil
        playerView.player = nil
    }

    deinit { teardown() }
}

/// Custom scrubber: a thin rounded track showing buffered (light) and played
/// (accent) progress with a draggable knob. Reports drag position as a
/// `0...1` fraction so the owner maps it to a seek time.
/// A borderless button that fires its action once on press, then repeats while
/// held (after a short initial delay) — used for frame-step so holding scrubs
/// frame-by-frame instead of stepping once.
final class HoldRepeatButton: NSButton {
    var initialDelay: TimeInterval = 0.32
    var repeatInterval: TimeInterval = 0.07
    private var delayTimer: Timer?
    private var repeatTimer: Timer?

    override func mouseDown(with event: NSEvent) {
        // Don't call super (its tracking loop would block + send one action);
        // drive press visuals + repeats manually. mouseUp is still delivered.
        highlight(true)
        fire()
        delayTimer = Timer.scheduledTimer(withTimeInterval: initialDelay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.repeatTimer = Timer.scheduledTimer(withTimeInterval: self.repeatInterval, repeats: true) {
                [weak self] _ in self?.fire()
            }
        }
    }

    override func mouseUp(with event: NSEvent) { stop() }

    private func fire() { if let action { sendAction(action, to: target) } }

    private func stop() {
        delayTimer?.invalidate(); delayTimer = nil
        repeatTimer?.invalidate(); repeatTimer = nil
        highlight(false)
    }

    deinit { delayTimer?.invalidate(); repeatTimer?.invalidate() }
}

final class VideoScrubber: NSView {
    var played: Double = 0 { didSet { needsDisplay = true } }
    var buffered: Double = 0 { didSet { needsDisplay = true } }
    var onScrub: ((Double) -> Void)?
    var onScrubEnd: ((Double) -> Void)?

    private let knobRadius: CGFloat = 6
    override var isFlipped: Bool { false }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 16) }

    override func draw(_ dirtyRect: NSRect) {
        let trackHeight: CGFloat = 4
        let inset = knobRadius
        let trackWidth = bounds.width - inset * 2
        guard trackWidth > 0 else { return }
        let y = bounds.midY - trackHeight / 2

        func bar(_ fraction: Double, _ color: NSColor) {
            let w = trackWidth * CGFloat(min(1, max(0, fraction)))
            let rect = NSRect(x: inset, y: y, width: max(w, 0), height: trackHeight)
            NSBezierPath(roundedRect: rect, xRadius: trackHeight / 2, yRadius: trackHeight / 2).fill()
            _ = color
        }
        NSColor.white.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: NSRect(x: inset, y: y, width: trackWidth, height: trackHeight),
                     xRadius: trackHeight / 2, yRadius: trackHeight / 2).fill()
        NSColor.white.withAlphaComponent(0.40).setFill(); bar(buffered, .white)
        NSColor.controlAccentColor.setFill(); bar(played, .controlAccentColor)

        let knobX = inset + trackWidth * CGFloat(min(1, max(0, played)))
        let knobRect = NSRect(x: knobX - knobRadius, y: bounds.midY - knobRadius,
                              width: knobRadius * 2, height: knobRadius * 2)
        NSColor.white.setFill()
        NSBezierPath(ovalIn: knobRect).fill()
    }

    private func fraction(at point: NSPoint) -> Double {
        let inset = knobRadius
        let trackWidth = bounds.width - inset * 2
        guard trackWidth > 0 else { return 0 }
        return min(1, max(0, Double((point.x - inset) / trackWidth)))
    }

    override func mouseDown(with event: NSEvent) {
        let f = fraction(at: convert(event.locationInWindow, from: nil))
        played = f
        onScrub?(f)
    }

    override func mouseDragged(with event: NSEvent) {
        let f = fraction(at: convert(event.locationInWindow, from: nil))
        played = f
        onScrub?(f)
    }

    override func mouseUp(with event: NSEvent) {
        let f = fraction(at: convert(event.locationInWindow, from: nil))
        played = f
        onScrubEnd?(f)
    }
}
