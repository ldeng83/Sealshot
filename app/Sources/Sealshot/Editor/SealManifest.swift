import Foundation

/// Top-level alias so call sites can write `VideoInfo(...)` instead of
/// `SealManifest.VideoInfo(...)`.
typealias VideoInfo = SealManifest.VideoInfo

/// Top-level manifest stored as `manifest.json` inside a `.seal` package.
/// Kept small and stable — additions go through a version bump.
struct SealManifest: Codable, Equatable {

    /// The schema version written by this build. All writers must use this
    /// constant so patching an older package always upgrades it in place.
    /// v5 = image overlay assets (`asset-<id>.png` entries + `.image` geometry).
    /// v6 = capture provenance (captureKind/captureMode/pageDomain).
    /// v7 = workflow (isFavorite/status).
    /// v8 = video payload (VideoInfo).
    /// v9 = summary (on-device generated summary).
    /// v10 = collection membership (collectionIDs).
    /// v11: smartKeywords (auto, read-only) split from user tags
    /// v12 = enhance parameters
    /// v13 = editable summary: userSummary override (CaptureMetadata)
    /// v14 = Live Capture scene layers (sceneLayers)
    static let currentVersion = 14

    /// Pixel dimensions of the immutable `source.png` entry.
    struct Size: Codable, Equatable {
        let width: Int
        let height: Int
    }

    /// v8: video payload descriptor. nil for images and pre-v8 manifests.
    struct VideoInfo: Codable, Equatable {
        /// Playback duration in seconds.
        let durationSeconds: Double
        /// Whether the recording has an audio track. nil = unknown.
        let hasAudio: Bool?
        /// AI-generated bulleted summary of the recording; nil = not generated.
        /// Produced by `VideoSummarizer` (view-driven, on open). Defaulted on decode.
        var summary: String?
        /// Bumped when this recording's summary was generated (see
        /// `VideoSummarizer.summaryVersion`). 0 = never.
        var summaryVersion: Int
        /// Bumped when this recording's tags were generated (see
        /// `VideoTagBuilder.version`). 0 = never. Tags themselves live in
        /// `SealManifest.metadata.tags` (shared with images); this only gates
        /// regeneration.
        var tagVersion: Int

        init(durationSeconds: Double, hasAudio: Bool?,
             summary: String? = nil, summaryVersion: Int = 0, tagVersion: Int = 0) {
            self.durationSeconds = durationSeconds
            self.hasAudio = hasAudio
            self.summary = summary
            self.summaryVersion = summaryVersion
            self.tagVersion = tagVersion
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            durationSeconds = try c.decode(Double.self, forKey: .durationSeconds)
            hasAudio = try c.decodeIfPresent(Bool.self, forKey: .hasAudio)
            summary = try c.decodeIfPresent(String.self, forKey: .summary)
            summaryVersion = try c.decodeIfPresent(Int.self, forKey: .summaryVersion) ?? 0
            tagVersion = try c.decodeIfPresent(Int.self, forKey: .tagVersion) ?? 0
        }
    }

    var version: Int
    var createdISO8601: String
    var modifiedISO8601: String
    var sourceSize: Size

    /// Reserved for future captures to record the front app at capture
    /// time. Always `nil` in v1.
    var sourceApp: String?

    /// v2: which base was last shown (true = enhanced).
    var showingEnhanced: Bool?

    /// v12: applied clarity params baked into the enhanced image. nil = never enhanced
    /// or pre-v12 package; treat as `.default` on load.
    var enhanceParams: EnhanceParams?

    /// v3: auto-generated, user-editable title/tags/category. Nil on older packages.
    var metadata: CaptureMetadata?

    /// v4: full OCR text of `source.png`, lines joined with "\n". Drives the
    /// Library's text search. nil = never OCR-indexed (pre-v4 package);
    /// "" = OCR ran and the image has no recognizable text.
    var ocrText: String?

    /// v6: how this capture originated (screenshot/import/clipboard/new-canvas).
    /// nil on pre-v6 packages and where unknown.
    var captureKind: CaptureKind?

    /// v6: the screenshot mode (area/window/full-screen/scrolling). Set only for
    /// screenshots; nil for imports/clipboard/new-canvas and pre-v6 packages.
    var captureMode: CaptureMode?

    /// v6: bare host of the captured browser tab (e.g. "github.com"). nil when
    /// the source app wasn't a recognized browser, the fetch failed, or pre-v6.
    var pageDomain: String?

    /// v7: user-set Favorite flag. nil/absent ⇒ not favorite.
    var isFavorite: Bool?
    /// v7: triage status. nil/absent ⇒ `.new`.
    var status: CaptureStatus?

    /// v8: present only for video captures (captureKind = .screenRecording / .importedVideo).
    var video: VideoInfo?

    /// Cached on-demand "Extract Structured Data" result (items + composed
    /// Markdown + focus area). nil = never extracted. Synthesized Codable decodes
    /// it as nil on older packages. (Added after v9; no dedicated version bump —
    /// the field is optional so older readers silently ignore it.)
    var extraction: ExtractionRecord?

    /// v10: manual collection membership — UUIDs of `CaptureCollection`s this
    /// capture belongs to. Top-level field (like isFavorite/status) so it works
    /// even for captures with no `CaptureMetadata`. nil/absent on old manifests;
    /// treat nil as empty (not in any collection).
    var collectionIDs: [UUID]?

    /// v14: per-window scene layers for a Live Capture. nil for non-Live-Capture
    /// packages and pre-v14 manifests.
    var sceneLayers: [SceneLayer]?

    init(
        version: Int,
        createdISO8601: String,
        modifiedISO8601: String,
        sourceSize: Size,
        sourceApp: String?,
        showingEnhanced: Bool? = nil,
        enhanceParams: EnhanceParams? = nil,
        metadata: CaptureMetadata? = nil,
        ocrText: String? = nil,
        captureKind: CaptureKind? = nil,
        captureMode: CaptureMode? = nil,
        pageDomain: String? = nil,
        isFavorite: Bool? = nil,
        status: CaptureStatus? = nil,
        video: VideoInfo? = nil,
        extraction: ExtractionRecord? = nil,
        collectionIDs: [UUID]? = nil,
        sceneLayers: [SceneLayer]? = nil
    ) {
        self.version = version
        self.createdISO8601 = createdISO8601
        self.modifiedISO8601 = modifiedISO8601
        self.sourceSize = sourceSize
        self.sourceApp = sourceApp
        self.showingEnhanced = showingEnhanced
        self.enhanceParams = enhanceParams
        self.metadata = metadata
        self.ocrText = ocrText
        self.captureKind = captureKind
        self.captureMode = captureMode
        self.pageDomain = pageDomain
        self.isFavorite = isFavorite
        self.status = status
        self.video = video
        self.extraction = extraction
        self.collectionIDs = collectionIDs
        self.sceneLayers = sceneLayers
    }

    /// Copy-with-changes rewrite: bumps `version` to current and stamps
    /// `modifiedISO8601`, then applies `mutate` to the copy. Every field NOT
    /// touched by `mutate` carries forward BY CONSTRUCTION (value-type copy) —
    /// so a newly added manifest field can never again be silently dropped by
    /// a rewrite site. (History: field-by-field manifest rebuilds have dropped
    /// captureKind (SP-B), isFavorite/status (SP-C), and sceneLayers (v14) —
    /// all the same bug. Rewrite sites MUST use this instead of calling the
    /// memberwise init with a hand-copied field list.)
    func rewritten(now: Date = Date(),
                   _ mutate: (inout SealManifest) -> Void) -> SealManifest {
        var copy = self
        copy.version = SealManifest.currentVersion
        copy.modifiedISO8601 = Self.rewriteTimestampFormatter.string(from: now)
        mutate(&copy)
        return copy
    }

    private static let rewriteTimestampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    func encodeJSON() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try enc.encode(self)
    }

    static func decodeJSON(from data: Data) throws -> SealManifest {
        try JSONDecoder().decode(SealManifest.self, from: data)
    }
}
