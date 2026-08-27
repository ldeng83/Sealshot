import AppKit
import KeyboardShortcuts
import os.log

private let scrollLog = OSLog(subsystem: "com.seal-shot.sealshot", category: "scroll-capture")

/// Runs the recording phase of a scrolling capture: after the user has picked
/// the viewport region, a click-through panel outlines it (scrolls pass
/// through to the app underneath) with a HUD and live captured height.
///
/// AUTO mode (default when Accessibility is granted, Direct build only):
/// the controller drives the scrolling itself — tagged synthetic steps,
/// settle wait, sample, stitch — finishing automatically at end of content.
/// The user's own scroll input is BLOCKED for the session (an active CGEvent
/// tap swallows untagged scroll events) so it can't perturb the capture;
/// ⏎ finishes early, Esc cancels.
///
/// MANUAL mode (preference set to manual, permission missing, sandboxed
/// build, or a window that won't auto-scroll): a ~5 fps sampler grabs the
/// region while the user scrolls — no event tap, scrolling is theirs.
/// Return finishes, Esc cancels — both via global Carbon hotkeys (the panel
/// is never key).
@MainActor
final class ScrollCaptureController {

    private enum Mode {
        case auto
        case manual
    }

    enum Result {
        case finished(CGImage)
        case cancelled
        /// Auto-scroll couldn't run because the Accessibility grant was pulled
        /// after the trigger-time preflight (which reads a cached, stale-true
        /// trust query). Detected live — the event tap failed to create, or an
        /// AX position write returned apiDisabled. The coordinator re-prompts.
        case accessibilityRevoked
    }

    /// Active-scrolling budget: accrues only on ticks that extend the stitch,
    /// so pausing to read or scrolling back to re-check costs nothing.
    /// Hitting it finishes with what was captured.
    static let maxDuration: TimeInterval = 120
    /// Wall-clock safety ceiling so an abandoned session can't run forever.
    static let absoluteCeiling: TimeInterval = 600
    private static let sampleInterval: TimeInterval = 0.2

    /// Resolves a per-session frame sampler for the region (SCK filter
    /// resolved once; each call only grabs pixels, keeping ticks at ~5 fps).
    private let makeSampler: (SelectedRegion) async throws -> @MainActor () async throws -> CGImage
    /// Resolves the per-session scroll injector for the region (browser → JS
    /// driver, else CGScrollInjector, nil when sandboxed). Resolved once per run.
    private let makeInjector: (SelectedRegion) async -> ScrollInjecting?
    private var activeInjector: ScrollInjecting?
    private var sampler: (@MainActor () async throws -> CGImage)?
    private var continuation: CheckedContinuation<Result, Never>?
    private var mode: Mode = .manual
    private var autoTask: Task<Void, Never>?
    /// Resolved per session so the ScrollMicroStep A/B flag applies without
    /// relaunching (see AutoScrollPolicy.current).
    private var policy = AutoScrollPolicy.current()
    /// Active event tap that swallows the user's scroll input during auto
    /// mode (synthetic tagged events pass through). nil in manual mode.
    private var scrollBlockTap: CFMachPort?
    private var scrollBlockSource: CFRunLoopSource?
    private var panel: NSPanel?
    private var hud: ScrollCaptureSessionView?
    private var timer: Timer?
    private var stitcher: ScrollStitcher?
    private var region: SelectedRegion?
    private var activeSeconds: TimeInterval = 0
    private var absoluteDeadline: Date?
    private var sampling = false
    /// Manual-mode sample interval, scaled to region height (shorter regions
    /// have less overlap headroom, so they sample faster). Set per session in
    /// startManualLoop.
    private var manualSampleInterval: TimeInterval = ScrollCaptureController.sampleInterval
    /// Consecutive manual ticks the new frame shared no overlap with the last
    /// stitched one — the user out-ran the sampler. Guides them to scroll back;
    /// past `manualReseedThreshold` (a ~1.2 s grace window) it force-continues.
    private var manualNoOverlapStreak = 0
    private var manualReseedThreshold = 6

    var isRunning: Bool { continuation != nil }

    /// True when the active injector knows (from page JS) that the viewport has
    /// reached the end of content — a definitive finish signal that bypasses the
    /// image-based end-of-content heuristics.
    nonisolated static func injectorReportsBottom(_ injector: ScrollInjecting?) -> Bool {
        (injector as? ScrollPositionReporting)?.isAtBottom ?? false
    }

    init(
        makeSampler: @escaping (SelectedRegion) async throws -> @MainActor () async throws -> CGImage,
        makeInjector: @escaping (SelectedRegion) async -> ScrollInjecting?
    ) {
        self.makeSampler = makeSampler
        self.makeInjector = makeInjector
    }

    func run(region: SelectedRegion) async -> Result {
        guard continuation == nil else { return .cancelled }
        self.activeInjector = await makeInjector(region)
        return await withCheckedContinuation { cont in
            self.continuation = cont
            self.start(region: region)
        }
    }

    /// Routed from the coordinator's global `.pickerCancel` (Esc) handler.
    func cancelFromGlobalEsc() {
        guard continuation != nil else { return }
        ScrollDiag.session("session end: CANCELLED (Esc)")
        complete(.cancelled)
    }

    /// Routed from the coordinator's global `.scrollCaptureFinish` (Return)
    /// handler.
    func finishFromGlobalReturn() {
        guard continuation != nil else { return }
        ScrollDiag.note("user pressed Return → finish")
        finish()
    }

    // MARK: - Session

    private func start(region: SelectedRegion) {
        self.region = region
        self.stitcher = ScrollStitcher()
        self.activeSeconds = 0
        self.absoluteDeadline = Date().addingTimeInterval(Self.absoluteCeiling)
        self.policy = AutoScrollPolicy.current()
        self.dumpSeq = 0
        self.dumpDir = nil
        self.failureTracesLogged = 0

        let r = region.globalRect
        ScrollDiag.session("scroll session start — region \(Int(r.width))×\(Int(r.height)) "
            + "at (\(Int(r.minX)),\(Int(r.minY))), injector=\(activeInjector.map { String(describing: type(of: $0)) } ?? "none"), "
            + "policy=\(policy.stepFraction <= 0.2 ? "micro-step" : "classic") (step \(Int(policy.stepPoints(forRegionHeight: r.height)))pt), "
            + "autoScrollPref=\(AutoScrollPreference.isEnabled()), accessibility=\(AccessibilityPermission.canAutoScroll)")

        let screen = region.screen
        let view = ScrollCaptureSessionView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.selectionRect = region.globalRect.offsetBy(
            dx: -screen.frame.minX, dy: -screen.frame.minY)

        let panel = NSPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.ignoresMouseEvents = true                      // scrolls pass through
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = view
        panel.orderFrontRegardless()
        self.panel = panel
        self.hud = view

        // Both keys are global Carbon hotkeys (consumed system-wide) for the
        // session only — the user is scrolling another app, so the panel can't
        // receive key events.
        KeyboardShortcuts.setShortcut(.init(.escape, modifiers: []), for: .pickerCancel)
        KeyboardShortcuts.setShortcut(.init(.return, modifiers: []), for: .scrollCaptureFinish)
        // Keypad Enter is a different key code — bind it too, or the numeric
        // keypad can't finish the session.
        KeyboardShortcuts.setShortcut(.init(.keypadEnter, modifiers: []), for: .scrollCaptureFinishKeypad)

        // The permission flow runs at trigger time (coordinator), before the
        // region pick — never here, where System Settings would land on top
        // of a live capture session.
        if let injector = activeInjector, AutoScrollPreference.isEnabled(), AccessibilityPermission.canAutoScroll {
            startAutoLoop(injector: injector)
        } else if activeInjector != nil, AutoScrollPreference.isEnabled(),
                  !AccessibilityPermission.isSandboxed {
            // activeInjector is nil when sandboxed, so the isSandboxed guard is
            // redundant here; kept for clarity. Landing here means trust vanished
            // between trigger and session, so explain why the session is manual.
            startManualLoop(instruction:
                "Scroll · ⏎ finish · esc cancel · for auto-scroll, enable Sealshot in System Settings → Accessibility")
        } else {
            startManualLoop(instruction: "Scroll · ⏎ finish · esc cancel")
        }
    }

    // MARK: - Manual mode (5 fps sampler, user scrolls)

    private func startManualLoop(instruction: String) {
        ScrollDiag.note("mode: MANUAL (\(instruction.prefix(60)))")
        mode = .manual
        hud?.instruction = instruction
        manualNoOverlapStreak = 0
        // Sample fast enough that a brisk scroll still overlaps by the
        // stitcher's minimum: the tolerated jump per tick is ~(frameHeight −
        // minOverlap), so a short region must sample faster than a tall one.
        // Aim to keep up with ~4000 px/s of frame motion, clamped to a sane
        // 6–~17 fps; the sampling gate already drops ticks if a grab overruns.
        if let region {
            let frameHeightPx = region.globalRect.height * region.screen.backingScaleFactor
            manualSampleInterval = min(Self.sampleInterval, max(0.06, frameHeightPx / 4000))
        } else {
            manualSampleInterval = Self.sampleInterval
        }
        // Grace window before force-continuing past a lost overlap (~1.2 s).
        manualReseedThreshold = max(3, Int((1.2 / manualSampleInterval).rounded(.up)))
        let t = Timer(timeInterval: manualSampleInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: - Auto mode (synthetic steps drive the content)

    private func startAutoLoop(injector: ScrollInjecting) {
        ScrollDiag.note("mode: AUTO")
        mode = .auto
        hud?.instruction = "Auto-scrolling · ⏎ finish · esc cancel"
        // Creating the scroll-block tap is a LIVE Accessibility check (an active
        // .cghidEventTap needs the grant), unlike the cached AXIsProcessTrusted
        // query the trigger-time preflight relied on. nil here means the grant
        // was pulled between trigger and session — surface it as a lost
        // permission instead of silently limping into a no-op auto session.
        guard installScrollBlockTap() else {
            ScrollDiag.session("session end: ACCESSIBILITY REVOKED (block-tap create failed)")
            AccessibilityPermission.autoScrollRevoked = true
            complete(.accessibilityRevoked)
            return
        }
        // Tap created ⇒ trust is genuinely present right now; clear any stale
        // revoked latch from an earlier failed attempt.
        AccessibilityPermission.autoScrollRevoked = false

        autoTask = Task { @MainActor [weak self] in
            guard let self, let region = self.region, let stitcher = self.stitcher else { return }
            do {
                if self.sampler == nil { self.sampler = try await self.makeSampler(region) }
            } catch {
                os_log("auto: sampler failed: %{public}@", log: scrollLog, type: .default,
                       String(describing: error))
                ScrollDiag.note("auto: SAMPLER FAILED: \(String(describing: error).prefix(200))")
                self.fallBackToManual()
                return
            }
            guard let sampler = self.sampler else { return }

            let step = Int(self.policy.stepPoints(forRegionHeight: region.globalRect.height))

            // Seed frame before any scrolling — not a step verdict, so the
            // policy's fruitless-steps fallback stays meaningful.
            if let seed = try? await sampler() {
                let seedTag = self.dumpFrameIfEnabled(seed)
                let seedResult = stitcher.append(seed)
                self.logAppendTrace(stitcher, result: seedResult, frameTag: seedTag)
                self.hud?.capturedHeightPx = stitcher.stitchedHeight
                // Feedforward: we COMMAND every scroll — the stitcher works in
                // frame pixels (the seed gives the points→pixels scale).
                let scale = Double(seed.height) / Double(region.globalRect.height)
                let expected = Int((Double(step) * scale).rounded())
                stitcher.expectedShift = expected
                ScrollDiag.note("auto: commanded advance \(expected)px/step "
                    + (self.policy.blindStitching ? "(BLIND stitch)" : "(constrained search)"))
            }

            // Wheel-target ladder. PRIMARY park: the region centre — the
            // spot the user expects the frozen cursor to sit (and where
            // Shottr visibly parks). Fallbacks, tried only if the page
            // stops responding while frames keep failing to stitch
            // (noOverlap streak): first the scrollbar gutter at the
            // region's right edge — wheel events there reach the ROOT
            // scroller, so inner carousels and wheel-swallowing widgets
            // (which live in the content area) never see them — then
            // content spots above/below centre. The pointer stays frozen
            // between hops (locked for the session; warping works while
            // disassociated). Field note: the earlier "re-parking never
            // rescues" evidence came from re-warping the SAME centre point
            // every step — RELOCATING is what escapes a swallowing element.
            let r = region.globalRect
            let parkSpots = [
                CGPoint(x: r.midX, y: r.midY),
                CGPoint(x: r.maxX - 8, y: r.midY),
                CGPoint(x: r.midX, y: r.midY + r.height * 0.3),
                CGPoint(x: r.midX, y: r.midY - r.height * 0.3),
            ]
            var parkIndex = 0
            injector.parkPointer(atGlobal: parkSpots[parkIndex])
            self.lockPointer()
            var state = AutoScrollPolicy.State()
            var prevStepFrame: CGImage?
            // Injections since the last successful stitch — the stitcher's
            // expected window tracks the ACCUMULATED commanded distance.
            var injectionsSinceMatch = 0
            // Consecutive steps whose region never went still within the
            // budget (large-area motion the whole time) — such regions can't
            // be scroll-stitched; give up after a handful.
            var skippedUnsettled = 0
            // Consecutive steps the page ignored (settled frame, no
            // movement) — the wheel is being eaten under the current park
            // spot; hop to the next one. At a genuine page bottom the hops
            // are harmless: the duplicate/stable-frame paths keep their
            // streaks and still finish.
            var wheelIgnoredStreak = 0

            while !Task.isCancelled, self.continuation != nil {
                if let deadline = self.absoluteDeadline, Date() >= deadline {
                    self.finish()
                    return
                }
                // STRICT TURN-TAKING (Shottr's measured cycle: glide…glide…
                // one motionless frame…repeat). Exactly ONE step in flight:
                // inject, then wait until the region is GENUINELY STILL
                // before sampling — never sample mid-glide. Timer-driven
                // injection was a perpetual-motion trap on smooth-scrolling
                // pages: injections outpaced the glide animations, the page
                // never went still, every sample was a fractional-offset
                // frame nothing could match, and the capture froze while the
                // page scrolled on.
                await injector.scrollContentDown(points: step)
                // Backstop: the grant can be pulled AFTER the tap was created,
                // mid-scroll. The AX driver reports its position write coming
                // back apiDisabled — surface the same lost-permission prompt.
                if (injector as? AXScrollDriver)?.writeDeauthorized == true {
                    ScrollDiag.session("session end: ACCESSIBILITY REVOKED (AX write apiDisabled)")
                    AccessibilityPermission.autoScrollRevoked = true
                    self.complete(.accessibilityRevoked)
                    return
                }
                injectionsSinceMatch += 1
                try? await Task.sleep(nanoseconds: UInt64(
                    self.policy.settleDelay(for: state) * 1_000_000_000))
                guard !Task.isCancelled, self.continuation != nil else { return }
                guard let frame = await self.stillFrame(sampler: sampler, budget: 3.0) else {
                    skippedUnsettled += 1
                    ScrollDiag.note("auto: region never went still — sample skipped (\(skippedUnsettled))")
                    if skippedUnsettled >= 6 {
                        ScrollDiag.note("auto: region animates continuously — finishing with what we have")
                        self.finish()
                        return
                    }
                    continue
                }
                skippedUnsettled = 0
                guard let stitcher = self.stitcher else { return }
                let frameTag = self.dumpFrameIfEnabled(frame)
                // The page has stopped when this grab is identical to the last
                // step's — a fast, definitive end-of-content signal.
                let framesStable = prevStepFrame.map { FrameSettle.isStable($0, frame) } ?? false
                prevStepFrame = frame
                stitcher.commandedStepsAhead = max(1, injectionsSinceMatch)
                let result: ScrollStitcher.AppendResult
                if self.policy.blindStitching, let expected = stitcher.expectedShift {
                    // Pure fixed-step mode: trust the commanded advance.
                    result = stitcher.appendCommanded(frame, advance: expected)
                } else {
                    result = stitcher.append(frame)
                }
                os_log("auto: step → %{public}@ moved %{public}@ (stitched %d px)",
                       log: scrollLog, type: .default,
                       String(describing: result),
                       stitcher.lastAppendMoved ? "y" : "n",
                       stitcher.stitchedHeight)
                self.logAppendTrace(stitcher, result: result, frameTag: frameTag)
                self.hud?.capturedHeightPx = stitcher.stitchedHeight
                // The page itself reports it has reached the bottom — finish now
                // rather than waiting for the stall/stable-frame heuristics. This
                // is the JS-scroll path's end-of-content fix (no re-anchor linger).
                if Self.injectorReportsBottom(injector) {
                    let tail = stitcher.appendFinalTail(frame)
                    self.logAppendTrace(stitcher, result: tail, frameTag: frameTag)
                    self.hud?.capturedHeightPx = stitcher.stitchedHeight
                    ScrollDiag.note("auto: page reports bottom → final tail \(String(describing: tail)) "
                        + "shift=\(stitcher.lastAppendShift) → finish (stitched \(stitcher.stitchedHeight)px)")
                    self.finish()
                    return
                }
                if case .noOverlap = result {} else { injectionsSinceMatch = 0 }
                let decision = self.policy.decide(after: result,
                                                  moved: stitcher.lastAppendMoved,
                                                  framesStable: framesStable,
                                                  state: &state)
                // Collapse repeats (micro-step mode emits many near-identical
                // healthy lines): growth deltas and stitched height change
                // every step, so they stay OUT of the line — steady growth
                // folds into one line; the height shows at decision changes
                // and session end.
                let growth: String
                if case .appendedRows(let d) = result, d > 0 { growth = "appendedRows(+)" }
                else { growth = String(describing: result) }
                // Shift note: bucketed so healthy on-command steps still
                // collapse, while any off-command alignment (the duplicate-
                // strip suspect) surfaces with its exact value.
                var shiftNote = ""
                if case .appendedRows = result, let e = stitcher.expectedShift {
                    let d = stitcher.lastAppendShift - e
                    shiftNote = abs(d) <= 8 ? ", shift≈cmd" : ", shift=\(stitcher.lastAppendShift) (Δ\(d))"
                }
                self.noteCollapsed("auto: step +\(step)pt → \(growth), "
                    + "moved=\(stitcher.lastAppendMoved ? "y" : "n"), stable=\(framesStable ? "y" : "n")\(shiftNote) "
                    + "→ \(String(describing: decision))")
                switch decision {
                case .continueScrolling:
                    // Hop only on UNMATCHED frames (noOverlap streak — a
                    // wheel-eater under the pointer or content the stitcher
                    // can't hold onto). Duplicates are the page bottom and
                    // in-place appends are lazy loads — both stop moving
                    // legitimately; hopping there is just a cursor dance.
                    if case .noOverlap = result {
                        wheelIgnoredStreak += 1
                        if wheelIgnoredStreak >= 3, parkIndex + 1 < parkSpots.count {
                            parkIndex += 1
                            injector.parkPointer(atGlobal: parkSpots[parkIndex])
                            ScrollDiag.note("auto: page ignoring wheel — re-park "
                                + "\(parkIndex + 1)/\(parkSpots.count)")
                            wheelIgnoredStreak = 0
                            // Fresh budget for the new spot — but the
                            // duplicate streak survives, so a real bottom
                            // still finishes on schedule.
                            state.fruitlessSteps = 0
                            state.stalledSteps = 0
                        }
                    } else {
                        wheelIgnoredStreak = 0
                    }
                    continue
                case .reseedAnchor:
                    // The seed anchored a page top whose header/hero transforms
                    // on the first scroll — it shares no overlap with the body,
                    // so every step only drifts further from it. Re-anchor on
                    // this frame: the body aligns frame-to-frame and stitches
                    // from here (the pre-scroll top is dropped).
                    ScrollDiag.note("auto: RESEED anchor (transformed header/hero — pre-scroll top dropped)")
                    let fresh = ScrollStitcher()
                    fresh.expectedShift = stitcher.expectedShift
                    _ = fresh.append(frame)
                    self.stitcher = fresh
                    self.hud?.capturedHeightPx = fresh.stitchedHeight
                    continue
                case .finish:
                    // End-of-content: the page has stopped. The final frame may
                    // have failed the normal append (dynamic content re-rendered
                    // its overlap, or a repetitive false peak out-voted the true
                    // shift), so its tail would be lost. Recover it permissively.
                    let tail = stitcher.appendFinalTail(frame)
                    self.logAppendTrace(stitcher, result: tail, frameTag: frameTag)
                    self.hud?.capturedHeightPx = stitcher.stitchedHeight
                    ScrollDiag.note("auto: policy finish — final tail \(String(describing: tail)) "
                        + "shift=\(stitcher.lastAppendShift) (end of content, stitched \(stitcher.stitchedHeight)px)")
                    self.finish()
                    return
                case .fallbackToManual:
                    ScrollDiag.note("auto: policy FELL BACK to manual (fruitless steps — window not moving)")
                    self.fallBackToManual()
                    return
                }
            }
        }
    }

    /// Wait for the region to be GENUINELY STILL: two consecutive grabs
    /// stable within the policy threshold. Returns nil when the budget
    /// expires without stillness — the caller must NOT stitch such a frame
    /// (a mid-motion anchor is unmatchable forever). This is the whole
    /// turn-taking contract: no next step until stillness was observed.
    private func stillFrame(
        sampler: @MainActor () async throws -> CGImage,
        budget: TimeInterval
    ) async -> CGImage? {
        guard var previous = try? await sampler() else { return nil }
        let deadline = Date().addingTimeInterval(budget)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: UInt64(max(policy.settlePollInterval, 0.06) * 1_000_000_000))
            guard continuation != nil, !Task.isCancelled else { return nil }
            guard let next = try? await sampler() else { return nil }
            if FrameSettle.isStable(previous, next, threshold: policy.settleStableThreshold) {
                return next
            }
            previous = next
        }
        return nil
    }

    /// Auto mode couldn't drive this window (non-native scroller) — keep the
    /// session alive and hand scrolling (and the pointer) back to the user.
    private func fallBackToManual() {
        autoTask?.cancel(); autoTask = nil
        activeInjector?.sessionEnded()   // the user scrolls now — end our gesture
        unlockPointer()
        removeScrollBlockTap()
        // The user scrolls freely now — the commanded-step constraint no
        // longer holds; restore the unconstrained search.
        stitcher?.expectedShift = nil
        startManualLoop(instruction: "Can't auto-scroll here — scroll manually · ⏎ finish")
    }

    // MARK: - Pointer lock (auto mode)

    /// Freeze the cursor where it's parked: mouse deltas stop moving it, so
    /// the user can't drag it out of the capture region mid-session. Global
    /// window-server state — every exit path MUST unlock (the window server
    /// also restores it if the process dies).
    private func lockPointer() {
        CGAssociateMouseAndMouseCursorPosition(0)
    }

    private func unlockPointer() {
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    // MARK: - Scroll blocking (auto mode)

    /// Swallow the user's scroll AND click input while auto mode drives the
    /// page: an ACTIVE event tap (allowed — auto mode requires the
    /// Accessibility grant) drops untagged scroll-wheel events and all
    /// mouse-button events, so manual input can't perturb the capture or
    /// click whatever sits under the pinned cursor. Our synthetic steps
    /// carry `CGScrollInjector.syntheticTag` and pass through. ⏎/Esc are
    /// key events — unaffected.
    /// Returns false when the tap can't be created — the definitive live signal
    /// that the Accessibility grant is gone (see `startAutoLoop`).
    @discardableResult
    private func installScrollBlockTap() -> Bool {
        guard scrollBlockTap == nil else { return true }
        let blockedTypes: [CGEventType] = [
            .scrollWheel,
            .leftMouseDown, .leftMouseUp,
            .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp,
        ]
        let mask = blockedTypes.reduce(CGEventMask(0)) { $0 | (1 << CGEventMask($1.rawValue)) }
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            // A tap that stalls gets disabled by the system — re-enable.
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let refcon {
                    let controller = Unmanaged<ScrollCaptureController>
                        .fromOpaque(refcon).takeUnretainedValue()
                    MainActor.assumeIsolated { controller.reenableScrollBlockTap() }
                }
                return Unmanaged.passUnretained(event)
            }
            if CGScrollInjector.shouldPassThroughBlockTap(
                eventType: type,
                userData: event.getIntegerValueField(.eventSourceUserData),
                sourcePID: event.getIntegerValueField(.eventSourceUnixProcessID),
                ourPID: Int64(ProcessInfo.processInfo.processIdentifier)) {
                return Unmanaged.passUnretained(event)
            }
            return nil   // user scroll/click — swallowed
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            // Tap creation fails when the Accessibility grant is gone — the
            // caller turns this into a lost-permission prompt rather than a
            // silent no-op auto session.
            os_log("auto: scroll-block tap creation failed", log: scrollLog, type: .error)
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        scrollBlockTap = tap
        scrollBlockSource = source
        return true
    }

    private func reenableScrollBlockTap() {
        if let scrollBlockTap { CGEvent.tapEnable(tap: scrollBlockTap, enable: true) }
    }

    private func removeScrollBlockTap() {
        if let scrollBlockTap { CGEvent.tapEnable(tap: scrollBlockTap, enable: false) }
        if let scrollBlockSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), scrollBlockSource, .commonModes)
        }
        scrollBlockTap = nil
        scrollBlockSource = nil
    }

    /// Manual mode samples at ~5 fps and micro-step auto runs many steps per
    /// second — collapse identical consecutive outcomes so the trace stays
    /// readable (one line per outcome change, plus a repeat count).
    private var lastTickLine = ""
    private var tickRepeats = 0
    private func noteCollapsed(_ line: String) {
        if line == lastTickLine { tickRepeats += 1; return }
        if tickRepeats > 1 { ScrollDiag.note("(previous ×\(tickRepeats))") }
        lastTickLine = line
        tickRepeats = 1
        ScrollDiag.note(line)
    }
    private func noteTick(_ line: String) { noteCollapsed("tick: \(line)") }

    private func tick() {
        if let absoluteDeadline, Date() >= absoluteDeadline {
            ScrollDiag.note("manual: absolute deadline hit → finish")
            finish(); return
        }
        guard !sampling, let region, let stitcher else { return }
        sampling = true
        Task { @MainActor in
            defer { sampling = false }
            let frame: CGImage
            do {
                if sampler == nil { sampler = try await makeSampler(region) }
                guard let sampler else { return }
                frame = try await sampler()
            } catch {
                os_log("tick: captureFrame failed: %{public}@", log: scrollLog, type: .default,
                       String(describing: error))
                self.noteTick("SAMPLER FAILED: \(String(describing: error).prefix(160))")
                return
            }
            guard self.continuation != nil else { return }
            let frameTag = self.dumpFrameIfEnabled(frame)
            let result = stitcher.append(frame)
            os_log("tick: frame %dx%d → %{public}@ (stitched %d px)",
                   log: scrollLog, type: .default,
                   frame.width, frame.height, String(describing: result), stitcher.stitchedHeight)
            self.noteTick("\(String(describing: result)) (stitched \(stitcher.stitchedHeight)px)")
            self.logAppendTrace(stitcher, result: result, frameTag: frameTag)
            switch result {
            case .appendedRows(let delta):
                // Any successful stitch (incl. an up-shift from scrolling back)
                // means overlap is re-established — clear the lost-overlap run.
                manualNoOverlapStreak = 0
                hud?.capturedHeightPx = stitcher.stitchedHeight
                // Only ticks that EXTEND the stitch burn budget — interior
                // re-scrolls (delta 0), duplicates (parked), and no-overlaps
                // (re-reading) are free.
                if delta > 0 {
                    activeSeconds += manualSampleInterval
                    if activeSeconds >= Self.maxDuration { finish() }
                }
            case .noOverlap:
                manualNoOverlapStreak += 1
                if manualNoOverlapStreak >= manualReseedThreshold {
                    // Grace window elapsed without the user scrolling back —
                    // force-continue from here so the session isn't wedged. The
                    // skipped content is a seam in the result (see reseedForward).
                    ScrollDiag.note("manual: lost overlap for \(manualNoOverlapStreak) ticks "
                        + "→ reseed forward (gap; content skipped)")
                    if case .appendedRows = stitcher.reseedForward(frame) {
                        manualNoOverlapStreak = 0
                        hud?.capturedHeightPx = stitcher.stitchedHeight
                        hud?.flashWarning("Resumed — skipped content left out")
                    }
                } else {
                    hud?.flashWarning("Scrolled too fast — scroll back up to resume")
                }
            case .capReached:
                finish()
            case .duplicate:
                manualNoOverlapStreak = 0
                break
            }
        }
    }

    /// Debug aid: `defaults write com.seal-shot.sealshot.direct ScrollDebugDump -bool true`
    /// writes every sampled frame — and the final stitched image — to a fresh
    /// per-session folder under /tmp/sealshot-frames for offline alignment
    /// analysis, and logs the stitcher's full decision trace for every append
    /// (not just failures). No-op unless the flag is set; read live, so no
    /// relaunch is needed. Returns the dumped frame's filename so the log can
    /// cross-reference it.
    private var dumpSeq = 0
    private var dumpDir: URL?
    private var debugDumpEnabled: Bool { UserDefaults.standard.bool(forKey: "ScrollDebugDump") }
    private func dumpFrameIfEnabled(_ frame: CGImage) -> String? {
        guard debugDumpEnabled else { return nil }
        dumpSeq += 1
        let name = String(format: "frame-%03d.png", dumpSeq)
        if let png = try? CaptureOutputWriter.encodePNG(frame) {
            try? png.write(to: ensureDumpDir().appendingPathComponent(name))
        }
        return name
    }

    private func ensureDumpDir() -> URL {
        if let dumpDir { return dumpDir }
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let dir = URL(fileURLWithPath: "/tmp/sealshot-frames", isDirectory: true)
            .appendingPathComponent(stamp.string(from: Date()), isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        ScrollDiag.note("frame dump: \(dir.path)")
        dumpDir = dir
        return dir
    }

    /// Write the stitcher's per-append decision trace to the scroll-capture
    /// log. Always logged for failed appends — a field failure carries its
    /// own forensics — but capped per session so manual-mode fast-scroll
    /// bursts (where no-overlap is routine) can't churn the log away.
    /// ScrollDebugDump lifts the cap and logs the trace for every append.
    private static let maxFailureTraces = 12
    private var failureTracesLogged = 0
    private func logAppendTrace(_ stitcher: ScrollStitcher,
                                result: ScrollStitcher.AppendResult,
                                frameTag: String?) {
        if !debugDumpEnabled {
            guard case .noOverlap = result else { return }
            failureTracesLogged += 1
            if failureTracesLogged > Self.maxFailureTraces {
                if failureTracesLogged == Self.maxFailureTraces + 1 {
                    ScrollDiag.note("stitch: further failure traces suppressed "
                        + "(ScrollDebugDump logs every append)")
                }
                return
            }
        }
        let tag = frameTag.map { "[\($0)] " } ?? ""
        for line in stitcher.appendTrace { ScrollDiag.note("stitch: \(tag)\(line)") }
    }

    private func finish() {
        if tickRepeats > 1 { ScrollDiag.note("tick: (previous ×\(tickRepeats))"); tickRepeats = 0 }
        guard let stitched = stitcher?.finish() else {
            ScrollDiag.session("session end: CANCELLED (no stitch)")
            complete(.cancelled); return
        }
        if debugDumpEnabled, let png = try? CaptureOutputWriter.encodePNG(stitched) {
            try? png.write(to: ensureDumpDir().appendingPathComponent("stitched.png"))
        }
        ScrollDiag.session("session end: FINISHED \(stitched.width)×\(stitched.height)px")
        complete(.finished(stitched))
    }

    private func complete(_ result: Result) {
        guard let cont = continuation else { return }
        continuation = nil
        tearDown()
        cont.resume(returning: result)
    }

    private func tearDown() {
        timer?.invalidate(); timer = nil
        autoTask?.cancel(); autoTask = nil
        activeInjector?.sessionEnded()   // close the latched gesture stream
        unlockPointer()
        removeScrollBlockTap()
        KeyboardShortcuts.setShortcut(nil, for: .pickerCancel)
        KeyboardShortcuts.setShortcut(nil, for: .scrollCaptureFinish)
        KeyboardShortcuts.setShortcut(nil, for: .scrollCaptureFinishKeypad)
        panel?.orderOut(nil); panel = nil; hud = nil
        stitcher = nil; region = nil; sampler = nil
        absoluteDeadline = nil; activeSeconds = 0
    }
}

/// Chrome for the recording phase: a border around the captured viewport and
/// a HUD pill with instructions, the live stitched height, and a transient
/// "scroll slower" warning.
final class ScrollCaptureSessionView: NSView {

    var selectionRect: CGRect = .zero { didSet { needsDisplay = true } }
    var capturedHeightPx: Int = 0 { didSet { needsDisplay = true } }
    var instruction = "Scroll · ⏎ finish · esc cancel" { didSet { needsDisplay = true } }
    private var warning: String?
    private var warningExpiry = Date.distantPast

    override var isFlipped: Bool { false }

    func flashWarning(_ text: String) {
        warning = text
        warningExpiry = Date().addingTimeInterval(1.2)
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [weak self] in
            self?.needsDisplay = true   // repaint after expiry to clear it
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !selectionRect.isEmpty else { return }

        // Viewport border (kept outside the captured rect so it's never in
        // the samples).
        let border = selectionRect.insetBy(dx: -2, dy: -2)
        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath(rect: border)
        path.lineWidth = 2
        path.stroke()

        // HUD pill below the selection (above when there's no room).
        var text = instruction
        if capturedHeightPx > 0 { text += "   \(capturedHeightPx) px" }
        if let warning, Date() < warningExpiry { text += "   — \(warning)" }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let label = text as NSString
        let size = label.size(withAttributes: attrs)
        let padX: CGFloat = 10, padY: CGFloat = 6, gap: CGFloat = 10
        var oy = selectionRect.minY - gap - size.height - padY * 2
        if oy < bounds.minY + 4 { oy = selectionRect.maxY + gap }
        let box = CGRect(x: selectionRect.midX - size.width / 2 - padX, y: oy,
                         width: size.width + padX * 2, height: size.height + padY * 2)
        NSColor.black.withAlphaComponent(0.78).setFill()
        NSBezierPath(roundedRect: box, xRadius: 7, yRadius: 7).fill()
        label.draw(at: CGPoint(x: box.minX + padX, y: box.minY + padY), withAttributes: attrs)
    }
}
