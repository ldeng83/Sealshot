import Foundation

/// Flattened, display-ready file info for one Library item, mirroring the
/// editor's file-Info panel. Built from a `SealManifest` (see the
/// `init(manifest:…)` added where it's wired). Display strings are passed in so
/// this stays pure and unit-testable; `detailRows` encodes the editor's Details
/// order and its show/hide rules.
struct LibraryItemInfo: Equatable {
    var name: String
    /// The pipeline's generated summary (nil when none was produced).
    var generatedSummary: String?
    /// Manual override (manifest v13 `userSummary`); preferred for display.
    var userSummary: String?
    /// The displayed summary: the user's override whenever one is present (an
    /// empty override = deliberately suppressed → blank), else generated —
    /// same precedence as CaptureMetadata.effectiveSummary.
    var summary: String? {
        if let u = userSummary { return u.trimmingCharacters(in: .whitespacesAndNewlines) }
        return generatedSummary
    }
    /// Auto-generated smart keywords, shown as a "Keywords: …" line under the
    /// summary (mirrors the editor Info panel).
    var smartKeywords: [String] = []
    var tags: [String]
    var category: ScreenshotCategory?
    var isFavorite: Bool
    var isVideo: Bool
    var width: Int
    var height: Int
    var capturedDisplay: String
    var modifiedDisplay: String
    var sourceApp: String
    var captureKindLabel: String
    var captureModeLabel: String
    var pageDomain: String
    var durationDisplay: String?
    var contentTypeLabel: String
    var sizeDisplay: String

    /// (label, value) rows in the editor's Details order, omitting the same
    /// fields the editor omits.
    var detailRows: [(label: String, value: String)] {
        var rows: [(String, String)] = [("Dimensions", "\(width) × \(height)")]
        rows.append(("Captured", capturedDisplay))
        if modifiedDisplay != capturedDisplay { rows.append(("Modified", modifiedDisplay)) }
        if !sourceApp.isEmpty { rows.append(("Source app", sourceApp)) }
        rows.append(("Source", captureKindLabel))
        if !captureModeLabel.isEmpty { rows.append(("Capture type", captureModeLabel)) }
        if !pageDomain.isEmpty { rows.append(("Website", pageDomain)) }
        if isVideo, let d = durationDisplay { rows.append(("Duration", d)) }
        if !contentTypeLabel.isEmpty { rows.append(("Content type", contentTypeLabel)) }
        rows.append(("Size", sizeDisplay))
        return rows.map { (label: $0.0, value: $0.1) }
    }
}

extension LibraryItemInfo {
    /// Build for a recording saved WITHOUT the package wrapper — a plain
    /// `.mov`/`.mp4` with no manifest behind it.
    ///
    /// Everything here is derived from the file itself: duration and pixel size
    /// from the asset, bytes and dates from the filesystem. The fields a
    /// manifest would carry — summary, tags, keywords, category, source app —
    /// are deliberately left empty rather than faked; the panel showing them
    /// blank is the honest answer to "why is there no metadata", and the
    /// Recording setting says the same thing before the user opts in.
    @MainActor
    init(plainMovie url: URL, name: String, fileSize: Int64,
         durationSeconds: Double?, pixelSize: CGSize?, created: Date?, modified: Date?) {
        self.init(
            name: name,
            generatedSummary: nil,
            userSummary: nil,
            smartKeywords: [],
            tags: [],
            category: nil,
            isFavorite: false,
            isVideo: true,
            width: Int(pixelSize?.width ?? 0),
            height: Int(pixelSize?.height ?? 0),
            capturedDisplay: created.map(CaptureInfoFormatting.displayDate(date:)) ?? "",
            modifiedDisplay: modified.map(CaptureInfoFormatting.displayDate(date:)) ?? "",
            sourceApp: "",
            captureKindLabel: "Screen Recording",
            captureModeLabel: "",
            pageDomain: "",
            durationDisplay: durationSeconds.map { VideoPlaybackMath.timeLabel($0) },
            contentTypeLabel: "",
            sizeDisplay: ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
        )
    }

    /// Build from a per-file manifest read. `fileSize` is the package size on
    /// disk (`sealPackageSize(at:)`); name is the resolved display name.
    @MainActor
    init(manifest m: SealManifest, name: String, fileSize: Int64) {
        let bytes = ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
        let dur = m.video.map { VideoPlaybackMath.timeLabel($0.durationSeconds) }
        // ContentTypeLabel.label(for:) takes a non-optional ScreenshotCategory;
        // m.metadata?.category is ScreenshotCategory? so we flat-map.
        let ctLabel = m.metadata.flatMap { ContentTypeLabel.label(for: $0.category) } ?? ""
        self.init(
            name: name,
            generatedSummary: m.video?.summary ?? m.metadata?.summary,
            userSummary: m.metadata?.userSummary,
            smartKeywords: m.metadata?.smartKeywords ?? [],
            tags: m.metadata?.tags ?? [],
            category: m.metadata?.category,
            isFavorite: m.isFavorite ?? false,
            isVideo: m.video != nil,
            width: m.sourceSize.width,
            height: m.sourceSize.height,
            capturedDisplay: CaptureInfoFormatting.displayDate(iso: m.createdISO8601) ?? "",
            modifiedDisplay: CaptureInfoFormatting.displayDate(iso: m.modifiedISO8601) ?? "",
            sourceApp: m.sourceApp ?? "",
            captureKindLabel: m.captureKind?.displayLabel ?? "",
            captureModeLabel: m.captureMode?.displayLabel ?? "",
            pageDomain: m.pageDomain ?? "",
            durationDisplay: dur,
            contentTypeLabel: ctLabel,
            sizeDisplay: bytes
        )
    }
}
