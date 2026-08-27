import AVFoundation
import ScreenCaptureKit
import CoreMedia
import CoreGraphics
import os.log

private let log = OSLog(subsystem: "com.seal-shot.sealshot", category: "recording")

/// Drives an SCStream (video + system audio) and an AVCaptureSession (mic)
/// into an AVAssetWriter for one recording. Pause/resume excludes paused time
/// via `RecordingClock`; system + mic are merged by `LiveAudioMixer`.
///
/// UNVERIFIED: the capture→file path requires on-device smoke testing
/// (Screen Recording + Microphone permissions, then play back the file).
/// Compilation is the only automated gate.
@MainActor
final class ScreenRecorder: NSObject {
    private var stream: SCStream?
    private var micSession: AVCaptureSession?
    private var writer: AssetRecordingWriter?
    private var mixer: LiveAudioMixer?
    private var clock: RecordingClock?
    private var started = false
    private let sampleQueue = DispatchQueue(label: "com.seal-shot.recording.samples")

    /// Surfaced to the coordinator for an alert; recording is already stopping.
    var onError: ((Error) -> Void)?

    var isPaused: Bool { clock?.isPaused ?? false }

    func start(_ session: RecordingSession) async throws {
        let (filter, size) = try await Self.filterAndSize(for: session.source)

        let config = SCStreamConfiguration()
        config.width = Int(size.width)
        config.height = Int(size.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(session.frameRate))
        config.showsCursor = session.showsCursor
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 6
        if case .region(_, let rect) = session.source { config.sourceRect = rect }
        if session.capturesSystemAudio {
            config.capturesAudio = true
            // 48 kHz is SCK's native audio rate (a 44.1 kHz request was ignored
            // and delivered as 48 kHz anyway); match it so nothing resamples.
            config.sampleRate = 48_000
            config.channelCount = 2
        }

        let writer = try AssetRecordingWriter(
            url: session.outputURL, format: session.format, size: size,
            hasAudio: session.hasAudio)
        self.writer = writer

        if session.hasAudio {
            let mixer = LiveAudioMixer.make(hasSystem: session.capturesSystemAudio,
                                            hasMic: session.capturesMicrophone,
                                            reduceNoise: session.reducesMicNoise)
            mixer.emit = { [weak self] sb in self?.appendMixedAudio(sb) }
            self.mixer = mixer
        }

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        if session.capturesSystemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        }
        self.stream = stream

        if session.capturesMicrophone { startMicrophone() }
        try await stream.startCapture()
    }

    func pause() { clock?.pause(at: CMClockGetTime(CMClockGetHostTimeClock())) }
    func resume() { clock?.resume(at: CMClockGetTime(CMClockGetHostTimeClock())) }

    func stop() async -> URL? {
        clock?.resume(at: CMClockGetTime(CMClockGetHostTimeClock())) // ensure finalizable if paused
        try? await stream?.stopCapture()
        micSession?.stopRunning()
        micSession = nil
        return await withCheckedContinuation { (cont: CheckedContinuation<URL?, Never>) in
            guard let writer else { cont.resume(returning: nil); return }
            writer.finish { result in
                switch result {
                case .success(let url): cont.resume(returning: url)
                case .failure(let e):
                    os_log("finish failed: %{public}@", log: log, type: .error, String(describing: e))
                    cont.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - Mic

    /// Capture the mic with a raw AVCaptureSession. Apple voice processing
    /// (AUVoiceProcessor) is NOT used here: its full-duplex IO unit conflicts
    /// with ScreenCaptureKit capturing system audio simultaneously (it never
    /// initializes, err -10867), so it always fell back to raw anyway. Cleanup
    /// instead happens downstream in `MicDSP` (high-pass + noise gate) on the
    /// raw stream, which is dependable and unit-testable.
    private func startMicrophone() {
        let session = AVCaptureSession()
        guard let device = AVCaptureDevice.default(for: .audio),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            os_log("microphone unavailable; continuing without it", log: log, type: .error)
            return
        }
        session.addInput(input)
        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: sampleQueue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.startRunning()
        micSession = session
    }

    // MARK: - Routing (main actor)

    private func appendMixedAudio(_ sb: CMSampleBuffer) {
        guard started, let writer,
              let out = clock?.outputTime(for: CMSampleBufferGetPresentationTimeStamp(sb)),
              let retimed = try? sb.retimed(to: out) else { return }
        writer.appendAudio(retimed)
    }

    fileprivate func routeVideo(_ sb: CMSampleBuffer, pts: CMTime) {
        guard let writer else { return }
        if !started {
            clock = RecordingClock(start: pts)
            try? writer.start(at: .zero)
            started = true
        }
        guard let out = clock?.outputTime(for: pts) else { return } // dropped while paused
        if let retimed = try? sb.retimed(to: out) { writer.appendVideo(retimed) }
    }

    fileprivate func routeSystemAudio(_ sb: CMSampleBuffer) {
        guard started else { return }
        mixer?.ingestSystem(sb)
    }

    fileprivate func routeMic(_ sb: CMSampleBuffer) {
        guard started else { return }
        mixer?.ingestMic(sb)
    }

    // MARK: - Source resolution

    private static func filterAndSize(for source: RecordingSession.Source) async throws -> (SCContentFilter, CGSize) {
        switch source {
        case .display(let d):
            // SCDisplay dimensions are in POINTS; capture at native backing
            // pixels so a Retina display records full-resolution, not halved.
            let size = pixelSize(points: CGSize(width: d.width, height: d.height),
                                 scale: pixelScale(for: d.displayID))
            return (try await displayFilterExcludingSelf(d), size)
        case .window(let w):
            return (SCContentFilter(desktopIndependentWindow: w), w.frame.size)
        case .region(let d, let rect):
            let size = pixelSize(points: rect.size, scale: pixelScale(for: d.displayID))
            return (try await displayFilterExcludingSelf(d), size)
        }
    }

    /// A display filter that excludes Sealshot's own windows, so the floating
    /// recording HUD (and any capture overlay) never appears in the recording.
    /// Shares the still-capture self-exclusion so the two never drift.
    private static func displayFilterExcludingSelf(_ display: SCDisplay) async throws -> SCContentFilter {
        let content = try await SCShareableContent.current
        return SelfExcludingContentFilter.display(display, in: content)
    }

    /// Native backing-pixel scale of a display (2 on Retina, 1 otherwise),
    /// derived from its current mode. Falls back to 1 if unavailable.
    private static func pixelScale(for displayID: CGDirectDisplayID) -> CGFloat {
        guard let mode = CGDisplayCopyDisplayMode(displayID), mode.width > 0 else { return 1 }
        return CGFloat(mode.pixelWidth) / CGFloat(mode.width)
    }

    /// Points × scale → integer pixel size for the capture config and writer.
    static func pixelSize(points: CGSize, scale: CGFloat) -> CGSize {
        CGSize(width: (points.width * scale).rounded(),
               height: (points.height * scale).rounded())
    }
}

extension ScreenRecorder: SCStreamOutput {
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer,
                            of type: SCStreamOutputType) {
        guard sb.isValid, CMSampleBufferGetNumSamples(sb) > 0 else { return }
        switch type {
        case .screen:
            // Skip non-complete frames (idle/blank), per the SCStream contract.
            if let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
               let statusRaw = attachments.first?[.status] as? Int,
               let status = SCFrameStatus(rawValue: statusRaw), status != .complete { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(sb)
            Task { @MainActor in self.routeVideo(sb, pts: pts) }
        case .audio:
            Task { @MainActor in self.routeSystemAudio(sb) }
        default:
            // .microphone (we capture mic via AVCaptureSession) and any future
            // output types are ignored here.
            break
        }
    }
}

extension ScreenRecorder: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in self.onError?(error) }
    }
}

extension ScreenRecorder: AVCaptureAudioDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        guard sb.isValid else { return }
        Task { @MainActor in self.routeMic(sb) }
    }
}

/// Re-stamp a sample buffer's PTS to the output timeline.
extension CMSampleBuffer {
    func retimed(to pts: CMTime) throws -> CMSampleBuffer {
        var timing = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(self),
                                        presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var out: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault, sampleBuffer: self,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &out)
        guard status == noErr, let out else { throw RecordingError.writerFailed }
        return out
    }
}
