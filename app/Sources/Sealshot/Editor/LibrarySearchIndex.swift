import Foundation
import os.log

private let log = OSLog(subsystem: "com.seal-shot.sealshot", category: "library")

private let iso8601 = ISO8601DateFormatter()

/// Searchable text + cheap display metadata for one capture, derived from its
/// `.seal` manifest. The Library matches against `title`, `tags` and `ocrText`
/// (plus the filename, which comes from the URL itself), and renders
/// date/name from `captureDate`/`userTitle` without touching the manifest
/// again.
struct CaptureSearchText: Codable, Equatable {
    /// File mtime at the moment the manifest was read; the cached entry is
    /// reused while the file's mtime still matches.
    let mtime: Date
    let title: String
    let tags: [String]
    let ocrText: String
    /// v2: manifest creation date. Nil only on entries persisted before this
    /// field existed — `refresh` treats nil as stale and re-reads once.
    let captureDate: Date?
    /// v2: manual title override; nil/empty when the filename should show.
    let userTitle: String?
    /// v3: capture category for Library sorting; nil when none. Optional, so
    /// older cached JSON (without the key) decodes to nil.
    let category: ScreenshotCategory?
    /// v4: user favorite flag. Optional, so older cached JSON (without the key)
    /// decodes to nil — synthesized `Codable` calls `decode` (which THROWS on a
    /// missing key) for non-optionals, so this MUST stay optional or legacy
    /// migration JSON fails to decode. Resolved to `false` at the use site.
    let isFavorite: Bool?
    /// v4: triage status. Optional for the same back-compat reason as
    /// `isFavorite`; resolved to `.new` at the use site.
    let status: CaptureStatus?
    /// v5: how this capture originated (.screenRecording for video .seals). Optional
    /// for back-compat: synthesized Codable calls `decode` (throws on missing key)
    /// for non-optionals, so a non-optional field would make legacy JSON decode
    /// throw and silently discard the migration index.
    let captureKind: CaptureKind?
    /// v5: playback duration in seconds. Optional for the same back-compat reason
    /// as `captureKind`; resolved to 0 at the use site.
    let durationSeconds: Double?
    /// v6: collection membership mirrored from `SealManifest.collectionIDs`. Optional
    /// for back-compat: older cached JSON (without the key) decodes to nil — resolved
    /// to [] at the use site.
    let collectionIDs: [UUID]?
    /// v7: auto-generated keywords from AI analysis. Optional for back-compat:
    /// older cached JSON (without the key) decodes to nil — resolved to [] at
    /// the use site. NOT included in the tag vocabulary (autocomplete uses `tags` only).
    let smartKeywords: [String]?
    /// v-dims: source pixel width/height mirrored from `SealManifest.sourceSize`.
    /// Optional for back-compat (older cached JSON lacks the key → nil).
    let width: Int?
    let height: Int?
    /// v-dims: capturing app name mirrored from `SealManifest.sourceApp`.
    let sourceApp: String?

    init(mtime: Date, title: String, tags: [String], ocrText: String,
         captureDate: Date? = nil, userTitle: String? = nil,
         category: ScreenshotCategory? = nil,
         isFavorite: Bool? = nil, status: CaptureStatus? = nil,
         captureKind: CaptureKind? = nil, durationSeconds: Double? = nil,
         collectionIDs: [UUID]? = nil, smartKeywords: [String]? = nil,
         width: Int? = nil, height: Int? = nil, sourceApp: String? = nil) {
        self.mtime = mtime
        self.title = title
        self.tags = tags
        self.ocrText = ocrText
        self.captureDate = captureDate
        self.userTitle = userTitle
        self.category = category
        self.isFavorite = isFavorite
        self.status = status
        self.captureKind = captureKind
        self.durationSeconds = durationSeconds
        self.collectionIDs = collectionIDs
        self.smartKeywords = smartKeywords
        self.width = width
        self.height = height
        self.sourceApp = sourceApp
    }
}

/// LEGACY: the Library's pre-SQLite index — one JSON file of per-capture
/// searchable text in Application Support. `LibraryIndexStore` imports it
/// once (then deletes the file) and owns the live index from then on; what
/// remains in production use here is `load()` for that migration and
/// `readEntry`, the shared manifest→entry reader `reconcile` uses.
struct LibrarySearchIndex {

    /// The single JSON file holding `[standardized path: CaptureSearchText]`.
    let fileURL: URL

    init(fileURL: URL = LibrarySearchIndex.defaultFileURL) {
        self.fileURL = fileURL
    }

    /// Shared production instance, rooted under Application Support.
    static let shared = LibrarySearchIndex()

    static var defaultFileURL: URL {
        AppSupportDirectory.file("searchIndex.json")
    }

    /// Load the cached entries; missing or corrupt file → empty (rebuilds).
    func load() -> [String: CaptureSearchText] {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: CaptureSearchText].self, from: data)
        else { return [:] }
        return decoded
    }

    /// Persist the entries. Failures are logged, never thrown — the index is
    /// a cache; losing it only costs a rebuild.
    func save(_ entries: [String: CaptureSearchText]) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(entries).write(to: fileURL, options: .atomic)
        } catch {
            os_log("search index save failed: %{public}@",
                   log: log, type: .error, String(describing: error))
        }
    }

    /// Production reader: pull searchable text + display metadata out of a
    /// `.seal` manifest. Non-`.seal` files (legacy PNGs) and unreadable
    /// manifests → nil, which leaves that capture searchable by filename only.
    @MainActor
    static func readEntry(at url: URL, mtime: Date) -> CaptureSearchText? {
        guard url.pathExtension == "seal",
              let manifest = try? SealMetadataStore.readManifest(at: url) else { return nil }
        return CaptureSearchText(
            mtime: mtime,
            title: manifest.metadata?.displayTitle(fallback: "") ?? "",
            tags: manifest.metadata?.tags ?? [],
            ocrText: manifest.ocrText ?? "",
            // Fall back to mtime so a manifest with an unparseable date isn't
            // re-read forever (nil is the "stale, read me" marker).
            captureDate: iso8601.date(from: manifest.createdISO8601) ?? mtime,
            userTitle: manifest.metadata?.userTitle,
            category: manifest.metadata?.category,
            isFavorite: CaptureWorkflow.isFavorite(manifest),
            status: CaptureWorkflow.status(manifest),
            captureKind: manifest.captureKind,
            durationSeconds: manifest.video?.durationSeconds,
            collectionIDs: manifest.collectionIDs,
            smartKeywords: manifest.metadata?.smartKeywords,
            width: manifest.sourceSize.width,
            height: manifest.sourceSize.height,
            sourceApp: manifest.sourceApp)
    }
}
