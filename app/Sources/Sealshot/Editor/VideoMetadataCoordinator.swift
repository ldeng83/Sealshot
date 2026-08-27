import Foundation

/// Owns video recording metadata (summary + tags) generation. Triggered eagerly
/// when a recording finishes (like image capture tags at save) and on-demand when
/// a recording is opened. Runs ONE recording at a time (serial) to bound memory —
/// the old concurrent video backfill spiked footprint; serial generation plus the
/// per-recording frame cap keeps it safe. Posts start/progress/finish notifications
/// so the open recording's Info panel can show progress bars, mirroring the image
/// `captureNameGenerationStarted/Finished` pattern.
@MainActor
final class VideoMetadataCoordinator {

    static let shared = VideoMetadataCoordinator()

    /// object = recording `.seal` URL.
    static let started = Notification.Name("com.seal-shot.videoMetadataGenerationStarted")
    /// object = recording `.seal` URL.
    static let finished = Notification.Name("com.seal-shot.videoMetadataGenerationFinished")
    /// object = recording `.seal` URL; userInfo["fraction"] = Double 0…1.
    static let progress = Notification.Name("com.seal-shot.videoMetadataProgress")
    static let progressFractionKey = "fraction"

    private var inFlight: Set<URL> = []
    private var queue: [URL] = []
    private var running = false

    /// Pure gate: what (summary/tags) this recording still needs. Summary needs FM
    /// (`aiOn` = toggle + Foundation Models); tags are deterministic (no FM) but
    /// still honor the "Use on-device AI" toggle (`aiEnabled`) so turning AI off
    /// stops ALL auto-metadata, matching the image pipeline. A non-nil summary
    /// at the current version (including the "" terminal marker) counts as done.
    /// A manual summary override (v13) is authoritative: it suppresses
    /// summary generation entirely.
    static func needs(video: SealManifest.VideoInfo?, aiOn: Bool, aiEnabled: Bool,
                      userSummaryPresent: Bool = false) -> (summary: Bool, tags: Bool) {
        let summaryDone = video?.summary != nil
            && (video?.summaryVersion ?? 0) >= VideoSummarizer.summaryVersion
        let tagsDone = (video?.tagVersion ?? 0) >= VideoTagBuilder.version
        return (aiOn && !summaryDone && !userSummaryPresent,
                aiEnabled && !tagsDone)
    }

    /// Idempotent: enqueue generation for `videoSeal` unless it's up to date or
    /// already queued/running.
    func ensure(for videoSeal: URL) {
        // A recording saved as a plain movie has no manifest to read the
        // "already generated" flags from, and none to write results into. Left
        // unguarded, generation starts (posting `started`, which lights the
        // Info panel's progress bars), produces a summary it cannot persist,
        // and runs again on the next open — a spinner that never completes.
        guard videoSeal.pathExtension.lowercased() == "seal" else { return }
        let key = videoSeal.standardizedFileURL
        guard !inFlight.contains(key) else { return }
        let manifest = try? SealMetadataStore.readManifest(at: key)
        let g = Self.needs(video: manifest?.video, aiOn: Self.aiOn, aiEnabled: Self.aiEnabled,
                           userSummaryPresent: Self.hasUserSummary(manifest?.metadata))
        guard g.summary || g.tags else { return }
        inFlight.insert(key)
        queue.append(key)
        drain()
    }

    private static var aiOn: Bool {
        AIAvailability.isFoundationModelAvailable && AIFeaturePreference().enabled
    }

    /// The master "Use on-device AI" toggle alone — gates the deterministic
    /// (non-FM) tag pass, which runs on every macOS when AI is enabled.
    private static var aiEnabled: Bool { AIFeaturePreference().enabled }

    private func drain() {
        guard !running, let next = queue.first else { return }
        running = true
        // `.utility`, matching OCRBackfillCoordinator and VisualTagBackfillJob:
        // nobody is waiting on a post-recording summary, and its frame OCR must
        // not compete with a capture or a Live Text read the user IS waiting on.
        // Inheriting the enqueuer's priority put this background sweep at the
        // same urgency as foreground work.
        Task(priority: .utility) { @MainActor in
            await self.generate(next)
            if !self.queue.isEmpty { self.queue.removeFirst() }
            self.inFlight.remove(next.standardizedFileURL)
            self.running = false
            self.drain()
        }
    }

    private static func hasUserSummary(_ metadata: CaptureMetadata?) -> Bool {
        // A deliberate suppression (userSummary == "") counts as present so the
        // cleared summary is never regenerated.
        metadata?.hasUserSummaryOverride ?? false
    }

    private func generate(_ url: URL) async {
        let manifest = try? SealMetadataStore.readManifest(at: url)
        let g = Self.needs(video: manifest?.video, aiOn: Self.aiOn, aiEnabled: Self.aiEnabled,
                           userSummaryPresent: Self.hasUserSummary(manifest?.metadata))
        guard g.summary || g.tags else { return }

        NotificationCenter.default.post(name: Self.started, object: url)
        defer { NotificationCenter.default.post(name: Self.finished, object: url) }

        let result = await VideoSummarizer.summarize(videoSeal: url, onProgress: { frac in
            NotificationCenter.default.post(name: Self.progress, object: url,
                                            userInfo: [Self.progressFractionKey: frac])
        })

        var changed = false
        if g.tags {
            try? SealMetadataStore.setVideoTags(result.tags, version: VideoTagBuilder.version, to: url)
            changed = true
        }
        if g.summary {
            switch result.summary {
            case .text(let s):
                try? SealMetadataStore.setVideoSummary(s, version: VideoSummarizer.summaryVersion, to: url)
                changed = true
            case .skip:
                try? SealMetadataStore.setVideoSummary("", version: VideoSummarizer.summaryVersion, to: url)
                changed = true
            case .transient:
                break
            }
        }
        if changed {
            NotificationCenter.default.post(name: .captureMetadataDidChange, object: url)
        }
    }
}
