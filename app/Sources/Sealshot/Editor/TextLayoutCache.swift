import CoreGraphics
import Foundation
import os.log

private let log = OSLog(subsystem: "com.seal-shot.sealshot", category: "ocr")

/// Live Text layouts, cached across capture switches for the life of the app.
///
/// The canvas already avoids re-recognizing while a capture stays open, but its
/// key is `ObjectIdentifier(displayBase)` — switch to another capture and back
/// and the reloaded image is a different object, so the layout is recomputed
/// from scratch. On a Mac without a Neural Engine that is ~10s of Vision work
/// for a result already produced minutes earlier.
///
/// Only the layout is cached, never the image, so entries are small (boxes and
/// strings) rather than bitmaps.
///
/// The manifest's `ocrText` cannot serve this: it stores text with no geometry,
/// and selection needs per-line boxes, per-character boxes and the tilt quad.
///
/// Backed by `TextLayoutStore`, which keeps the layout in the capture's own
/// package, so a miss here falls through to disk rather than to ten seconds of
/// Vision. This class is now the memory tier of the two.
@MainActor
final class TextLayoutCache {

    static let shared = TextLayoutCache()

    /// Small on purpose: a handful of recently-visited captures covers the
    /// back-and-forth this exists for, and layouts for text-heavy captures are
    /// not free.
    private let limit = 8
    private var entries: [(key: String, layout: RecognizedTextLayout)] = []

    /// Identifies the exact pixels a layout was computed from.
    ///
    /// Anchored on the manifest's stamp rather than the package's file mtime.
    /// mtime was right while this cache was memory-only, but the layout is
    /// written into the package now, and that write changes the mtime — so
    /// keying on it would invalidate every layout the instant it was stored.
    /// Only a real save moves the manifest stamp, which is exactly when a
    /// layout should go stale. Dimensions, base and crop cover the alternate
    /// bases, which are genuinely different pixels.
    ///
    /// nil when the package can't be read — an unsaved scratch canvas has no
    /// file to key on, and its pixels can change under the same identity.
    static func key(sourceURL: URL, baseSize: CGSize, showingEnhanced: Bool,
                    showingCutout: Bool, croppedRect: CGRect?) -> TextLayoutKey? {
        guard let anchor = derivedAnchor(for: sourceURL, crypto: SealPackageCryptoContext.current())
        else { return nil }
        let base: DerivedBase = showingCutout ? .cutout : (showingEnhanced ? .enhanced : .source)
        return TextLayoutKey(sourceURL: sourceURL, base: base, crop: croppedRect,
                             width: Int(baseSize.width), height: Int(baseSize.height),
                             anchor: anchor)
    }

    /// The layout for `key` — from memory, or from the capture's own package
    /// when this is the first time it has been asked for since launch.
    func layout(for key: TextLayoutKey) -> RecognizedTextLayout? {
        // The in-memory layer has to be bypassed too, or the second look at a
        // capture during a diagnostic session serves the layout the FIRST look
        // computed — and only one run ever gets traced.
        if OCRDiag.isEnabled { return nil }
        if let inMemory = memoryLayout(for: key.memoryKey) { return inMemory }
        guard let stored = TextLayoutStore.load(for: key, crypto: SealPackageCryptoContext.current())
        else { return nil }
        // Promote, so the second ask in a session skips the file read too.
        store(stored, for: key, persist: false)
        return stored
    }

    private func memoryLayout(for key: String) -> RecognizedTextLayout? {
        guard let index = entries.firstIndex(where: { $0.key == key }) else { return nil }
        // Refresh recency so a capture being revisited isn't evicted by the
        // ones visited in between.
        let entry = entries.remove(at: index)
        entries.append(entry)
        os_log("live text layout reused (%d lines)", log: log, type: .info,
               entry.layout.lines.count)
        return entry.layout
    }

    /// Remember `layout`, and write it into the capture's package so it is
    /// still there after a relaunch.
    ///
    /// `persist: false` is for a layout that just came OUT of the package —
    /// writing it straight back would be a pointless re-encode of bytes that
    /// are already on disk.
    func store(_ layout: RecognizedTextLayout, for key: TextLayoutKey, persist: Bool = true) {
        entries.removeAll { $0.key == key.memoryKey }
        entries.append((key.memoryKey, layout))
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
        guard persist else { return }
        TextLayoutStore.save(layout, for: key, crypto: SealPackageCryptoContext.current())
    }

    func removeAll() { entries.removeAll() }
}
