import AppKit
import ImageIO

/// Max pixel size (longest edge) for Library/strip thumbnails. 720px covers a
/// ~360pt card at 2x Retina; decoding at this size is roughly an order of
/// magnitude cheaper than a full Retina screenshot.
let captureThumbnailMaxPixel: CGFloat = 720

/// The bytes a capture's thumbnail is derived from: the package's
/// pre-rendered `thumbnail.png` when present (written at save time), else its
/// full `composite.png`. Plain `.png` captures are the file itself.
///
/// Bytes rather than a URL because an entry inside a container has no URL of
/// its own.
func captureThumbnailSourceData(for url: URL) -> Data? {
    guard url.pathExtension.lowercased() == "seal" else {
        return try? Data(contentsOf: url)
    }
    return sealEntryData("thumbnail.png", at: url) ?? sealEntryData("composite.png", at: url)
}

/// Full-resolution plaintext composite for Quick Look preview / drag export.
///
/// Deliberately NOT `enhanced.png`: that entry is the RAW enhanced base (full
/// source, no crop, no annotations), whereas `composite.png` is the actual
/// rendered composite — crop + annotations + enhance. Preferring the former
/// dropped the crop and annotations from previews and drag-out.
func previewCompositeSourceData(for url: URL) -> Data? {
    guard url.pathExtension.lowercased() == "seal" else {
        return try? Data(contentsOf: url)
    }
    return sealEntryData("composite.png", at: url)
}

/// Decode the image at `url` downsampled so its longest edge is at most
/// `maxPixel`. ImageIO downsamples DURING decode, so the full-resolution
/// bitmap is never materialized. Nil if the file is missing or not an image.
func downsampledImage(at url: URL, maxPixel: CGFloat) -> NSImage? {
    let srcOptions = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let source = CGImageSourceCreateWithURL(url as CFURL, srcOptions) else { return nil }
    return downsampledImage(from: source, maxPixel: maxPixel)
}

/// Same as `downsampledImage(at:)` but from in-memory bytes — used for
/// decrypted (sealed) thumbnails that never touch disk in plaintext.
func downsampledImage(from data: Data, maxPixel: CGFloat) -> NSImage? {
    let srcOptions = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let source = CGImageSourceCreateWithData(data as CFData, srcOptions) else { return nil }
    return downsampledImage(from: source, maxPixel: maxPixel)
}

private func downsampledImage(from source: CGImageSource, maxPixel: CGFloat) -> NSImage? {
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixel,
    ]
    guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
}

/// Decrypt the sealed thumbnail (or composite, as fallback) of a locked
/// package using `identity` to unwrap the per-package content key. Returns the
/// plaintext PNG bytes, or nil if the package can't be opened. Pure file I/O +
/// CryptoKit — safe to call off the main thread.
private func decryptedThumbnailPNG(for url: URL, identity: IdentityKey) -> Data? {
    guard let headerData = sealEntryData(LockHeader.filename, at: url),
          let header = try? JSONDecoder().decode(LockHeader.self, from: headerData),
          let cek = try? SealPackageCrypter.unwrapCEK(header, identity: identity)
    else { return nil }
    // Prefer the small pre-rendered thumbnail; fall back to the full composite
    // for captures saved without one (the image was already small enough).
    for entry in ["thumbnail.png", "composite.png"] {
        if let raw = sealEntryData(entry, at: url),
           let plain = try? SealedBlob.open(raw, with: cek) {
            return plain
        }
    }
    return nil
}

/// Load a display image for a capture URL, downsampled for thumbnail use.
///
/// Locked (encrypted) packages can't be decoded straight off disk — their PNG
/// bytes are sealed. When `crypto.identity` is present (the session is
/// unlocked), decrypt the sealed thumbnail and downsample it. When it's nil
/// (session locked), return nil (→ placeholder) without touching ImageIO,
/// which also avoids flooding the console with `CGImageSourceCreateThumbnail …
/// [-50]`.
func captureThumbnailImage(for url: URL, crypto: SealPackageCryptoContext) -> NSImage? {
    if SealPackageCrypter.isLocked(url) {
        guard let identity = crypto.identity,
              let png = decryptedThumbnailPNG(for: url, identity: identity)
        else { return nil }
        return downsampledImage(from: png, maxPixel: captureThumbnailMaxPixel)
    }
    guard let png = captureThumbnailSourceData(for: url) else { return nil }
    return downsampledImage(from: png, maxPixel: captureThumbnailMaxPixel)
}

/// Decrypt the full-resolution `composite.png` of a locked package for the
/// Quick Look preview / drag export (falling back to the small thumbnail).
/// Pure file I/O + CryptoKit — safe to call off the main thread.
///
/// Deliberately does NOT read `enhanced.png`: that is the raw enhanced base
/// (full source, no crop/annotations); `composite.png` is the rendered
/// composite with crop + annotations + enhance. See `previewCompositeSourceData`.
private func decryptedCompositePNG(for url: URL, identity: IdentityKey) -> Data? {
    guard let headerData = sealEntryData(LockHeader.filename, at: url),
          let header = try? JSONDecoder().decode(LockHeader.self, from: headerData),
          let cek = try? SealPackageCrypter.unwrapCEK(header, identity: identity)
    else { return nil }
    for entry in ["composite.png", "thumbnail.png"] {
        if let raw = sealEntryData(entry, at: url),
           let plain = try? SealedBlob.open(raw, with: cek) {
            return plain
        }
    }
    return nil
}

/// Full-resolution preview image for a capture, downsampled to `maxPixel`.
/// Unlike `readSealPackage` (which is `@MainActor` and decodes every full-size
/// entry), this decrypts just the composite bytes and downsamples during decode,
/// off the main thread — so the Quick Look preview never stalls the UI, even
/// when navigating large captures with the arrow keys. Returns nil when locked
/// without an identity, or on any decode failure.
func previewCompositeImage(for url: URL, crypto: SealPackageCryptoContext, maxPixel: CGFloat) -> NSImage? {
    if SealPackageCrypter.isLocked(url) {
        guard let identity = crypto.identity,
              let png = decryptedCompositePNG(for: url, identity: identity)
        else { return nil }
        return downsampledImage(from: png, maxPixel: maxPixel)
    }
    guard let png = previewCompositeSourceData(for: url) else { return nil }
    return downsampledImage(from: png, maxPixel: maxPixel)
}

/// FULL-resolution composite for drag-out / share export — decodes `composite.png`
/// at native size via `CGImageSourceCreateImageAtIndex`, NOT the thumbnail API.
/// `CGImageSourceCreateThumbnailAtIndex` (used by `previewCompositeImage`)
/// degrades/caps very large images, which quietly shrank multi-monitor Live
/// Capture scenes on drag-out; this matches Export-to-Image
/// (`readSealPackage` → `contents.composite`) so both produce the same file.
/// Nil when locked without an identity, or on any decode failure.
func fullCompositeImage(for url: URL, crypto: SealPackageCryptoContext) -> NSImage? {
    let data: Data?
    if SealPackageCrypter.isLocked(url) {
        guard let identity = crypto.identity else { return nil }
        data = decryptedCompositePNG(for: url, identity: identity)
    } else {
        data = previewCompositeSourceData(for: url)
    }
    guard let data,
          let source = CGImageSourceCreateWithData(
              data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
          let cg = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
}

private struct SourceSizeProbe: Decodable {
    struct S: Decodable { let width: Int; let height: Int }
    let sourceSize: S
}

/// Read one package entry's bytes off-main — plaintext for an unlocked package,
/// decrypted for a locked one (unwraps the per-package content key). Nil when
/// missing or unreadable. Pure file I/O + CryptoKit — safe off the main thread.
private func previewEntryData(url: URL, entry: String,
                              crypto: SealPackageCryptoContext) -> Data? {
    let entryURL = url.appendingPathComponent(entry)
    guard SealPackageCrypter.isLocked(url) else { return try? Data(contentsOf: entryURL) }
    guard let identity = crypto.identity,
          let headerData = try? Data(contentsOf: url.appendingPathComponent(LockHeader.filename)),
          let header = try? JSONDecoder().decode(LockHeader.self, from: headerData),
          let cek = try? SealPackageCrypter.unwrapCEK(header, identity: identity),
          let raw = try? Data(contentsOf: entryURL)
    else { return nil }
    return try? SealedBlob.open(raw, with: cek)
}

/// The focus geometry needed to draw the Quick Look focus indicator, read
/// off-main: the visible content size and the focus rect, both in the same 1×
/// coordinate space (visible = the destructive crop's size, else source.png's
/// pixel size). Nil when the capture has no focus rect. Safe off the main thread.
func previewFocusGeometry(for url: URL,
                          crypto: SealPackageCryptoContext) -> (visibleSize: CGSize, focus: CGRect)? {
    guard url.pathExtension.lowercased() == "seal",
          let annData = previewEntryData(url: url, entry: "annotations.json", crypto: crypto),
          let decoded = try? decodeAnnotations(from: annData),
          let focus = decoded.focus
    else { return nil }
    if let crop = decoded.crop { return (crop.size, focus) }
    guard let manData = previewEntryData(url: url, entry: "manifest.json", crypto: crypto),
          let probe = try? JSONDecoder().decode(SourceSizeProbe.self, from: manData)
    else { return nil }
    return (CGSize(width: probe.sourceSize.width, height: probe.sourceSize.height), focus)
}
