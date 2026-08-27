import Foundation
import CoreGraphics
import ImageIO
import CryptoKit
import os.log

extension Notification.Name {
    /// Posted (main thread) after a capture's metadata is written. `object` is the `.seal` URL.
    static let captureMetadataDidChange = Notification.Name("com.seal-shot.captureMetadataDidChange")
    /// Posted after an import re-creates a collection so the Library drops its
    /// cached CollectionStore and reloads the sidebar + membership.
    static let collectionsDidChange = Notification.Name("com.seal-shot.collectionsDidChange")

    /// Posted (main thread) when the metadata pipeline wants to rename a capture
    /// that is currently open in an editor window. `object` is the current `.seal`
    /// URL; `userInfo["base"]` is the new base name (no extension). The owning
    /// editor window performs the rename through its own safe path so the open
    /// window's autosave/undo/index stay in sync.
    static let captureAutoRenameRequested = Notification.Name("com.seal-shot.captureAutoRenameRequested")

    /// Posted (main thread) when AI-driven filename generation begins for a fresh
    /// capture. `object` is the provisional `.seal` URL. Drives the strip's
    /// "refining…" spinner.
    static let captureNameGenerationStarted = Notification.Name("com.seal-shot.captureNameGenerationStarted")

    /// Posted (main thread) when the final filename has been determined (renamed
    /// or unchanged). `object` is the *original* provisional `.seal` URL the
    /// spinner was keyed on. Clears the strip's "refining…" spinner.
    static let captureNameGenerationFinished = Notification.Name("com.seal-shot.captureNameGenerationFinished")

    /// Posted (main thread) when summary generation begins for a capture. object = `.seal` URL.
    static let captureSummaryGenerationStarted = Notification.Name("com.seal-shot.captureSummaryGenerationStarted")
    /// Posted (main thread) when summary generation ends (success, skip, or error). object = `.seal` URL.
    static let captureSummaryGenerationFinished = Notification.Name("com.seal-shot.captureSummaryGenerationFinished")
    /// Posted at coarse pipeline milestones so determinate Info-panel bars can
    /// step. object = `.seal` URL; userInfo carries `MetadataCoordinator.stageKey`
    /// ("tags"|"summary") and `MetadataCoordinator.fractionKey` (Double 0…1).
    static let captureStageProgress = Notification.Name("com.seal-shot.captureStageProgress")
}

/// Tracks which capture `.seal` URLs are mid AI-filename generation, so UI that
/// appears *after* generation began (e.g. the editor title row, set during the
/// post-capture window swap) can query the state synchronously rather than rely
/// on having caught the start notification. Mirrors `OpenCaptureRegistry`.
@MainActor
final class NameGenerationRegistry {
    static let shared = NameGenerationRegistry()
    private var paths = Set<String>()
    private func key(_ url: URL) -> String { url.standardizedFileURL.path }
    func add(_ url: URL) { paths.insert(key(url)) }
    func remove(_ url: URL) { paths.remove(key(url)) }
    func contains(_ url: URL) -> Bool { paths.contains(key(url)) }
}

/// Tracks capture `.seal` URLs whose OCR is queued or running in the metadata
/// pipeline, so `OCRBackfillCoordinator` doesn't start a second, independent
/// recognition pass over the same image.
///
/// The two pipelines are otherwise unaware of each other, and "is it OCR'd
/// yet?" cannot be answered from disk while the work is in flight: a capture's
/// package is written with `ocrText == nil` *first*, and the text is patched
/// in only when recognition finishes — so for the whole duration of the OCR
/// the file looks exactly like an un-backfilled one. A backfill pass starting
/// in that window (app launch, or post-unlock) picks the capture up and OCRs
/// it again in parallel. Observed in the field: one 2098x1505 capture
/// recognized twice, 59ms apart, each run ~37s because the two contended for
/// the same CPU/GPU. Registration happens at ENQUEUE time, not when the work
/// starts, so an item still sitting on `metaQueue` is covered too.
///
/// Mirrors `NameGenerationRegistry`'s path keying.
@MainActor
final class OCRInFlightRegistry {
    static let shared = OCRInFlightRegistry()
    private var paths = Set<String>()
    private func key(_ url: URL) -> String { url.standardizedFileURL.path }
    func add(_ url: URL) { paths.insert(key(url)) }
    func remove(_ url: URL) { paths.remove(key(url)) }
    func contains(_ url: URL) -> Bool { paths.contains(key(url)) }
}

/// Runs the metadata pipeline asynchronously after a capture is saved:
/// OCR → signals → rule-based generation → patch manifest → notify.
@MainActor
final class MetadataCoordinator {

    static let shared = MetadataCoordinator()

    /// userInfo keys for `.captureStageProgress`.
    static let stageKey = "stage"
    static let fractionKey = "fraction"

    /// Post a stepped-progress milestone for a determinate Info-panel bar.
    static func postStage(_ seal: URL, _ stage: String, _ fraction: Double) {
        NotificationCenter.default.post(
            name: .captureStageProgress, object: seal,
            userInfo: [stageKey: stage, fractionKey: fraction])
    }

    private let log = OSLog(subsystem: "com.seal-shot.sealshot", category: "metadata")
    private let ocr: (CGImage) async throws -> [OCRLine]
    private let visualTags: (CGImage) async -> VisualTags
    private let pendingQueue: PendingIndexQueue
    private let publicKeyProvider: @MainActor () -> IdentityPublicKey?
    private let generationProvider: @MainActor () -> KeyGeneration?
    /// Resolves the generator per capture: the on-device Foundation Model when
    /// AI is enabled and available (macOS 26+), the rule-based generator as the
    /// fallback, or `nil` when AI metadata is turned off (OCR + source app are
    /// still written so search and the Info pane keep working).
    private let metadataGeneratorProvider: @MainActor () -> MetadataGenerating?
    private let summaryGenerator: SummaryGenerating
    /// Describes one Live Capture window for the scene summary. Injectable for
    /// the same reason `summaryGenerator` is: tests must not reach the model.
    private let sceneWindowDescriber: SceneWindowDescribing
    /// When non-nil, overrides the live AI/FM gating for summaries (tests).
    private let summaryGatingOverride: Bool?
    /// Standardized URLs whose summary generation is queued/running (idempotency).
    private var summaryInFlight: Set<URL> = []
    /// Standardized paths of Live Capture scenes whose terminal-marker
    /// exemption has already been spent this process (see `ensureTags`).
    /// Mirrors `NameGenerationRegistry`'s path keying.
    private var scenesRehealed: Set<String> = []

    /// Whether a freshly-captured `.seal` should be renamed to include its title
    /// and app. Encryption must be on (this mode is hidden otherwise), the user
    /// opted in, and at least one human-readable component (title or app) is
    /// available — otherwise the rename would just reproduce the timestamp-only
    /// name. The app name is known at capture time, so this fires even when AI
    /// metadata is off and no title was generated. Whether the capture is open
    /// in an editor only changes the rename *mechanism* (delegated to the window
    /// vs. moved here), not whether it happens. Pure for testing.
    nonisolated static func shouldRenameForTitle(encryptionEnabled: Bool, preferenceEnabled: Bool,
                                                 title: String?, app: String?) -> Bool {
        guard encryptionEnabled, preferenceEnabled else { return false }
        return isNonEmpty(title) || isNonEmpty(app)
    }

    /// Whether a fresh capture will get an AI-generated name (the slow on-device
    /// Foundation Model path), which is the only case worth showing the strip's
    /// "refining…" spinner for. Rule-based naming is effectively instant, and a
    /// capture with no AI is named finally at capture time. Pure for testing.
    nonisolated static func willGenerateAIName(encryptionEnabled: Bool, preferenceEnabled: Bool,
                                               aiEnabled: Bool, foundationModelAvailable: Bool) -> Bool {
        encryptionEnabled && preferenceEnabled && aiEnabled && foundationModelAvailable
    }

    /// `willGenerateAIName` against the CURRENT preferences and availability.
    @MainActor
    static var willGenerateAINameNow: Bool {
        willGenerateAIName(
            encryptionEnabled: EncryptionSession.shared.isEnabled,
            preferenceEnabled: FilenameIncludesTitlePreference().enabled,
            aiEnabled: AIFeaturePreference().enabled,
            foundationModelAvailable: AIAvailability.isFoundationModelAvailable)
    }

    /// Whether the editor's title row should show its "refining" spinner.
    ///
    /// `NameGenerationRegistry` marks the whole metadata pipeline as in flight,
    /// not just AI naming — `ensureTags` enters it whenever ANY generator
    /// exists, and where Foundation Models is unavailable that is the
    /// rule-based one. The spinner means "this filename isn't final yet", so
    /// following the registry alone made it promise a refinement that was never
    /// coming and hold it for the length of the OCR. Rule-based naming is
    /// already final when the file is written, so there is nothing to wait for.
    /// Pure for testing.
    nonisolated static func shouldShowTitleRefining(pipelineInFlight: Bool,
                                                    willGenerateAIName: Bool) -> Bool {
        pipelineInFlight && willGenerateAIName
    }

    /// The title to embed in the filename: the AI-generated title when present,
    /// otherwise the window title captured at screenshot time, otherwise nil.
    /// Lets the "include title & app" toggle work without AI metadata. Pure.
    nonisolated static func renameTitle(aiTitle: String?, windowTitle: String?) -> String? {
        if isNonEmpty(aiTitle) { return aiTitle }
        if isNonEmpty(windowTitle) { return windowTitle }
        return nil
    }

    private nonisolated static func isNonEmpty(_ s: String?) -> Bool {
        guard let s else { return false }
        return !s.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Merge visual tags into freshly-generated metadata and stamp the version.
    /// Pure for testing.
    nonisolated static func applyingVisualTags(to metadata: CaptureMetadata,
                                               visual: VisualTags) -> CaptureMetadata {
        var m = metadata
        m.smartKeywords = VisualTagMerge.atCapture(generated: m.smartKeywords, visual: visual)
        m.visualTagVersion = VisionTagger.version
        return m
    }

    /// Default selection: gated by the AI toggle, then by model availability.
    @MainActor
    static func defaultMetadataGenerator() -> MetadataGenerating? {
        guard AIFeaturePreference().enabled else { return nil }
        switch chooseMetadataGenerator(aiEnabled: true,
                                       foundationModelAvailable: AIAvailability.isFoundationModelAvailable) {
        case .foundationModel:
            if #available(macOS 26, *) { return FoundationMetadataGenerator() }
            return RuleBasedMetadataGenerator()   // unreachable (availability implies 26)
        case .ruleBased:
            return RuleBasedMetadataGenerator()
        }
    }

    /// Default production OCR uses the existing on-device TextRecognizer,
    /// carrying each line's box so the generator can weight titles by size.
    init(ocr: ((CGImage) async throws -> [OCRLine])? = nil,
         visualTags: ((CGImage) async -> VisualTags)? = nil,
         pendingQueue: PendingIndexQueue = PendingIndexQueue(folder: PendingIndexQueue.defaultFolder),
         publicKeyProvider: @escaping @MainActor () -> IdentityPublicKey? = {
             EncryptionSession.shared.publicKey
         },
         generationProvider: @escaping @MainActor () -> KeyGeneration? = {
             EncryptionSession.shared.activeGeneration
         },
         metadataGenerator: @escaping @MainActor () -> MetadataGenerating? = {
             MetadataCoordinator.defaultMetadataGenerator()
         },
         summaryGenerator: SummaryGenerating = FoundationSummaryGenerator(),
         sceneWindowDescriber: SceneWindowDescribing = FoundationSceneWindowDescriber(),
         summaryGatingOverride: Bool? = nil) {
        self.metadataGeneratorProvider = metadataGenerator
        self.summaryGenerator = summaryGenerator
        self.sceneWindowDescriber = sceneWindowDescriber
        self.summaryGatingOverride = summaryGatingOverride
        self.generationProvider = generationProvider
        if let ocr {
            self.ocr = ocr
        } else {
            let recognizer = TextRecognizer()
            self.ocr = { image in
                // Automatic post-capture work with nobody waiting on it, so the
                // refine pass runs under a budget (a no-op on Apple Silicon
                // beyond dropping the sharpened re-read). Every user-initiated
                // path — Live Text, Find in Image, Smart Redaction — keeps the
                // default `.full`.
                let layout = try await recognizer.recognize(image, policy: .budgeted)
                return layout.lines.map { OCRLine(text: $0.text, box: $0.box) }
            }
        }
        if let visualTags {
            self.visualTags = visualTags
        } else {
            let tagger = VisionTagger()
            self.visualTags = { image in
                await Task.detached(priority: .utility) { tagger.tags(for: image) }.value
            }
        }
        self.pendingQueue = pendingQueue
        self.publicKeyProvider = publicKeyProvider
    }

    /// Fire-and-forget entry point for the capture path.
    func start(for seal: URL, sourceApp: String?, windowTitle: String?,
               captureKind: CaptureKind? = nil, captureMode: CaptureMode? = nil,
               sourceBundleID: String? = nil,
               packageKey: SymmetricKey? = nil, source: CGImage? = nil) {
        // Signal the strip to show "refining…" only when the slow AI naming path
        // will actually run; otherwise the file is already named finally.
        let willGenerateName = Self.willGenerateAINameNow
        if willGenerateName {
            NameGenerationRegistry.shared.add(seal)
            NotificationCenter.default.post(name: .captureNameGenerationStarted, object: seal)
        }
        // Serialize metadata generation. Previously each capture/import spawned an
        // unbounded fire-and-forget task; a bulk import (e.g. 50 files) then ran
        // dozens of concurrent OCR + on-device Foundation Model requests on the
        // main actor, which piled up and wedged the app mid-import. Enqueue here
        // and drain one at a time, so files import fast while metadata fills in
        // steadily. `captureDate` is stamped now (enqueue time), not when the
        // worker eventually runs the item.
        let captureDate = Date()
        // Claim the package before it can be enqueued, so a backfill pass that
        // lists the save folder while this item waits its turn (or is mid-OCR)
        // skips it instead of recognizing the same image a second time.
        OCRInFlightRegistry.shared.add(seal)
        metaQueue.append { [weak self] in
            await self?.generate(for: seal, sourceApp: sourceApp, windowTitle: windowTitle,
                                 captureKind: captureKind, captureMode: captureMode,
                                 sourceBundleID: sourceBundleID,
                                 captureDate: captureDate, packageKey: packageKey, source: source,
                                 signalNameGeneration: willGenerateName)
        }
        drainMetaQueue()
    }

    /// Generate + persist a summary for `seal` if gating allows. Always posts
    /// Started before and Finished after, so a UI progress flag always clears.
    func generateSummary(for seal: URL, packageKey: SymmetricKey?) async {
        NotificationCenter.default.post(name: .captureSummaryGenerationStarted, object: seal)
        defer { NotificationCenter.default.post(name: .captureSummaryGenerationFinished, object: seal) }

        let manifest = try? SealMetadataStore.readManifest(at: seal, packageKey: packageKey)
        let allowed = summaryGatingOverride ?? SummaryGating.shouldGenerate(
            aiEnabled: AIFeaturePreference().enabled,
            foundationModelAvailable: AIAvailability.isFoundationModelAvailable,
            summaryPresent: manifest?.metadata?.summary != nil,
            ocrText: manifest?.ocrText,
            isScene: manifest?.captureKind == .liveCapture)
        // `ocrText` unwraps here for BOTH branches below, but only the
        // non-scene path (further down) actually reads it: the scene branch
        // rebuilds its own per-window text from the package instead. A scene
        // with genuinely no readable windows still has a stored `ocrText` of
        // `""` (a real value, written by `sceneAwareOCR`/`SceneText.aggregate`
        // at capture/backfill time) — never `nil` — so this guard does not
        // need a scene exemption of its own; it only ever rejects a manifest
        // that was never OCR'd at all.
        guard allowed, let ocrText = manifest?.ocrText, manifest?.metadata != nil else { return }
        Self.postStage(seal, "summary", 0.25)            // OCR ready, about to run the model
        defer { Self.postStage(seal, "summary", 1.0) }

        // Live Capture: one bullet per captured window, assembled from the
        // manifest rather than asked of the model, so no window can be renamed,
        // merged, or dropped. Scenes pass their own clamp bounds — the bullet
        // count is the window count, which is known before the model runs.
        //
        // No `.skip` case, deliberately: the non-scene path below persists an
        // empty terminal marker when the model declines, but a scene whose
        // window descriptions all fail still yields name-only bullets — a list
        // of what was captured, useful on its own — so it is stored. Nothing is
        // written only when the scene has no readable windows or the clamp
        // rejects the result. Descriptions are produced one window at a time
        // (see `SceneSummarizer`): two concurrent on-device model contexts
        // spike memory to ~5GB, which is why tag and summary generation are
        // serialized on `metaQueue` in the first place.
        //
        // Being a scene is decided FIRST, and a failed package read returns
        // without writing. Folding the read into the same condition let a
        // locked/corrupt scene fall through to the generic generator below —
        // and since a stored summary is terminal, that generic blob could never
        // be replaced by the per-window list on a later open.
        if manifest?.captureKind == .liveCapture,
           let sceneLayers = manifest?.sceneLayers, !sceneLayers.isEmpty {
            guard let contents = try? readSealPackage(
                at: seal, crypto: SealPackageCryptoContext.current()) else { return }
            let windows = await sceneWindowTexts(sceneLayers: sceneLayers,
                                                 imageAssets: contents.imageAssets)
            guard let raw = await SceneSummarizer(describer: sceneWindowDescriber)
                .summarize(windows) else { return }
            let n = max(1, windows.count)
            // The total bound is derived, not guessed: `clamp` measures the
            // string it composes (with the "- " prefixes and newlines), so a
            // bare n × perBullet budget is short and deletes the backmost
            // windows' bullets. See `SummaryClamp.totalBudget`.
            let perBullet = SummaryClamp.sceneMaxBulletChars
            guard let clamped = SummaryClamp.clamp(
                raw, maxBullets: n, maxBulletChars: perBullet,
                maxTotalChars: SummaryClamp.totalBudget(bullets: n, perBullet: perBullet))
            else { return }
            do {
                try SealMetadataStore.update(at: seal, packageKey: packageKey) {
                    $0.summary = clamped
                }
            } catch {
                os_log("scene summary write failed for %{public}@: %{public}@",
                       log: log, type: .error, seal.lastPathComponent, String(describing: error))
            }
            return
        }

        // Persist on `.text` (the summary) and `.skip` (an empty terminal marker
        // so the panel shows "No summary" and we never re-run for this input).
        // `.transient` writes nothing — leave it for a later retry.
        let summaryToWrite: String
        switch await summaryGenerator.summarize(ocrText: ocrText) {
        case .text(let s): summaryToWrite = s
        case .skip:        summaryToWrite = ""
        case .transient:   return
        }
        do {
            try SealMetadataStore.update(at: seal, packageKey: packageKey) { $0.summary = summaryToWrite }
        } catch {
            os_log("summary write failed for %{public}@: %{public}@",
                   log: log, type: .error, seal.lastPathComponent, String(describing: error))
        }
    }

    /// Whether a summary is currently queued/generating for `seal` (so the
    /// editor can show its progress bar when it opens mid-generation).
    func isSummaryInFlight(for seal: URL) -> Bool {
        summaryInFlight.contains(seal.standardizedFileURL)
    }

    /// Idempotent: enqueue summary generation for `seal` unless one already
    /// exists or is in-flight. Used for backfill when an image is opened.
    func ensureSummary(for seal: URL, packageKey: SymmetricKey? = nil) {
        let key = seal.standardizedFileURL
        guard !summaryInFlight.contains(key) else { return }
        // Same rule as ensureTags: an UNREADABLE manifest is not actionable.
        guard let manifest = try? SealMetadataStore.readManifest(at: seal, packageKey: packageKey)
        else { return }
        guard manifest.metadata?.summary == nil else { return }
        // A deliberate suppression (userSummary == "") counts as present, so a
        // summary the user cleared is never regenerated.
        // Same isScene exemption as `generateSummary`'s gate below — this is
        // the entry point the capture path actually calls for a scene, so
        // without it a textless scene never even reaches `generateSummary`.
        guard summaryGatingOverride ?? SummaryGating.shouldGenerate(
            aiEnabled: AIFeaturePreference().enabled,
            foundationModelAvailable: AIAvailability.isFoundationModelAvailable,
            summaryPresent: false, ocrText: manifest.ocrText,
            userSummaryPresent: manifest.metadata?.hasUserSummaryOverride ?? false,
            isScene: manifest.captureKind == .liveCapture) else { return }
        summaryInFlight.insert(key)
        metaQueue.append { [weak self] in
            await self?.generateSummary(for: seal, packageKey: packageKey)
            self?.summaryInFlight.remove(key)
        }
        drainMetaQueue()
    }

    /// Idempotent: enqueue tag (metadata) backfill for `seal` when it has no
    /// tags yet — used when an image is opened. No-op if tags exist, a
    /// generation is already in flight, or no generator is available (AI off).
    /// Whether the keyword backfill should run for this manifest state.
    /// Empty smart keywords normally mean "generate", with one terminal
    /// exception: OCR ran and found NO text (`ocrText == ""`, the v4 marker) —
    /// a pure image can never yield text keywords, and re-running would loop
    /// forever (generate → nothing written → metadata-change notification →
    /// generate…).
    ///
    /// Live Capture is exempt. For a scene that marker never meant "this image
    /// has no text" — it meant "we OCR'd the wallpaper", which is the bug. A
    /// scene re-reads its window assets instead, and the loop can't recur
    /// because the re-read writes real text. The exemption is deliberately
    /// scoped to scenes: widening it reopens the livelock above.
    nonisolated static func needsTagBackfill(smartKeywordsEmpty: Bool, ocrText: String?,
                                             isScene: Bool = false) -> Bool {
        guard smartKeywordsEmpty else { return false }
        return isScene || ocrText != ""
    }

    func ensureTags(for seal: URL, packageKey: SymmetricKey? = nil) {
        guard !NameGenerationRegistry.shared.contains(seal) else { return }
        guard metadataGeneratorProvider() != nil else { return }
        // UNREADABLE manifest means "can't generate", never "needs backfill":
        // treating it as missing tags arms a generation that must skip (its
        // own read fails too), whose completion notification re-runs this
        // check — a main-thread livelock when the package stays unreadable
        // (observed: capture while locked → unlock → app pegged at 100%).
        guard let manifest = try? SealMetadataStore.readManifest(at: seal, packageKey: packageKey)
        else { return }
        guard Self.needsTagBackfill(
            smartKeywordsEmpty: manifest.metadata?.smartKeywords.isEmpty ?? true,
            ocrText: manifest.ocrText,
            isScene: manifest.captureKind == .liveCapture) else { return }
        // The scene exemption above lets a scene carrying the terminal `""`
        // marker re-read its windows — but it fires on EVERY open, and a scene
        // of photo/media windows OCRs to nothing every time, so the full decode
        // + per-window OCR would be paid forever for a guaranteed no-op. Heal
        // once per process instead: the first open after launch re-reads, later
        // opens are as cheap as the marker used to make them.
        if manifest.captureKind == .liveCapture, manifest.ocrText == "",
           !scenesRehealed.insert(seal.standardizedFileURL.path).inserted { return }
        NameGenerationRegistry.shared.add(seal)
        NotificationCenter.default.post(name: .captureNameGenerationStarted, object: seal)
        // Same claim as `start`: this path re-OCRs the package when it has no
        // stored text, which is exactly the manifest state backfill selects on.
        OCRInFlightRegistry.shared.add(seal)
        metaQueue.append { [weak self] in await self?.generateTags(for: seal, packageKey: packageKey) }
        drainMetaQueue()
    }

    /// OCR each Live Capture window from its own PNG asset, tagged with the
    /// identity the manifest already holds.
    ///
    /// A scene's `source` image is the display wallpaper (`SceneTypes.swift`
    /// `CapturedDisplay`), so OCR'ing it finds nothing and the pipeline used to
    /// persist the terminal "OCR ran, no text" marker. The readable content is
    /// in the per-window assets. The wallpaper is deliberately never read —
    /// desktop icon names and menu-bar text would otherwise reach keywords.
    func sceneWindowTexts(sceneLayers: [SceneLayer],
                          imageAssets: [String: Data]) async -> [SceneWindowText] {
        var out: [SceneWindowText] = []
        for layer in sceneLayers.sorted(by: { $0.z < $1.z }) {
            guard let data = imageAssets[layer.assetID],
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                // Missing or undecodable bytes cost the window's TEXT, never
                // the window: its app and title are right here in the manifest,
                // so it still gets a name-only bullet in the scene summary.
                // (`SceneText.aggregate` drops empty-text windows on its own, so
                // this adds no blank heading to the keyword text.)
                os_log("scene window asset missing or undecodable, no text: %{public}@",
                       log: log, type: .info, layer.assetID)
                out.append(SceneWindowText(app: layer.app, title: layer.title,
                                           z: layer.z, text: ""))
                continue
            }
            let lines = (try? await ocr(image)) ?? []
            let text = lines.map(\.text).joined(separator: "\n")
            out.append(SceneWindowText(app: layer.app, title: layer.title,
                                       z: layer.z, text: text))
        }
        return out
    }

    /// OCR a package's contents for the metadata pipeline: a Live Capture
    /// scene reads its per-window assets (`source` is the wallpaper and has no
    /// readable text); everything else OCRs `source` as before. Shared by the
    /// backfill and capture-time paths so the "is this a scene" rule can't
    /// drift between them — it is applied exactly once, here. Only called
    /// once package contents are already in hand; the capture-time path's
    /// in-memory `source` fast path (no package read at all) never reaches
    /// this helper.
    func sceneAwareOCR(for contents: SealPackageContents) async -> (lines: [OCRLine], text: String) {
        if contents.manifest.captureKind == .liveCapture,
           let sceneLayers = contents.manifest.sceneLayers, !sceneLayers.isEmpty {
            let windows = await sceneWindowTexts(sceneLayers: sceneLayers,
                                                 imageAssets: contents.imageAssets)
            return ([], SceneText.aggregate(windows))
        }
        let lines = (try? await ocr(contents.source)) ?? []
        return (lines, lines.map(\.text).joined(separator: "\n"))
    }

    /// Generate tags/title/category for an EXISTING package from its OCR text and
    /// write them non-destructively (preserves sourceApp, dates, favorite/status,
    /// summary, visual tags; no rename). The registry entry and progress bar
    /// always clear; `captureMetadataDidChange` posts ONLY when something was
    /// persisted — a no-op exit that still announces a change re-arms the
    /// editor's backfill check, and if the manifest is unreadable that cycle
    /// never terminates (defense in depth behind ensureTags' readable guard).
    func generateTags(for seal: URL, packageKey: SymmetricKey?) async {
        var wrote = false
        defer {
            NameGenerationRegistry.shared.remove(seal)
            OCRInFlightRegistry.shared.remove(seal)
            Self.postStage(seal, "tags", 1.0)
            if wrote {
                NotificationCenter.default.post(name: .captureMetadataDidChange, object: seal)
            }
        }
        guard let generator = metadataGeneratorProvider(),
              let manifest = try? SealMetadataStore.readManifest(at: seal, packageKey: packageKey),
              Self.needsTagBackfill(
                smartKeywordsEmpty: manifest.metadata?.smartKeywords.isEmpty ?? true,
                ocrText: manifest.ocrText,
                isScene: manifest.captureKind == .liveCapture) else { return }
        Self.postStage(seal, "tags", 0.25)

        // Reuse stored OCR text; only decode the package to OCR if it has none.
        // For non-scene captures a stored "" is terminal and already rejected
        // by the gate, so this path only reaches "" for a Live Capture scene —
        // the exemption's healing path — which re-decodes and re-OCRs below.
        let lines: [OCRLine]
        let ocrText: String
        if let stored = manifest.ocrText,
           !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ocrText = stored
            lines = []
        } else if let contents = try? readSealPackage(at: seal, crypto: SealPackageCryptoContext.current()) {
            (lines, ocrText) = await sceneAwareOCR(for: contents)
        } else {
            return
        }
        guard !ocrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // Pure image: persist the terminal "OCR ran, no text" marker so the
            // gate stops future re-runs (and the progress bar stops looping).
            // A text-free Live Capture scene reaches this same branch on every
            // pass (the scene exemption bypasses the marker), so only report a
            // write when the marker actually changes — otherwise the second
            // pass re-arms the notification cycle the marker exists to stop.
            let changed = manifest.ocrText != ""
            if changed {
                wrote = (try? SealMetadataStore.applyOCRText("", to: seal, packageKey: packageKey)) != nil
            }
            return
        }
        Self.postStage(seal, "tags", 0.6)               // OCR ready, about to generate tags

        let captureDate = ISO8601DateFormatter().date(from: manifest.createdISO8601) ?? Date()
        let signals = MetadataSignals(
            ocrText: ocrText, ocrLines: lines, sourceApp: manifest.sourceApp,
            windowTitle: nil, captureDate: captureDate,
            imageWidth: manifest.sourceSize.width, imageHeight: manifest.sourceSize.height)
        var generated = await generator.makeMetadata(for: signals)
        Self.postStage(seal, "tags", 0.9)
        // Carry over fields the freshly-generated metadata doesn't know about, so
        // the backfill can't wipe a summary/visual tags/user title/user tags
        // written earlier. Generators only ever produce `smartKeywords` (they set
        // `tags: []`), so without this the regenerated struct would clobber every
        // user-added tag — the exact wipe seen when on-device AI is turned on and
        // the first keyword backfill runs on a capture the user had already tagged.
        if let old = manifest.metadata {
            generated.tags = old.tags
            generated.summary = old.summary
            generated.visualTagVersion = old.visualTagVersion
            if let userTitle = old.userTitle { generated.userTitle = userTitle }
            generated.userSummary = old.userSummary
        }
        // Persist the OCR text too if the package had none (helps later summary backfill).
        let ocrToPersist = (manifest.ocrText?.isEmpty ?? true) ? ocrText : nil
        wrote = (try? SealMetadataStore.apply(metadata: generated, sourceApp: nil, ocrText: ocrToPersist,
                                              to: seal, packageKey: packageKey)) != nil
    }

    /// Pending metadata work + whether a drain loop is active. Touched only on
    /// the main actor (this class is `@MainActor`), so no locking is needed.
    private var metaQueue: [() async -> Void] = []
    private var metaDraining = false

    /// Process the queue one item at a time. A single drain loop runs at a time;
    /// `start` appends and the running loop picks new items up on its next turn.
    private func drainMetaQueue() {
        guard !metaDraining else { return }
        metaDraining = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            while !self.metaQueue.isEmpty {
                let work = self.metaQueue.removeFirst()
                await work()
            }
            self.metaDraining = false
        }
    }

    func generate(for seal: URL, sourceApp: String?, windowTitle: String?,
                  captureKind: CaptureKind? = nil, captureMode: CaptureMode? = nil,
                  sourceBundleID: String? = nil,
                  captureDate: Date,
                  packageKey: SymmetricKey? = nil, source: CGImage? = nil,
                  signalNameGeneration: Bool = false) async {
        // The final name is "determined" on any exit (renamed, unchanged, or
        // error) — always clear the spinner so it can never hang.
        defer {
            // Released on the pre-rename URL, the one `start` claimed. After a
            // rename the old path is gone and the new one already carries its
            // OCR text, so neither is a backfill candidate either way.
            OCRInFlightRegistry.shared.remove(seal)
            if signalNameGeneration {
                NameGenerationRegistry.shared.remove(seal)
                NotificationCenter.default.post(name: .captureNameGenerationFinished, object: seal)
            }
        }
        do {
            // When the in-memory source image is available (capture path), use
            // it directly — avoids reading/decrypting the package just to get
            // the CGImage, and works while the session is locked.
            // When source is nil (OCR backfill path), read from disk — this will
            // throw .packageLocked for locked packages without identity (Task 6
            // will handle the skip there).
            //
            // A Live Capture's in-memory `source` (when a caller supplies one) is
            // deliberately ignored here even though it exists: for a scene, that
            // image is the display wallpaper, not readable content, and routing
            // it through the fast path would OCR desktop icon names and menu-bar
            // text into the capture's keywords. Only the package-read branch
            // knows to route a scene to its per-window assets (`sceneAwareOCR`),
            // so a scene must always take that branch regardless of what the
            // caller passed in.
            //
            // `imageForOCR` still determines the recorded image dimensions; for a
            // scene that is the backdrop, which is the scene's canvas size.
            let imageForOCR: CGImage
            let lines: [OCRLine]
            let ocrText: String
            if let source, captureKind != .liveCapture {
                imageForOCR = source
                lines = (try? await ocr(source)) ?? []
                ocrText = lines.map(\.text).joined(separator: "\n")
            } else {
                let contents = try readSealPackage(at: seal, crypto: SealPackageCryptoContext.current())
                imageForOCR = contents.source
                (lines, ocrText) = await sceneAwareOCR(for: contents)
            }
            // Generation gate: title/tags/category are produced only when a
            // generator is resolved (AI enabled). OCR text + source app are
            // written either way, so search and the Info pane never depend on it.
            let metadata: CaptureMetadata?
            if let generator = metadataGeneratorProvider() {
                let signals = MetadataSignals(
                    ocrText: ocrText, ocrLines: lines, sourceApp: sourceApp, windowTitle: windowTitle,
                    captureDate: captureDate,
                    imageWidth: imageForOCR.width, imageHeight: imageForOCR.height)
                // Generate tags and the summary SEQUENTIALLY — both are on-device
                // Foundation Model inferences, and running two LLM contexts at once
                // spiked memory (~5GB). The UI still shows both progress bars; only
                // the work is serialized. Written in a single manifest update below.
                //
                // A Live Capture scene is deliberately excluded: its summary is
                // one bullet per captured window, assembled from the manifest,
                // which only `generateSummary` knows how to build. Summarizing
                // the aggregated scene text with the generic generator here
                // would store a 3-bullet blob — and a stored summary is
                // terminal (`ensureSummary` and the editor's extraction sync
                // both bail once one exists), so the per-window list could never
                // replace it. Scenes are routed to `ensureSummary` below, after
                // the manifest is written and the file has its final name.
                let wantSummary = !ocrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && captureKind != .liveCapture
                    && AIAvailability.isFoundationModelAvailable && AIFeaturePreference().enabled
                var generated = await generator.makeMetadata(for: signals)
                let visual = await visualTags(imageForOCR)
                generated = Self.applyingVisualTags(to: generated, visual: visual)
                if wantSummary {
                    // `.text` persists the summary; `.skip` persists "" (terminal
                    // marker, no re-run); `.transient` leaves it nil to retry later.
                    switch await summaryGenerator.summarize(ocrText: ocrText) {
                    case .text(let s): generated.summary = s
                    case .skip:        generated.summary = ""
                    case .transient:   generated.summary = nil
                    }
                } else {
                    generated.summary = nil
                }
                metadata = generated
            } else {
                metadata = nil
            }
            // Website (pageDomain) is no longer resolved: it rode the removed
            // JS-over-AppleScript path, which needed both the Automation grant
            // and the browsers' off-by-default "Allow JavaScript from Apple
            // Events" dev setting — so it was almost always nil in practice.
            // Existing captures keep whatever domain they stored.
            let pageDomain: String? = nil

            try SealMetadataStore.apply(metadata: metadata, sourceApp: sourceApp,
                                        ocrText: ocrText,
                                        captureKind: captureKind, captureMode: captureMode,
                                        pageDomain: pageDomain,
                                        to: seal, packageKey: packageKey)

            // Opt-in (encryption on): rename the package to "<title> <app> <date>"
            // now that the title exists. Downstream index/notification use the
            // post-rename URL. Skipped if the capture is open in an editor.
            var finalSeal = seal
            let titleForName = Self.renameTitle(
                aiTitle: metadata?.displayTitle(fallback: ""), windowTitle: windowTitle)
            if Self.shouldRenameForTitle(
                encryptionEnabled: EncryptionSession.shared.isEnabled,
                preferenceEnabled: FilenameIncludesTitlePreference().enabled,
                title: titleForName, app: sourceApp) {
                let base = CaptureConfig.composeTitleAppBase(
                    title: titleForName, app: sourceApp,
                    format: CaptureConfig().filenameFormat, at: captureDate)
                if OpenCaptureRegistry.shared.contains(seal) {
                    // Open in an editor: the window must own the move so its
                    // pending autosave, undo history, and represented URL stay in
                    // sync. Delivered synchronously, so the rename is done when
                    // this returns. finalSeal stays `seal` here — an open capture
                    // is unlocked, so the locked-pending-index path below is moot.
                    NotificationCenter.default.post(name: .captureAutoRenameRequested,
                                                    object: seal, userInfo: ["base": base])
                } else {
                    let folder = seal.deletingLastPathComponent()
                    let newName = CaptureConfig.uniqueName(base: base, ext: "seal") {
                        FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
                    }
                    let newURL = folder.appendingPathComponent(newName, isDirectory: false)
                    if newURL != seal {
                        do {
                            try FileManager.default.moveItem(at: seal, to: newURL)
                            finalSeal = newURL
                        } catch {
                            os_log("title-rename move failed %{public}@ → %{public}@: %{public}@", log: log,
                                   type: .error, seal.lastPathComponent, newName, String(describing: error))
                        }
                    }
                }
            }

            // For locked-format packages, the index reconcile cannot read the
            // sealed manifest → enqueue a pending entry so the title/OCR reach
            // the index at the next unlock drain.
            if SealPackageCrypter.isLocked(finalSeal) {
                if let publicKey = publicKeyProvider(), let generation = generationProvider() {
                    let mtime = (try? FileManager.default.attributesOfItem(atPath: finalSeal.path)[.modificationDate] as? Date) ?? Date()
                    // captureDate is the same instant stamped into the
                    // manifest moments ago — re-reading (and re-decrypting)
                    // the manifest for createdISO8601 would be wasted crypto.
                    let row = CaptureIndexRow(
                        path: finalSeal.standardizedFileURL.path,
                        folder: finalSeal.deletingLastPathComponent().standardizedFileURL.path,
                        mtime: mtime,
                        captureDate: captureDate,
                        userTitle: metadata?.userTitle,
                        title: metadata?.displayTitle(fallback: "") ?? "",
                        tags: metadata?.tags ?? [],
                        smartKeywords: metadata?.smartKeywords ?? [])
                    let entry = PendingIndexEntry(row: row, ocrText: ocrText)
                    try? pendingQueue.append(entry, publicKey: publicKey, generation: generation)
                } else {
                    // No public key to wrap the entry — the index won't learn
                    // this capture's title/OCR until a future unlocked
                    // reconcile. Should not happen once provisioned; log loudly.
                    os_log("locked package but no public key — pending index entry skipped for %{public}@",
                           log: log, type: .error, finalSeal.lastPathComponent)
                }
            }

            // A scene's summary is generated separately (see `wantSummary`):
            // queue it on `finalSeal`, the POST-rename URL, since the block
            // above may have moved the package. `ensureSummary` is idempotent
            // and appends to `metaQueue`, so the two on-device model contexts
            // still never run at once — this item is picked up by the same
            // drain loop after `generate` returns.
            if captureKind == .liveCapture {
                ensureSummary(for: finalSeal, packageKey: packageKey)
            }

            // Tags + summary were generated concurrently above and written
            // together, so a single change notification covers both.
            NotificationCenter.default.post(name: .captureMetadataDidChange, object: finalSeal)
        } catch {
            os_log("metadata generation failed for %{public}@: %{public}@",
                   log: log, type: .error, seal.lastPathComponent, String(describing: error))
        }
    }
}
