import Foundation
import CryptoKit

/// Reads/writes only the `manifest.json` entry inside a `.seal` directory
/// bundle, leaving the PNG entries and other manifest fields untouched.
@MainActor
enum SealMetadataStore {

    enum StoreError: Error { case manifestMissing }
    enum CryptoError: Error { case packageLocked, lockHeaderCorrupt }

    private static func manifestURL(in seal: URL) -> URL {
        seal.appendingPathComponent("manifest.json")
    }

    /// Fired after every successful `update(at:)` write with the metadata
    /// before (nil = created from the user-editable shell) and after the
    /// transform. The editor window uses it to mint ⌘Z checkpoints for user
    /// metadata edits (title/summary/tags) without hooking every edit control.
    static var didUpdateMetadata: ((URL, CaptureMetadata?, CaptureMetadata) -> Void)?

    /// Resolve the CEK for a locked package: explicit key wins; else
    /// `identity` (the unlocked session's, at the public entry points)
    /// unwraps lock.json; else throw. Internal so the corrupt-header path is
    /// unit-testable with an injected identity.
    static func resolveCEK(at seal: URL, packageKey: SymmetricKey?,
                           identity: IdentityKey?) throws -> SymmetricKey? {
        guard SealPackageCrypter.isLocked(seal) else { return nil }
        if let packageKey { return packageKey }
        guard let identity else {
            throw CryptoError.packageLocked
        }
        // Identity present but header unreadable → corruption, not a lock
        // state; never mask it as .packageLocked (mirrors SealPackageIO).
        guard let headerData = try? Data(contentsOf: seal.appendingPathComponent(LockHeader.filename)),
              let header = try? JSONDecoder().decode(LockHeader.self, from: headerData)
        else { throw CryptoError.lockHeaderCorrupt }
        return try SealPackageCrypter.unwrapCEK(header, identity: identity)
    }

    static func readManifest(at seal: URL, packageKey: SymmetricKey? = nil) throws -> SealManifest {
        guard var data = sealEntryData("manifest.json", at: seal) else {
            throw StoreError.manifestMissing
        }
        if let cek = try resolveCEK(at: seal, packageKey: packageKey,
                                 identity: SealPackageCryptoContext.current().identity) {
            data = try SealedBlob.open(data, with: cek)
        }
        return try SealManifest.decodeJSON(from: data)
    }

    /// Stamp freshly generated metadata (and the captured source app) into the
    /// package. `ocrText` nil preserves any text already in the manifest.
    static func apply(metadata: CaptureMetadata?, sourceApp: String?,
                      ocrText: String? = nil,
                      captureKind: CaptureKind? = nil, captureMode: CaptureMode? = nil,
                      pageDomain: String? = nil,
                      to seal: URL, packageKey: SymmetricKey? = nil) throws {
        let cek = try resolveCEK(at: seal, packageKey: packageKey,
                                 identity: SealPackageCryptoContext.current().identity)
        let old = try readManifestRaw(at: seal, cek: cek)
        let new = old.rewritten {
            $0.sourceApp = sourceApp ?? old.sourceApp
            $0.metadata = metadata
            $0.ocrText = ocrText ?? old.ocrText
            $0.captureKind = captureKind ?? old.captureKind
            $0.captureMode = captureMode ?? old.captureMode
            $0.pageDomain = pageDomain ?? old.pageDomain
        }
        try writeManifestRaw(new, at: seal, cek: cek)
    }

    /// Patch only `ocrText` (backfill path). Never touches `metadata`, so a
    /// backfill can't clobber user-edited titles/tags. Upgrades the manifest
    /// to the current version.
    static func applyOCRText(_ text: String, to seal: URL,
                              packageKey: SymmetricKey? = nil) throws {
        let cek = try resolveCEK(at: seal, packageKey: packageKey,
                                 identity: SealPackageCryptoContext.current().identity)
        let old = try readManifestRaw(at: seal, cek: cek)
        let new = old.rewritten { $0.ocrText = text }
        try writeManifestRaw(new, at: seal, cek: cek)
    }

    /// Mutate existing metadata in place (e.g. user edits the title/tags).
    /// No-op if the package has no metadata yet, unless `createIfMissing` is
    /// set — user-edit paths (add tag, rename) pass `true` so their edits
    /// persist even when no generator ever ran (on-device AI disabled),
    /// starting from `CaptureMetadata.userEditableShell()`.
    static func update(at seal: URL, packageKey: SymmetricKey? = nil,
                       createIfMissing: Bool = false,
                       _ transform: (inout CaptureMetadata) -> Void) throws {
        let cek = try resolveCEK(at: seal, packageKey: packageKey,
                                 identity: SealPackageCryptoContext.current().identity)
        let old = try readManifestRaw(at: seal, cek: cek)
        guard var meta = old.metadata
            ?? (createIfMissing ? CaptureMetadata.userEditableShell() : nil) else { return }
        let pre = old.metadata
        transform(&meta)
        let new = old.rewritten { $0.metadata = meta }
        try writeManifestRaw(new, at: seal, cek: cek)
        didUpdateMetadata?(seal, pre, meta)
    }

    /// Set the workflow fields (Favorite / Status) at the manifest top level,
    /// independent of `metadata`. A nil argument leaves that field unchanged.
    static func setWorkflow(isFavorite: Bool? = nil, status: CaptureStatus? = nil,
                            to seal: URL, packageKey: SymmetricKey? = nil) throws {
        let cek = try resolveCEK(at: seal, packageKey: packageKey,
                                 identity: SealPackageCryptoContext.current().identity)
        let old = try readManifestRaw(at: seal, cek: cek)
        let new = old.rewritten {
            $0.isFavorite = isFavorite ?? old.isFavorite
            $0.status = status ?? old.status
        }
        try writeManifestRaw(new, at: seal, cek: cek)
    }

    /// Re-date a capture as of `now` and record how it arrived.
    ///
    /// For ADOPTED captures — a `.seal` opened from outside the library. The
    /// strip, Recents and the Date sort all order by capture date, so a
    /// capture keeping its original one is filed months back and never
    /// appears in the surfaces that show recent work. Importing an image
    /// already stamps `now`; this is the same decision for a package.
    ///
    /// The original capture time is genuinely overwritten, which is why the
    /// kind comes with it: the Info panel then reports the capture as
    /// imported rather than presenting today's date as when it was taken.
    static func stampAsAdopted(at seal: URL, kind: CaptureKind, now: Date = Date(),
                               packageKey: SymmetricKey? = nil) throws {
        let cek = try resolveCEK(at: seal, packageKey: packageKey,
                                 identity: SealPackageCryptoContext.current().identity)
        let old = try readManifestRaw(at: seal, cek: cek)
        // `rewritten` carries every field forward and bumps the version, so a
        // rewrite can never silently drop what a newer codec added.
        let new = old.rewritten(now: now) {
            $0.createdISO8601 = ISO8601DateFormatter().string(from: now)
            $0.captureKind = kind
        }
        try writeManifestRaw(new, at: seal, cek: cek)
    }

    /// Patch only the video summary (`VideoInfo.summary`/`summaryVersion`),
    /// preserving everything else. No-op when the package has no `VideoInfo`.
    static func setVideoSummary(_ summary: String, version: Int, to seal: URL,
                                packageKey: SymmetricKey? = nil) throws {
        let cek = try resolveCEK(at: seal, packageKey: packageKey,
                                 identity: SealPackageCryptoContext.current().identity)
        let old = try readManifestRaw(at: seal, cek: cek)
        guard var video = old.video else { return }
        video.summary = summary
        video.summaryVersion = version
        let new = old.rewritten { $0.video = video }
        try writeManifestRaw(new, at: seal, cek: cek)
    }

    /// Set a recording's Smart Keywords. Keywords live in `metadata.smartKeywords`
    /// (auto-generated, read-only); `metadata.tags` (user tags) is preserved
    /// unchanged. `video.tagVersion` only gates regeneration. Creates a minimal
    /// metadata if the recording has none. `tags` is the FINAL auto-keyword list —
    /// the caller already computed it (via `VideoTagBuilder`).
    static func setVideoTags(_ tags: [String], version: Int, to seal: URL,
                             packageKey: SymmetricKey? = nil) throws {
        let cek = try resolveCEK(at: seal, packageKey: packageKey,
                                 identity: SealPackageCryptoContext.current().identity)
        let old = try readManifestRaw(at: seal, cek: cek)
        guard var video = old.video else { return }
        video.tagVersion = version
        let base = old.metadata
        let meta = CaptureMetadata(
            generatedTitle: base?.generatedTitle ?? "",
            userTitle: base?.userTitle,
            tags: base?.tags ?? [],
            smartKeywords: TagNormalizer.normalize(tags),
            category: base?.category ?? .other, confidence: base?.confidence ?? 0,
            generatorVersion: base?.generatorVersion ?? RuleBasedMetadataGenerator.version,
            visualTagVersion: base?.visualTagVersion ?? 0,
            summary: base?.summary, summaryVersion: base?.summaryVersion ?? 0)
        let new = old.rewritten { $0.metadata = meta; $0.video = video }
        try writeManifestRaw(new, at: seal, cek: cek)
    }

    /// Cache the on-demand "Extract Structured Data" result; preserves everything else.
    static func setExtraction(_ record: ExtractionRecord, to seal: URL,
                              packageKey: SymmetricKey? = nil) throws {
        let cek = try resolveCEK(at: seal, packageKey: packageKey,
                                 identity: SealPackageCryptoContext.current().identity)
        let old = try readManifestRaw(at: seal, cek: cek)
        let new = old.rewritten { $0.extraction = record }
        try writeManifestRaw(new, at: seal, cek: cek)
    }

    /// Set the manual collection membership at the manifest top level, independent
    /// of `metadata` (works even when the capture has no metadata yet). `ids` is the
    /// FINAL membership list for this capture.
    static func setCollections(_ ids: [UUID], to seal: URL,
                               packageKey: SymmetricKey? = nil) throws {
        let cek = try resolveCEK(at: seal, packageKey: packageKey,
                                 identity: SealPackageCryptoContext.current().identity)
        let old = try readManifestRaw(at: seal, cek: cek)
        let new = old.rewritten { $0.collectionIDs = ids }
        try writeManifestRaw(new, at: seal, cek: cek)
    }

    /// Read the manual collection membership at the manifest top level.
    static func collections(of seal: URL, packageKey: SymmetricKey? = nil) throws -> [UUID] {
        let cek = try resolveCEK(at: seal, packageKey: packageKey,
                                 identity: SealPackageCryptoContext.current().identity)
        return try readManifestRaw(at: seal, cek: cek).collectionIDs ?? []
    }

    // MARK: - Private raw helpers (CEK already resolved)

    private static func readManifestRaw(at seal: URL, cek: SymmetricKey?) throws -> SealManifest {
        guard var data = sealEntryData("manifest.json", at: seal) else {
            throw StoreError.manifestMissing
        }
        if let cek { data = try SealedBlob.open(data, with: cek) }
        return try SealManifest.decodeJSON(from: data)
    }

    private static func writeManifestRaw(_ m: SealManifest, at seal: URL,
                                         cek: SymmetricKey?) throws {
        var data = try m.encodeJSON()
        if let cek { data = try SealedBlob.seal(data, with: cek) }
        // The manifest lives at the container's TAIL precisely so this — the
        // hot path for every tag, title and OCR write — rewrites kilobytes
        // instead of re-encoding a whole capture.
        if SealContainer.isContainer(seal) {
            try SealContainer.rewritingManifest(data, in: seal)
        } else {
            try data.write(to: manifestURL(in: seal), options: .atomic)
        }
    }
}
