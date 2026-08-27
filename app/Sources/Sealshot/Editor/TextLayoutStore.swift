import CoreGraphics
import Foundation
import os.log

private let log = OSLog(subsystem: "com.seal-shot.sealshot", category: "ocr")

/// Everything that identifies the pixels a Live Text layout describes.
///
/// Carries the anchor rather than deriving one on demand: reading it costs a
/// manifest decode (plus a decrypt on a locked package), and both the memory
/// lookup and the disk lookup want the same answer, so it is resolved once at
/// the call site and passed down.
struct TextLayoutKey: Equatable {
    let sourceURL: URL
    let base: DerivedBase
    let crop: CGRect?
    let width: Int
    let height: Int
    let anchor: DerivedAnchor

    /// Which record inside the section this is — the pixels, without the
    /// "are they still current" part.
    var recordKey: String {
        let cropPart = crop.map { "\($0.origin.x),\($0.origin.y),\($0.width),\($0.height)" }
            ?? "full"
        return "\(base.rawValue)|\(width)x\(height)|\(cropPart)"
    }

    /// Memory-cache identity: the record plus the anchor, so a re-save of the
    /// capture cannot be served a layout computed from the old pixels.
    var memoryKey: String {
        "\(sourceURL.standardizedFileURL.path)|\(anchor.modifiedISO8601)"
            + "|\(anchor.sourceBytes)|\(recordKey)"
    }
}

/// Reads and writes Live Text layouts in the package's `derived.json`.
///
/// `TextLayoutCache` covers switching captures within a session; this is what
/// survives quitting. Without it the first use of Live Text or Find in Image
/// after a relaunch pays a full recognition pass — around ten seconds on a Mac
/// with no Neural Engine — to produce a result the app had already computed.
///
/// Never throws. A layout is recomputable by definition, so every failure here
/// has the same correct answer: behave as though nothing was stored.
@MainActor
enum TextLayoutStore {

    /// The layout for `key`, or nil when none is stored, it was computed from
    /// different pixels, or anything at all goes wrong reading it.
    static func load(for key: TextLayoutKey,
                     crypto: SealPackageCryptoContext) -> RecognizedTextLayout? {
        // Diagnostics need the recognizer to actually RUN. A stored layout is
        // only invalidated when the image changes, so without this the boxes
        // being investigated are re-drawn from the package and no stage ever
        // executes. See OCRDiag.
        if OCRDiag.isEnabled {
            OCRDiag.note("bypassing stored layout for \(key.sourceURL.lastPathComponent)")
            return nil
        }
        guard let sidecar = readDerivedSidecar(at: key.sourceURL, crypto: crypto),
              let blob = sidecar.section(TextLayoutSection.name),
              let records = try? decodeRecords(blob)
        else { return nil }

        guard let record = records.first(where: { $0.recordKey == key.recordKey }) else {
            return nil
        }
        // The anchor is what stops boxes from the pre-edit image being drawn
        // over the post-edit one.
        guard record.isValid(for: key.anchor) else { return nil }
        os_log("live text layout loaded from package (%d lines)", log: log, type: .info,
               record.layout.lines.count)
        return record.layout
    }

    /// Store `layout` for `key`, merging with whatever other bases are already
    /// recorded. Best-effort: a failure loses a cache entry, nothing more, so it
    /// must never surface to the caller.
    static func save(_ layout: RecognizedTextLayout, for key: TextLayoutKey,
                     crypto: SealPackageCryptoContext) {
        let record = TextLayoutSection(anchor: key.anchor, base: key.base, crop: key.crop,
                                       width: key.width, height: key.height, layout: layout)

        var sidecar = readDerivedSidecar(at: key.sourceURL, crypto: crypto) ?? DerivedSidecar()
        var records = sidecar.section(TextLayoutSection.name)
            .flatMap { try? decodeRecords($0) } ?? []

        // Replace this record; drop any that no longer describe the package, so
        // an edited capture doesn't accumulate dead layouts forever.
        records.removeAll { $0.recordKey == record.recordKey || !$0.isValid(for: key.anchor) }
        records.append(record)
        if records.count > maxRecords { records.removeFirst(records.count - maxRecords) }

        guard let blob = try? encodeRecords(records) else { return }
        sidecar.setSection(TextLayoutSection.name, data: blob)
        try? writeDerivedSidecar(sidecar, into: key.sourceURL, crypto: crypto)
    }

    /// One per base, and there are only three of them.
    private static let maxRecords = 3

    // The section holds an ARRAY of records — the source, enhanced and cutout
    // bases are different pixels and each needs its own. Encoded as a JSON array
    // of the per-record blobs so `TextLayoutSection` stays the single place that
    // knows the compact geometry format.
    private static func decodeRecords(_ data: Data) throws -> [TextLayoutSection] {
        try JSONDecoder().decode([Data].self, from: data).compactMap {
            try? TextLayoutSection.decode($0)
        }
    }

    private static func encodeRecords(_ records: [TextLayoutSection]) throws -> Data {
        try JSONEncoder().encode(records.map { $0.encoded() })
    }
}
