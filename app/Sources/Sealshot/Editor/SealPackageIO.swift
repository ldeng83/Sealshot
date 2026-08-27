import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import os.log

private let log = OSLog(subsystem: "com.seal-shot.sealshot", category: "sealio")

/// Read-side result of a `.seal` package.
struct SealPackageContents {
    let source: CGImage
    let composite: CGImage
    let annotations: [Annotation]
    let crop: CGRect?
    /// v11: region of the source shown when the canvas has been grown (see
    /// `EditorState.contentClip`). nil = no grow.
    let contentClip: CGRect?
    let focus: CGRect?
    /// v8: the document was resampled to this pixel size (applied after the
    /// crop). `source` stays pristine at its captured size; annotations and
    /// focus are stored in resized space, `crop` in pristine-source space.
    let resizedSize: CGSize?
    /// Background-removed alternate base (`cutout.png`) + whether it's shown.
    let cutout: CGImage?
    let showingCutout: Bool
    /// v9: solid fill behind the base image (nil = transparent).
    let backgroundFill: SerializableColor?
    let manifest: SealManifest
    let enhanced: CGImage?
    let showingEnhanced: Bool
    /// True when `enhanced.png` is present in the package but was NOT decoded
    /// (`decodeEnhanced: false`). Distinguishes "no enhanced copy exists, so
    /// Enhance must regenerate one" from "one exists, just decode it" — without
    /// this the editor would re-run the enhancer over an image it already has.
    let enhancedAvailableUndecoded: Bool
    /// PNG payloads for `.image` annotations, keyed by assetID (the part
    /// after "asset-" in the entry filename). Empty for packages written
    /// before image-overlay support (codec <v5).
    let imageAssets: [String: Data]
    /// 720px `thumbnail.png`, decoded up front so the canvas has something to
    /// draw while the real base is still being decoded off the main thread.
    /// nil for packages written before thumbnails, or if the entry is corrupt.
    var placeholder: CGImage? = nil
}

enum SealPackageIOError: Error {
    case pngEncodingFailed
    case missingEntry(String)
    case sourceDecodeFailed
    case compositeDecodeFailed
    case manifestDecodeFailed
    case writeFailed(URL, underlying: Error)
    case readFailed(URL, underlying: Error)
    /// The package is encrypted and the caller did not supply an unlocked identity.
    case packageLocked
}

private enum Entry {
    static let manifest = "manifest.json"
    static let source = "source.png"
    static let composite = "composite.png"
    static let annotations = "annotations.json"
    static let enhanced = "enhanced.png"
    static let thumbnail = "thumbnail.png"
    static let cutout = "cutout.png"
    /// Recomputable results — Live Text layout today, extraction and redaction
    /// detections next. See `DerivedSidecar`. Never decoded by
    /// `readSealPackage`: the callers that want it ask for it directly, so
    /// opening a capture does not pay for data only Live Text uses.
    static let derived = "derived.json"
}

private let iso8601: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

// MARK: - CEK resolution helper

/// Resolve the CEK for an existing locked package at `url`. Returns `(cek,
/// existingManifest)` so the caller can avoid a second header read.
/// Throws `.packageLocked` when the package is locked but no identity is
/// available.
// Not main-isolated: every operation here is thread-safe — FileManager reads,
// JSON decode, and pure-CryptoKit (Curve25519/HPKE) CEK unwrap. Kept callable
// off the main thread so background autosave never blocks the UI.
private func existingCEKAndManifest(
    at url: URL,
    crypto: SealPackageCryptoContext
) throws -> (cek: SymmetricKey, manifest: SealManifest?)? {
    guard SealPackageCrypter.isLocked(url) else { return nil }
    // Identity nil → locked and caller cannot authenticate → .packageLocked.
    guard let identity = crypto.identity else { throw SealPackageIOError.packageLocked }
    // Identity present but lock.json missing or corrupt → corruption, not a lock issue.
    guard let headerData = sealEntryData(LockHeader.filename, at: url),
          let header = try? JSONDecoder().decode(LockHeader.self, from: headerData)
    else { throw SealPackageIOError.readFailed(url, underlying: SealPackageIOError.manifestDecodeFailed) }
    let cek = try SealPackageCrypter.unwrapCEK(header, identity: identity)
    // Also open the existing manifest so the write path can preserve createdISO8601.
    let existingManifest: SealManifest? = {
        guard let raw = sealEntryData(Entry.manifest, at: url),
              let plain = try? SealedBlob.open(raw, with: cek)
        else { return nil }
        return try? SealManifest.decodeJSON(from: plain)
    }()
    return (cek, existingManifest)
}

/// Every entry of a `.seal`, whichever on-disk shape it has.
///
/// Containers are what the app writes; directory packages are the legacy
/// shape, still readable so a library opens normally before (and during) the
/// launch conversion. Nothing else in the codebase should care which is which.
func sealEntryMap(at url: URL) throws -> [String: Data] {
    if SealContainer.isContainer(url) {
        return try SealContainer.Reader(url: url).allEntries()
    }
    let bundle = try FileWrapper(url: url, options: [.immediate])
    guard let wrappers = bundle.fileWrappers else {
        throw SealPackageIOError.missingEntry(Entry.manifest)
    }
    return wrappers.compactMapValues { $0.regularFileContents }
}

/// One entry's bytes, or nil when the package doesn't carry it.
func sealEntryData(_ name: String, at url: URL) -> Data? {
    if SealContainer.isContainer(url) {
        return try? SealContainer.Reader(url: url).data(name)
    }
    return try? Data(contentsOf: url.appendingPathComponent(name))
}

// MARK: - Write

/// Write a `.seal` package at `url` as an `NSFileWrapper` directory bundle.
/// Overwrites any existing package at that URL atomically.
///
/// `source` is the immutable original capture (PNG-encoded into `source.png`).
/// `composite` is the rendered output (PNG-encoded into `composite.png`).
/// For a freshly-captured package with no annotations, callers pass the same
/// CGImage for both.
///
/// When `crypto.publicKey` is non-nil, all entries are sealed with a per-
/// package content key (codec v5). The function returns that CEK so the
/// metadata pipeline can reuse it without a round-trip decrypt. Returns `nil`
/// for plaintext (codec ≤v4) packages.
///
/// Not main-isolated: PNG encode (ImageIO), AES-GCM seal, and the atomic
/// FileWrapper write are all thread-safe, so background autosave can call this
/// off the main thread. The synchronous callers (capture, import, explicit
/// save) keep calling it from the main thread unchanged.
@discardableResult
func writeSealPackage(
    to url: URL,
    source: CGImage,
    composite: CGImage,
    annotations: [Annotation],
    crop: CGRect?,
    contentClip: CGRect? = nil,
    focus: CGRect? = nil,
    resizedSize: CGSize? = nil,
    cutout: CGImage? = nil,
    showingCutout: Bool = false,
    backgroundFill: SerializableColor? = nil,
    enhanced: CGImage? = nil,
    showingEnhanced: Bool = false,
    enhanceParams: EnhanceParams = .default,
    assets: [String: Data] = [:],
    captureKind: CaptureKind? = nil,
    sceneLayers: [SceneLayer]? = nil,
    crypto: SealPackageCryptoContext
) throws -> SymmetricKey? {
    let now = iso8601.string(from: Date())

    // ── Resolve CEK + existing manifest in ONE pass for locked packages ──
    // The CEK is needed both to open the existing manifest (for
    // createdISO8601 preservation) and to re-seal the new entries.
    var existingCEK: SymmetricKey?
    let existingManifest: SealManifest?

    if FileManager.default.fileExists(atPath: url.path) {
        if SealPackageCrypter.isLocked(url) {
            // Throws .packageLocked if identity is nil.
            let resolved = try existingCEKAndManifest(at: url, crypto: crypto)
            existingCEK = resolved?.cek
            existingManifest = resolved?.manifest
        } else {
            // Plaintext existing package: read its manifest entry. Missing
            // this read is silent and expensive — every re-save would drop
            // capture provenance, favourites, tags and title.
            let raw = sealEntryData(Entry.manifest, at: url)
            existingManifest = raw.flatMap { try? SealManifest.decodeJSON(from: $0) }
        }
    } else {
        existingManifest = nil
    }

    // Carry forward EVERY field the editor doesn't itself produce, so a
    // re-save / autosave never silently drops capture provenance (SP-B:
    // captureKind/captureMode/pageDomain), user workflow (SP-C: isFavorite/
    // status), the cached Extract Structured Data result (extraction), or
    // collection membership (collectionIDs). Brand-new captures have
    // `existingManifest == nil`, so these all resolve to nil → the manifest's
    // defaults.
    let manifest = SealManifest(
        version: SealManifest.currentVersion,
        createdISO8601: existingManifest?.createdISO8601 ?? now,
        modifiedISO8601: now,
        sourceSize: SealManifest.Size(width: source.width, height: source.height),
        sourceApp: existingManifest?.sourceApp,
        showingEnhanced: showingEnhanced,
        enhanceParams: enhanced != nil ? enhanceParams : nil,
        metadata: existingManifest?.metadata,
        ocrText: existingManifest?.ocrText,
        captureKind: captureKind ?? existingManifest?.captureKind,
        captureMode: existingManifest?.captureMode,
        pageDomain: existingManifest?.pageDomain,
        isFavorite: existingManifest?.isFavorite,
        status: existingManifest?.status,
        video: existingManifest?.video,
        extraction: existingManifest?.extraction,
        collectionIDs: existingManifest?.collectionIDs,
        sceneLayers: sceneLayers ?? existingManifest?.sceneLayers
    )
    // Scene forensics: a Live Capture losing its sceneLayers across a rewrite
    // is exactly the silent failure this trace exists to catch — an existing
    // package whose manifest couldn't be read/opened preserves NOTHING.
    if manifest.captureKind == .liveCapture || existingManifest?.captureKind == .liveCapture
        || sceneLayers != nil {
        let existed = FileManager.default.fileExists(atPath: url.path)
        SceneDiag.note("REWRITE \(url.lastPathComponent): existed=\(existed) "
            + "existingManifestReadable=\(existingManifest != nil) "
            + "sceneLayersParam=\(sceneLayers?.count.description ?? "nil") "
            + "existingSceneLayers=\(existingManifest?.sceneLayers?.count.description ?? "nil") "
            + "-> written=\(manifest.sceneLayers?.count.description ?? "nil") "
            + "annotations=\(annotations.count) assets=\(assets.count) locked=\(existingCEK != nil)")
    }
    let manifestData = try manifest.encodeJSON()
    let annotationsData = try encodeAnnotations(annotations, crop: crop, contentClip: contentClip,
                                                focus: focus,
                                                resizedSize: resizedSize,
                                                showingCutout: showingCutout && cutout != nil,
                                                backgroundFill: backgroundFill)
    let sourcePNG = try pngData(from: source)
    let compositePNG = try pngData(from: composite)
    // Hoist optional PNGs so we can put them in the entry map before sealing.
    let enhancedPNG: Data? = try enhanced.map { try pngData(from: $0) }
    let cutoutPNG: Data? = try cutout.map { try pngData(from: $0) }
    let thumb = downsampledCGImage(from: composite, maxPixel: captureThumbnailMaxPixel)
    let thumbPNG: Data? = (thumb !== composite) ? (try? pngData(from: thumb)) : nil

    // ── Assemble entry map ──
    var entryData: [String: Data] = [
        Entry.manifest: manifestData,
        Entry.source: sourcePNG,
        Entry.composite: compositePNG,
        Entry.annotations: annotationsData,
    ]
    if let enhancedPNG { entryData[Entry.enhanced] = enhancedPNG }
    if let cutoutPNG { entryData[Entry.cutout] = cutoutPNG }
    if let thumbPNG { entryData[Entry.thumbnail] = thumbPNG }

    // Image-overlay bitmaps: flat entries so they ride encryption and
    // the atomic FileWrapper write unchanged. Never pruned in v1.
    for (assetID, png) in assets {
        entryData["asset-\(assetID).png"] = png
    }

    // ── Carry `derived.json` forward ──
    //
    // The write below builds a FRESH directory wrapper from `entryData` and
    // replaces the package atomically, so anything absent here is deleted. The
    // sidecar is not produced by this function, which means without this an
    // ordinary autosave would silently wipe it.
    //
    // Read here but injected AFTER sealing, deliberately: these bytes are
    // already in whatever form the package uses — sealed under the CEK it keeps
    // using, or plaintext — so passing them through `sealEntries` would encrypt
    // them a second time and make them unopenable. Copying them verbatim also
    // keeps this off the hot path: no decrypt, no re-encrypt, on a function
    // that runs on every autosave.
    let carriedDerived = sealEntryData(Entry.derived, at: url)

    // ── codec v5: seal every entry + lock.json when encryption is active ──
    var usedCEK: SymmetricKey?
    if let publicKey = crypto.publicKey, let generation = crypto.generation {
        // Overwriting an existing locked package must reuse its CEK so the
        // metadata pipeline's key (and any cached key) stays valid.
        let sealed = try SealPackageCrypter.sealEntries(
            entryData, publicKey: publicKey, generation: generation, reusing: existingCEK)
        entryData = sealed.entries
        usedCEK = sealed.cek
    }

    // Injected post-seal — see the note where `carriedDerived` is read. Dropped
    // when the package is being re-keyed (a generation rotation leaves the old
    // bytes unopenable): the contents are derived by definition, so recomputing
    // beats carrying rubbish forward.
    if let carriedDerived, !(usedCEK != nil && existingCEK == nil) {
        entryData[Entry.derived] = carriedDerived
    }

    // A single-file container, not a directory bundle: macOS never consults a
    // third-party thumbnailer for `com.apple.package`, so a packaged capture
    // could not show its own picture in Finder. See `SealContainer`.
    //
    // Overwriting a legacy directory package leaves no directory behind —
    // `SealContainer.write` moves a temp file into place, and a same-named
    // directory would block that, so it is removed first. Only ever a
    // conversion in place: the entries being written were just read from it.
    if !SealContainer.isContainer(url) {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            try? FileManager.default.removeItem(at: url)
        }
    }
    do {
        try SealContainer.write(entries: entryData.map { ($0.key, $0.value) }, to: url)
    } catch {
        throw SealPackageIOError.writeFailed(url, underlying: error)
    }
    return usedCEK
}

// MARK: - Read

/// Read a `.seal` package and return its contents.
///
/// When the package carries a `lock.json` header (codec v5), every entry is
/// AES-GCM sealed. `crypto.identity` is required to unwrap the CEK; if it
/// is nil, throws `.packageLocked`. Plaintext (≤v4) packages are unaffected.
@MainActor
/// - Parameter decodeEnhanced: pass `false` to skip decoding `enhanced.png`.
///   It is 2x linear — four times the pixels — so on a machine with no Neural
///   Engine that decode dominates a capture switch, and it is wasted whenever
///   the enhanced base isn't the one being shown. The file is left untouched;
///   `enhancedAvailableUndecoded` reports that it is there to be decoded later.
func readSealPackage(
    at url: URL,
    crypto: SealPackageCryptoContext,
    decodeEnhanced: Bool = true
) throws -> SealPackageContents {
    // Both formats: containers are what we write now, directories are what a
    // library holds until the launch conversion has run over it.
    let wrappers: [String: Data]
    do {
        wrappers = try sealEntryMap(at: url)
    } catch {
        throw SealPackageIOError.readFailed(url, underlying: error)
    }

    // codec v5: a lock.json header means every entry is sealed with the
    // package CEK — reading requires the unlocked identity.
    var open: (Data) throws -> Data = { $0 }
    if let headerData = wrappers[LockHeader.filename] {
        guard let identity = crypto.identity else { throw SealPackageIOError.packageLocked }
        let header = try JSONDecoder().decode(LockHeader.self, from: headerData)
        let cek = try SealPackageCrypter.unwrapCEK(header, identity: identity)
        open = { try SealedBlob.open($0, with: cek) }
    }

    guard let rawManifest = wrappers[Entry.manifest] else {
        throw SealPackageIOError.missingEntry(Entry.manifest)
    }
    guard let rawSource = wrappers[Entry.source] else {
        throw SealPackageIOError.missingEntry(Entry.source)
    }
    guard let rawComposite = wrappers[Entry.composite] else {
        throw SealPackageIOError.missingEntry(Entry.composite)
    }
    guard let rawAnnotations = wrappers[Entry.annotations] else {
        throw SealPackageIOError.missingEntry(Entry.annotations)
    }

    let manifestData = try open(rawManifest)
    let sourceData = try open(rawSource)
    let compositeData = try open(rawComposite)
    let annotationsData = try open(rawAnnotations)

    let manifest: SealManifest
    do {
        manifest = try SealManifest.decodeJSON(from: manifestData)
    } catch {
        throw SealPackageIOError.manifestDecodeFailed
    }

    guard let source = decodeCGImageFromPNG(sourceData) else {
        throw SealPackageIOError.sourceDecodeFailed
    }

    guard let composite = decodeCGImageFromPNG(compositeData) else {
        throw SealPackageIOError.compositeDecodeFailed
    }

    let decodedAnnotations = try decodeAnnotations(from: annotationsData)

    let enhanced: CGImage?
    let enhancedAvailableUndecoded: Bool
    if let rawEnhanced = wrappers[Entry.enhanced] {
        enhanced = decodeEnhanced ? decodeCGImageFromPNG(try open(rawEnhanced)) : nil
        enhancedAvailableUndecoded = !decodeEnhanced
    } else {
        enhanced = nil
        enhancedAvailableUndecoded = false
    }
    let cutout: CGImage?
    if let rawCutout = wrappers[Entry.cutout] {
        cutout = decodeCGImageFromPNG(try open(rawCutout))
    } else {
        cutout = nil
    }

    // The 720px thumbnail, decoded EAGERLY (everything else here stays lazy).
    //
    // The canvas needs something to show during the ~45ms the real base spends
    // being decoded, and that decode is why switching to a capture stalls the
    // main thread — the strip scrolls on the same thread, so it hitches. This
    // entry is a separate, small PNG, so inflating it costs a few ms; a
    // reduced-size decode of `source.png` would NOT help, as PNG has no
    // subsampled decode and ImageIO must inflate the whole stream regardless.
    var placeholder: CGImage?
    if let rawThumb = wrappers[Entry.thumbnail],
       let thumbData = try? open(rawThumb),
       let thumbSource = CGImageSourceCreateWithData(thumbData as CFData, nil) {
        placeholder = CGImageSourceCreateImageAtIndex(thumbSource, 0, [
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    }

    // Collect image-overlay assets: entries whose name starts with "asset-"
    // and ends with ".png". The assetID is everything between those affixes.
    // Unreadable entries (decrypt failure, corrupt data) are skipped with an
    // error log so one bad asset never blocks the whole open.
    var imageAssets: [String: Data] = [:]
    for (name, raw) in wrappers {
        guard name.hasPrefix("asset-") && name.hasSuffix(".png") else { continue }
        let assetID = String(name.dropFirst("asset-".count).dropLast(".png".count))
        do {
            imageAssets[assetID] = try open(raw)
        } catch {
            os_log("sealio: skipping unreadable asset %{public}@ in %{public}@: %{public}@",
                   log: log, type: .error, name, url.lastPathComponent, String(describing: error))
        }
    }

    return SealPackageContents(
        source: source,
        composite: composite,
        annotations: decodedAnnotations.annotations,
        crop: decodedAnnotations.crop,
        contentClip: decodedAnnotations.contentClip,
        focus: decodedAnnotations.focus,
        resizedSize: decodedAnnotations.resizedSize,
        cutout: cutout,
        showingCutout: decodedAnnotations.showingCutout && cutout != nil,
        backgroundFill: decodedAnnotations.backgroundFill,
        manifest: manifest,
        enhanced: enhanced,
        showingEnhanced: manifest.showingEnhanced ?? false,
        enhancedAvailableUndecoded: enhancedAvailableUndecoded,
        imageAssets: imageAssets,
        placeholder: placeholder
    )
}

/// Scale `image` so its longest edge is at most `maxPixel`. Returns the SAME
/// object (identity-preserved) when no scaling is needed, so callers can skip
/// redundant encodes.
func downsampledCGImage(from image: CGImage, maxPixel: CGFloat) -> CGImage {
    let w = CGFloat(image.width), h = CGFloat(image.height)
    let scale = min(1, maxPixel / max(w, h))
    guard scale < 1 else { return image }
    let tw = max(1, Int(w * scale)), th = max(1, Int(h * scale))
    guard let ctx = CGContext(
        data: nil, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: tw, height: th))
    return ctx.makeImage() ?? image
}

// MARK: - Private helpers

private func pngData(from image: CGImage) throws -> Data {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
        data as CFMutableData,
        UTType.png.identifier as CFString,
        1, nil
    ) else {
        throw SealPackageIOError.pngEncodingFailed
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw SealPackageIOError.pngEncodingFailed
    }
    return data as Data
}

private func decodeCGImageFromPNG(_ data: Data) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

// MARK: - Derived sidecar

/// Read `derived.json` from a package, or nil when it is absent, unopenable, or
/// malformed.
///
/// Never throws. Everything in the sidecar is recomputable, so a corrupt or
/// unreadable one has exactly one correct outcome — behave as though it were
/// not there and compute again. Failing an editor open over a cache would be
/// the wrong trade by a wide margin.
func readDerivedSidecar(at url: URL, crypto: SealPackageCryptoContext) -> DerivedSidecar? {
    guard let raw = sealEntryData(Entry.derived, at: url) else { return nil }
    let plain: Data
    if SealPackageCrypter.isLocked(url) {
        guard let resolved = try? existingCEKAndManifest(at: url, crypto: crypto),
              let opened = try? SealedBlob.open(raw, with: resolved.cek)
        else { return nil }
        plain = opened
    } else {
        plain = raw
    }
    return try? DerivedSidecar.decode(plain)
}

/// Write `derived.json` into an existing package, sealed to match it.
///
/// Deliberately NOT a `writeSealPackage` call. That rewrites every entry,
/// re-encoding source, composite, thumbnail and any enhanced base — paying a
/// full PNG re-encode to record a cache would cost more than the recognition it
/// saves. This touches one file.
///
/// The package's modification date is restored afterwards.
/// `LibraryIndexStore.reconcile` compares stored row mtimes against disk, so
/// bumping it here would make every capture look edited and drag the library
/// through a needless re-index. It also keeps `DerivedAnchor` honest: the
/// anchor is the manifest's stamp, which this never touches.
func writeDerivedSidecar(_ sidecar: DerivedSidecar, into url: URL,
                         crypto: SealPackageCryptoContext) throws {
    var payload = sidecar.encoded()
    if SealPackageCrypter.isLocked(url) {
        guard let resolved = try existingCEKAndManifest(at: url, crypto: crypto)
        else { throw SealPackageIOError.packageLocked }
        payload = try SealedBlob.seal(payload, with: resolved.cek)
    }

    // Captured and restored through stat/utimensat rather than FileManager,
    // which truncates the fraction. `reconcile` allows a 1ms drift (mtimes
    // round-trip through REAL columns); losing up to a second sails past that
    // and puts us back to re-indexing the library on every sidecar write.
    var before = stat()
    let haveStat = stat(url.path, &before) == 0

    do {
        if SealContainer.isContainer(url) {
            // A TAIL entry: writing a Live Text cache rewrites the tail, never
            // the payload — the same reason the manifest lives there.
            try SealContainer.rewritingTail([Entry.derived: payload], in: url)
        } else {
            try payload.write(to: url.appendingPathComponent(Entry.derived), options: .atomic)
        }
    } catch {
        throw SealPackageIOError.writeFailed(url, underlying: error)
    }

    if haveStat {
        var times = [before.st_atimespec, before.st_mtimespec]
        _ = utimensat(AT_FDCWD, url.path, &times, 0)
    }
}

/// What a derived section must match to still be valid for this package.
///
/// The manifest's stamp rather than the package's file mtime — writing
/// `derived.json` changes the latter, so anchoring on it would invalidate every
/// section the instant it was written. Paired with `source.png`'s byte size,
/// because the stamp only has second resolution.
///
/// nil when the package cannot be read (missing, locked without an identity,
/// corrupt manifest) — callers treat that as "no valid cache" and recompute.
func derivedAnchor(for url: URL, crypto: SealPackageCryptoContext) -> DerivedAnchor? {
    guard let raw = sealEntryData(Entry.manifest, at: url) else { return nil }
    let plain: Data
    if SealPackageCrypter.isLocked(url) {
        guard let resolved = try? existingCEKAndManifest(at: url, crypto: crypto),
              let opened = try? SealedBlob.open(raw, with: resolved.cek) else { return nil }
        plain = opened
    } else {
        plain = raw
    }
    guard let manifest = try? SealManifest.decodeJSON(from: plain) else { return nil }
    // `source.png`'s size, from the container's directory when there is one —
    // no need to read the bytes to learn how many there are.
    let bytes: Int? = {
        if SealContainer.isContainer(url) {
            return (try? SealContainer.Reader(url: url))?.entry(Entry.source)
                .map { Int($0.size) }
        }
        return (try? FileManager.default.attributesOfItem(
            atPath: url.appendingPathComponent(Entry.source).path)[.size] as? Int) ?? nil
    }()
    return DerivedAnchor(modifiedISO8601: manifest.modifiedISO8601, sourceBytes: bytes ?? 0)
}
