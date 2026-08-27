import Vision
import CoreGraphics
import CoreImage
import os.log

private let ocrUpscaleContext = CIContext(options: [.useSoftwareRenderer: false])

private let log = OSLog(subsystem: "com.seal-shot.sealshot", category: "ocr")

/// On-device text recognition. Wraps `VNRecognizeTextRequest` and converts
/// observations into a Vision-free `RecognizedTextLayout` in normalized
/// [0,1], top-left-origin space.
///
/// The Vision work runs off the main actor in a detached task and is
/// cooperatively cancellable (mirrors `ImageEnhancer`): cancelling the
/// awaiting task throws `CancellationError`.
@MainActor
final class TextRecognizer {

    func recognize(_ image: CGImage,
                   policy: RefinementPolicy = .full) async throws -> RecognizedTextLayout {
        let limits = RefinementLimits.resolve(policy, on: .current)
        // Log every request, not just completions. Consumers of one capture are
        // hard to tell apart from completion lines alone — and a pass that is
        // cancelled or never starts leaves no completion line at all, which is
        // exactly the ambiguity that made "did Live Text run?" unanswerable
        // from the logs.
        os_log("OCR request %dx%d policy=%{public}@", log: log, type: .info,
               image.width, image.height, policy == .full ? "full" : "budgeted")
        // Background recognition must not compete with a pass the user is
        // waiting on. A capture's metadata OCR and the editor's Live Text OCR
        // routinely overlap (the field log showed three concurrent passes over
        // the same pixels, each ~3x slower than it would have been alone), and
        // at equal priority the OS has no reason to favour the visible one.
        let priority: TaskPriority = policy == .budgeted ? .utility : .userInitiated
        // A fresh capture is recognized TWICE over the same CGImage: once by
        // the metadata pipeline and once by the editor's Live Text overlay.
        // They are handed the identical instance (`RegionCapturer` passes
        // `raw.image` to both `MetadataCoordinator.start(source:)` and the
        // `CaptureResult` that `EditorController.present` turns into
        // `EditorState.sourceImage`), and the base pass — tiling, dedup,
        // stitching, column repair — does not depend on the refinement policy.
        // On the measured Intel machine that base is ~7s of a ~10.6s pass, so
        // the second consumer reuses it and pays only for its own refinement.
        // Awaited separately from refinement so a second consumer can JOIN this
        // computation while it runs, not merely reuse it once it has finished.
        let base = try await OCRBaseCache.shared.base(for: image, priority: priority) { img, prio in
            Task.detached(priority: prio) { () throws -> OCRBase in
                try Task.checkCancellation()
                return try recognizeBase(img)
            }
        }
        // Refinement is per-caller: whoever joined still gets exactly the
        // policy they asked for, so sharing never downgrades a `.full` read.
        let task = Task.detached(priority: priority) { () throws -> RecognizedTextLayout in
            try Task.checkCancellation()
            return try refineAndOrder(base, source: image, refinement: limits)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Cheap "does this image contain ANY readable text?" probe.
    ///
    /// Deliberately not `recognize(_:)`. Callers that need one bit were paying
    /// for the whole pipeline — tiling plus up to 80 refine requests — which on
    /// a Mac with no Neural Engine measured **~28 seconds to answer a boolean**
    /// (field log: 3360x1700, 6 tiles). A single `.fast` pass answers the same
    /// question in ~60ms, and `.fast` is not worse at *presence*: on the
    /// benchmark fixture it found 41 lines where `.accurate` found 40. It reads
    /// those lines less accurately, which is why it is confined to this
    /// yes/no probe and never used for text anyone will read.
    func containsText(_ image: CGImage) async -> Bool {
        let task = Task.detached(priority: .userInitiated) { () -> Bool in
            guard !Task.isCancelled else { return false }
            return probeForAnyText(image)
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

/// One `.fast`, whole-image Vision pass — no tiling, no refinement, no
/// upscale. Recognition options otherwise mirror `recognizeLines` so the same
/// text qualifies (notably `minimumTextHeight`, which keeps small UI text in
/// scope; a probe that missed it would wrongly report "no text here").
private func probeForAnyText(_ image: CGImage) -> Bool {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .fast
    request.usesLanguageCorrection = false
    request.automaticallyDetectsLanguage = true
    request.recognitionLanguages = ["en-US"]
    request.minimumTextHeight = 0.008
    guard (try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])) != nil
    else { return false }
    return ((request.results ?? []) as [VNRecognizedTextObservation]).contains { obs in
        !(obs.topCandidates(1).first?.string.isEmpty ?? true)
    }
}

/// How much of the low-confidence refine pass a recognition run may spend.
///
/// This is a per-CALL choice, deliberately not a global inside the recognizer:
/// `TextRecognizer` is shared by ten call sites and only two of them (the
/// capture-time metadata pipeline and the library backfill) run without a user
/// waiting. The other eight are Live Text, Find in Image, copy-text, the AI
/// text actions, video summaries and — most importantly — Smart Redaction,
/// whose `SensitiveTextRules` match Luhn-checked card numbers and validated
/// SSNs against this text. One misread digit there means a card is not
/// detected and therefore not redacted, so those paths must never be trimmed
/// to save time. `.full` is the default so a new call site is safe by
/// construction; opting into `.budgeted` has to be deliberate.
enum RefinementPolicy {
    /// Refine every low-confidence line, both crop variants. Byte-for-byte the
    /// behavior every call site had before budgeting existed.
    case full
    /// Refine only what this machine can afford — for automatic, background
    /// work that nobody is waiting on.
    case budgeted
}

/// Coarse recognition-cost class of the machine. Intel Macs have no Neural
/// Engine, so Vision's `.accurate` model runs on CPU/GPU and each request
/// costs ~120ms versus ~14ms on an M4 (measured — see `scripts/ocr-bench/`).
/// The refine pass issues one request per weak line, so the same line count
/// costs an order of magnitude more here.
///
/// Compile-time arch is enough and, unusually for a hardware gate, will not
/// rot: no new Intel Macs will ship, and existing ones are frozen on macOS 15
/// so they will never get faster. It matches the existing `#if arch(arm64)`
/// gate in `RedactionEngineLoader`.
enum OCRPerformanceClass {
    case neuralEngine
    case cpuOnly

    #if arch(arm64)
    static let current: OCRPerformanceClass = .neuralEngine
    #else
    static let current: OCRPerformanceClass = .cpuOnly
    #endif
}

/// Concrete caps handed to the refine pass. Resolved on the main actor and
/// passed by value into the detached recognition task, so nothing reads
/// mutable global state off-actor.
struct RefinementLimits: Equatable {
    let maxLines: Int
    /// Whether to also re-read a SHARPENED copy of each crop. Sharpening wins
    /// on some blurry glyphs but can itself close a "6" into an "8", so it is
    /// pooled as a second candidate rather than trusted alone — which costs a
    /// second Vision request per line, i.e. double the pass.
    let useSharpenedVariant: Bool

    /// Pure so the policy matrix is testable without touching `.current`.
    static func resolve(_ policy: RefinementPolicy,
                        on machine: OCRPerformanceClass) -> RefinementLimits {
        switch (policy, machine) {
        case (.full, _):
            return RefinementLimits(maxLines: refineMaxLines, useSharpenedVariant: true)
        case (.budgeted, .neuralEngine):
            // A Neural Engine absorbs the line count; only the second variant
            // is dropped, halving the pass for ~1 correction per 20 attempts.
            return RefinementLimits(maxLines: refineMaxLines, useSharpenedVariant: false)
        case (.budgeted, .cpuOnly):
            return RefinementLimits(maxLines: refineMaxLinesWithoutNeuralEngine,
                                    useSharpenedVariant: false)
        }
    }
}

/// Free function (no actor isolation) so it runs on the detached task.
private func recognizeBase(_ image: CGImage) throws -> OCRBase {
    let started = ContinuousClock.now
    let W = CGFloat(image.width), H = CGFloat(image.height)
    let tiles = ocrTiles(width: W, height: H)
    OCRDiag.pass(String(format: "%.0fx%.0f, %d tiles", W, H, tiles.count))

    // Each element is a recognized line paired with its Vision confidence; kept
    // together so the low-confidence refine pass stays index-aligned after merge.
    var items: [(line: RecognizedLine, conf: Float)]

    if tiles.isEmpty {
        // Small image: one whole-image pass. Upscaling helps small/isolated text
        // and box coords are normalized so no remapping is needed.
        items = recognizeLines(in: upscaledForOCR(image))
    } else {
        // Large/dense image: a single Vision pass downscales the whole image to a
        // fixed internal resolution, so dense small text falls below it and never
        // gets proposed (empirically it plateaus regardless of input size). Run
        // recognition on overlapping tiles instead — each tile is within Vision's
        // effective resolution, so its text stays sharp — then map every line
        // back to full-image coordinates and de-dup lines caught in tile overlaps.
        var merged: [(line: RecognizedLine, conf: Float)] = []
        OCRDiag.tiles(tiles, imageW: W, imageH: H)
        for tile in tiles {
            try Task.checkCancellation()
            guard let crop = image.cropping(to: tile) else { continue }
            for (line, conf) in recognizeLines(in: crop) {
                merged.append((transformLine(line, tile: tile, imageW: W, imageH: H), conf))
            }
        }
        OCRDiag.stage("tiles-merged", merged)
        // De-dup identical reads from tile overlaps; absorb seam-TRUNCATED
        // fragments (partial duplicates dedup can't catch — their texts differ
        // at the cut, and their edges feed aligned false evidence to the
        // column-gutter voter); then stitch the fragments a line was split
        // into (titles by height, body text by seam-anchored overlap).
        let seams = tileSeams(tiles, imageW: W)
        OCRDiag.note("seams \(seams.map { String(format: "%.3f", $0) }.joined(separator: ","))")
        // Stepwise so a lost line is attributable to ONE stage rather than to
        // the composed expression as a whole.
        let deduped = dedupLines(merged)
        OCRDiag.stage("after-dedup", deduped)
        let absorbedItems = absorbSeamFragments(deduped, seams: seams)
        OCRDiag.stage("after-seam-absorb", absorbedItems)
        items = stitchRowFragments(absorbedItems, seams: seams)
        OCRDiag.stage("after-row-stitch", items)
    }

    // Repair dense-table cross-column reads (Vision merges two tightly-spaced
    // cells into one line — its own behavior, made frequent by tile crops that
    // straddle a column boundary). Gutters are voted from the correctly-read
    // rows' line boxes; spanning lines are dropped when redundant or re-read
    // column-by-column. Runs on both the tiled and single-pass paths.
    items = repairColumnSpanningReads(items, source: image,
                                      seams: tiles.isEmpty ? [] : tileSeams(tiles, imageW: W))
    OCRDiag.stage("after-column-repair", items)

    let elapsed = ContinuousClock.now - started
    let baseMs = Double(elapsed.components.seconds) * 1000
        + Double(elapsed.components.attoseconds) / 1.0e15
    os_log("OCR base %d lines (%dx%d, %d tiles) in %.0fms", log: log,
           type: baseMs > 2000 ? .error : .info,
           items.count, image.width, image.height, tiles.count, baseMs)
    return OCRBase(lines: items.map(\.line), confidences: items.map(\.conf),
                   tileCount: tiles.count)
}

/// The policy-INDEPENDENT result of recognition: every line pass 1 found, with
/// the Vision confidence that decides whether refinement will revisit it.
///
/// Split out so it can be shared. Tiling is the expensive half (~7s of a
/// ~10.6s pass on the measured Intel machine) and produces the same answer no
/// matter which `RefinementPolicy` the caller wants, so two consumers of one
/// capture compute it once between them and each still applies its own
/// refinement. Arrays stay index-aligned: `confidences[i]` belongs to
/// `lines[i]`.
struct OCRBase {
    let lines: [RecognizedLine]
    let confidences: [Float]
    let tileCount: Int
}

/// Apply `refinement` to a base result and put the lines in reading order.
/// Cheap relative to `recognizeBase`, and the only part that varies by policy.
private func refineAndOrder(_ base: OCRBase, source image: CGImage,
                            refinement: RefinementLimits) throws -> RecognizedTextLayout {
    let started = ContinuousClock.now
    var lines = base.lines
    let confidences = base.confidences

    // Second pass: re-OCR low-confidence lines from a high-resolution crop. On a
    // clean screenshot every line is ~0.99 confidence, so nothing re-runs; on a
    // photographed label (small, blurry, glare) the weak lines get a much larger
    // sharpened crop where Vision can tell a "6" from an "8". The pass is purely
    // corrective — it only swaps in a strictly-more-confident read. Runs before
    // the sort so `lines` and `confidences` stay index-aligned.
    try refineLowConfidenceLines(&lines, confidences: confidences, source: image,
                                 limits: refinement)

    // Reading order: rows top-first, then left-to-right within a row. Snap the
    // top edge to a 1%-of-image-height grid so lines on the same visual row
    // share a key — this keeps the comparator a valid strict-weak ordering
    // (a raw `abs(...) < tolerance` band is non-transitive → undefined sort).
    func rowKey(_ r: CGRect) -> CGFloat { (r.minY / 0.01).rounded() * 0.01 }
    lines.sort { a, b in
        let ka = rowKey(a.box), kb = rowKey(b.box)
        return ka != kb ? ka < kb : a.box.minX < b.box.minX
    }
    let elapsed = ContinuousClock.now - started
    let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1.0e15
    // `.accurate` Vision recognition is Neural-Engine-accelerated on Apple
    // Silicon; Intel Macs run the same work on CPU/GPU only, which is why
    // captures were taking 15-37s there. Escalate to `.error` past a threshold
    // no normal capture should hit, so it's easy to spot in Console or the
    // feedback diagnostics export without Instruments. `refine` here is the
    // per-policy tail only — the shared base is timed by `recognizeBase`, so a
    // reused base shows up as a small number next to a large one.
    os_log("OCR recognized %d lines (%dx%d, %d tiles), refine %.0fms (cap %d)", log: log,
           type: ms > 2000 ? .error : .info,
           lines.count, image.width, image.height, base.tileCount, ms, refinement.maxLines)
    return RecognizedTextLayout(lines: lines)
}

/// Vision's language auto-detection occasionally reads an isolated ASCII line
/// (a phone number) as CJK, emitting fullwidth punctuation for characters that
/// are plain ASCII on screen — `(555) 210-3350` → `［555）210・3350`
/// (corpus-verified). When a line contains no actual CJK letters, fold the
/// fullwidth forms back to ASCII: the screen content IS ASCII, so this corrects
/// the read. Lines with real CJK text are left untouched. Scalar-count is
/// preserved (fullwidth forms fold 1:1), so per-character boxes stay aligned.
func foldStrayFullwidth(_ s: String) -> String {
    // Fast path: nothing beyond the Basic Latin-ish range → no fold needed.
    guard s.unicodeScalars.contains(where: { $0.value >= 0x3000 }) else { return s }
    let hasCJKLetter = s.unicodeScalars.contains { scalar in
        let v = scalar.value
        return (0x4E00...0x9FFF).contains(v)        // CJK ideographs
            || (0x3040...0x309F).contains(v)        // hiragana
            || (0x30A0...0x30FA).contains(v)        // katakana letters (excl. ・)
            || (0x31F0...0x31FF).contains(v)        // katakana phonetic extensions
            || (0xAC00...0xD7AF).contains(v)        // hangul
    }
    guard !hasCJKLetter else { return s }
    var out = s.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? s
    // The transform leaves the katakana middle dot as its HALFWIDTH form
    // (U+FF65); on an ASCII line it is a misread separator — fold to hyphen.
    out = out.replacingOccurrences(of: "\u{FF65}", with: "-")
    return out
}

/// Recognize `image` in one Vision pass and build lines in the image's own
/// normalized [0,1] top-left space. Shared by the single-pass and per-tile
/// paths (a tile's lines are later mapped to full-image coords).
private func recognizeLines(in image: CGImage) -> [(line: RecognizedLine, conf: Float)] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    // Screenshots are full of numbers, codes and IDs. Language correction is
    // tuned for prose and tends to drop or garble short numeric tokens (a lone
    // "5" or "24"), so disable it for more faithful raw text.
    request.usesLanguageCorrection = false
    // Without this, Vision assumes en-US and force-reads non-Latin scripts
    // (CJK, Cyrillic, …) as Latin — producing replacement-symbol garbage.
    // The explicit language list is the detector's PRIOR: without it, an
    // isolated Latin line (a phone number) can be mis-detected as CJK and
    // come back as full-width punctuation (corpus-verified).
    request.automaticallyDetectsLanguage = true
    request.recognitionLanguages = ["en-US"]
    // The default minimum (~1/32 of image height) skips small UI text such as
    // single/two-digit values; lower it so they're recognized too. Relative to
    // the recognized image, so a tile's shorter height means a smaller absolute
    // floor — another reason tiling recovers small rows.
    request.minimumTextHeight = 0.008
    guard (try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])) != nil
    else { return [] }
    let observations = (request.results ?? []) as [VNRecognizedTextObservation]

    var out: [(line: RecognizedLine, conf: Float)] = []
    for obs in observations {
        guard let candidate = obs.topCandidates(1).first else { continue }
        let string = foldStrayFullwidth(candidate.string)
        guard !string.isEmpty else { continue }

        // Character boxes use validated Vision token geometry, subdividing only
        // within each token. Asking Vision for every individual character is
        // unreliable, while dividing the WHOLE line accumulates severe drift on
        // proportional text ("FORGEROCK AM STUDY" placed AM too far left).
        // Invalid/missing token boxes fall back to the robust whole-line model.
        let lineBox = flipY(obs.boundingBox)
        // The tilt-following outline: Vision's rectangle-observation corners,
        // flipped from bottom-left to top-left origin. `boundingBox` (above) is
        // their axis-aligned hull and stays the basis for hit-testing.
        // Tighten vertically so the outline hugs the text and adjacent close
        // lines don't visually merge; the selection highlight derives from this
        // same quad, so the two stay consistent.
        let quad = TextQuad.fromVisionCorners(topLeft: obs.topLeft, topRight: obs.topRight,
                                              bottomLeft: obs.bottomLeft, bottomRight: obs.bottomRight)
            .insetVertically(by: lineQuadVerticalInset)
        let charBoxes = tokenAwareCharacterBoxes(candidate: candidate,
                                                  displayText: string,
                                                  lineBox: lineBox)

        out.append((RecognizedLine(text: string, box: lineBox, charBoxes: charBoxes, quad: quad),
                    candidate.confidence))
    }
    return out
}

// MARK: - Tiling

/// Longest side above which a single Vision pass can't resolve dense text, so we
/// switch to tiled recognition.
private let ocrTileThreshold: CGFloat = 2000
/// Target tile side in source pixels — sized to stay within Vision's effective
/// working resolution so tile text isn't downscaled.
private let ocrTileTarget: CGFloat = 1600
/// Tile overlap in source pixels. Must comfortably exceed a typical line's
/// width/height so a line straddling a seam is fully contained by at least one
/// tile (otherwise it splits into two partial reads). Even tile distribution
/// below keeps the actual overlap ≥ this.
private let ocrTileOverlap: CGFloat = 320

/// Overlapping tile rects (source-pixel, top-left origin) covering a WxH image,
/// or an empty array when the image is small enough for a single whole-image
/// pass. Tiles are distributed evenly so every one is full-size and the last
/// ends exactly at the edge (no thin remainder tiles).
private func ocrTiles(width w: CGFloat, height h: CGFloat) -> [CGRect] {
    guard max(w, h) > ocrTileThreshold else { return [] }
    func starts(_ dim: CGFloat) -> [CGFloat] {
        if dim <= ocrTileTarget { return [0] }
        let step = ocrTileTarget - ocrTileOverlap
        let count = Int(ceil((dim - ocrTileTarget) / step)) + 1
        let last = dim - ocrTileTarget
        return (0..<count).map { last * CGFloat($0) / CGFloat(max(1, count - 1)) }
    }
    let xs = starts(w), ys = starts(h)
    var rects: [CGRect] = []
    for y in ys {
        for x in xs {
            rects.append(CGRect(x: x, y: y,
                                width: min(ocrTileTarget, w - x),
                                height: min(ocrTileTarget, h - y)))
        }
    }
    return rects
}

/// Map a line from a tile's normalized [0,1] top-left space into the full
/// image's normalized [0,1] top-left space. `tile` is the tile's source-pixel
/// rect; both spaces are top-left origin so this is a plain affine (no flip).
private func transformLine(_ line: RecognizedLine, tile: CGRect,
                           imageW: CGFloat, imageH: CGFloat) -> RecognizedLine {
    func mapRect(_ r: CGRect) -> CGRect {
        CGRect(x: (tile.minX + r.minX * tile.width) / imageW,
               y: (tile.minY + r.minY * tile.height) / imageH,
               width: r.width * tile.width / imageW,
               height: r.height * tile.height / imageH)
    }
    func mapPoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (tile.minX + p.x * tile.width) / imageW,
                y: (tile.minY + p.y * tile.height) / imageH)
    }
    let quad = line.quad.map {
        TextQuad(topLeft: mapPoint($0.topLeft), topRight: mapPoint($0.topRight),
                 bottomRight: mapPoint($0.bottomRight), bottomLeft: mapPoint($0.bottomLeft))
    }
    return RecognizedLine(text: line.text, box: mapRect(line.box),
                          charBoxes: line.charBoxes.map(mapRect), quad: quad)
}

/// Drop duplicate lines produced where tiles overlap: two lines are the same
/// read when their boxes overlap heavily AND their text matches (near-identical,
/// tolerating minor per-tile OCR variance). Keeps the higher-confidence copy.
private func dedupLines(_ items: [(line: RecognizedLine, conf: Float)]) -> [(line: RecognizedLine, conf: Float)] {
    let sorted = items.sorted { $0.conf > $1.conf }
    var kept: [(line: RecognizedLine, conf: Float)] = []
    for item in sorted {
        let dup = kept.contains { k in
            boxIoU(k.line.box, item.line.box) > 0.5 && textsSimilar(k.line.text, item.line.text)
        }
        if !dup { kept.append(item) }
    }
    return kept
}

// MARK: - Tile-seam fragment absorption

/// Tolerance (normalized x) for matching a fragment's cut edge to a tile seam
/// and its outer edge to the fuller read's edge. Generous because the box
/// edge sits at the last recognized glyph, slightly inside the tile edge.
private let seamEdgeTolerance: CGFloat = 0.008

/// Interior vertical tile edges in normalized x — where seam-truncated
/// fragments start or end. Image borders are excluded (nothing is cut there).
private func tileSeams(_ tiles: [CGRect], imageW W: CGFloat) -> [CGFloat] {
    var xs = Set<CGFloat>()
    for tile in tiles {
        if tile.minX > 0.5 { xs.insert(tile.minX / W) }
        if tile.maxX < W - 0.5 { xs.insert(tile.maxX / W) }
    }
    return xs.sorted()
}

/// Drop tile-seam TRUNCATED fragments in favor of the fuller read of the same
/// line. A tile whose edge cuts through a line still reads the part it can
/// see, while the neighbouring tile (overlap) reads the whole line; the two
/// TEXTS differ at the cut (often with a garbled glyph), so `dedupLines`
/// keeps both. The leftovers pollute the layout with overlapping boxes and —
/// worse — their edges align at the same seam x row after row, voting false
/// column gutters and falsely "covering" full reads in the repair pass.
///
/// A line is absorbed only when ALL hold, so a real cell read is never
/// mistaken for a fragment (a merged cross-column read also contains its
/// cells' text and boxes, but a cell's interior edge sits at a column
/// gutter, not a tile seam):
///   • same visual row and x-span contained in the fuller line's span,
///   • exactly one edge shared with the fuller line (it IS that line's
///     start or end),
///   • the other (cut) edge lies at a tile seam,
///   • its text core (2 chars trimmed from each end — the seam garbles the
///     cut glyph) appears verbatim in the fuller line's text.
func absorbSeamFragments(_ items: [(line: RecognizedLine, conf: Float)],
                         seams: [CGFloat]) -> [(line: RecognizedLine, conf: Float)] {
    guard !seams.isEmpty, items.count > 1 else { return items }
    var absorbed = Set<Int>()
    for i in items.indices {
        let a = items[i].line
        guard a.text.count >= 6 else { continue }
        let core = String(a.text.dropFirst(2).dropLast(2))
        guard core.count >= 3 else { continue }
        for j in items.indices where j != i && !absorbed.contains(j) {
            let b = items[j].line
            guard b.box.width > a.box.width else { continue }
            let vOverlap = min(a.box.maxY, b.box.maxY) - max(a.box.minY, b.box.minY)
            guard vOverlap > 0.5 * min(a.box.height, b.box.height) else { continue }
            guard a.box.minX >= b.box.minX - seamEdgeTolerance,
                  a.box.maxX <= b.box.maxX + seamEdgeTolerance else { continue }
            let sharesStart = abs(a.box.minX - b.box.minX) <= seamEdgeTolerance
            let sharesEnd = abs(a.box.maxX - b.box.maxX) <= seamEdgeTolerance
            let cutEdge: CGFloat
            if sharesStart && !sharesEnd { cutEdge = a.box.maxX }
            else if sharesEnd && !sharesStart { cutEdge = a.box.minX }
            else { continue }
            guard seams.contains(where: { abs($0 - cutEdge) <= seamEdgeTolerance }),
                  b.text.contains(core) else { continue }
            absorbed.insert(i)
            break
        }
    }
    guard !absorbed.isEmpty else { return items }
    os_log("absorbed %d tile-seam fragments", log: log, type: .info, absorbed.count)
    return items.indices.filter { !absorbed.contains($0) }.map { items[$0] }
}

// MARK: - Cross-tile fragment stitching (Non-Max Merging for text lines)

/// Stitch back together a wide line (typically a title/heading) that a tile seam
/// split into pieces. `dedupLines` removes *identical* overlapping reads; this
/// handles the *partial* reads it keeps.
///
/// Text-level stitching (matching one fragment's tail to the next's head) is
/// unreliable because tile seams cut through glyphs and the two tiles misread the
/// cut ("…Foundat" vs "indation"). So we group by GEOMETRY only:
///   • same visual row — boxes overlap vertically by >60% of the shorter (a
///     stacked/wrapped line barely overlaps vertically),
///   • a tile seam — boxes overlap horizontally (distinct columns are separated
///     by whitespace and never overlap in X).
/// Clusters are transitive (A–B–C fold into one). Singletons pass through
/// untouched, so ordinary lines are unaffected.
///
/// A cluster is then rebuilt WORD by word from the reads the tiles already
/// produced — see `mergeRowFragments`, which also records why re-OCR'ing the
/// merged region (the previous approach) could silently lose text.
private func stitchRowFragments(_ items: [(line: RecognizedLine, conf: Float)],
                                seams: [CGFloat] = []) -> [(line: RecognizedLine, conf: Float)] {
    let n = items.count
    guard n > 1 else { return items }
    // Union-find over same-row, horizontally-overlapping fragments.
    var parent = Array(0..<n)
    func find(_ a: Int) -> Int {
        var r = a
        while parent[r] != r { parent[r] = parent[parent[r]]; r = parent[r] }
        return r
    }
    for i in 0..<n {
        for j in (i + 1)..<n where sameLineFragments(items[i].line.box, items[j].line.box,
                                                     seams: seams) {
            parent[find(i)] = find(j)
        }
    }
    var groups: [Int: [Int]] = [:]
    for i in 0..<n { groups[find(i), default: []].append(i) }

    var out: [(line: RecognizedLine, conf: Float)] = []
    for idxs in groups.values {
        guard idxs.count > 1 else { out.append(items[idxs[0]]); continue }
        let cluster = idxs.map { items[$0] }
        if let merged = mergeRowFragments(cluster) {
            out.append(merged)
        } else {
            // Only reachable when a fragment's char boxes are out of step with
            // its text, so there is no trustworthy word geometry to merge on.
            // Keep every fragment: overlapping duplicates read worse than one
            // clean line, but they are not MISSING text, which is the failure
            // this whole stage exists to avoid.
            out.append(contentsOf: cluster)
        }
    }
    return out
}

/// Only stitch LARGE text. The bug is oversized titles/headings (tall boxes)
/// that a tile splits; small dense text (packed tables) is a separate problem,
/// and there tile fragments routinely span cell boundaries — grouping them would
/// fuse distinct columns. Confining the fix to tall lines keeps dense tables
/// untouched. In normalized image height: ~2% ≈ a heading, body text is <1.5%.
private let minStitchLineHeight: CGFloat = 0.02

/// Two fragments belong to the same line: their boxes overlap in X (a tile
/// seam — columns don't) and vertically by >60% of the shorter (same row —
/// stacked lines don't), AND either
///   • both are tall (a heading — the original title stitch), or
///   • their x-overlap band contains a tile seam: the unambiguous signature
///     of a seam-split body-text line whose halves no single tile contained
///     (absorption can't help — there is no fuller read to absorb into).
///     Small-text pairs overlapping AWAY from a seam are left alone — those
///     are the ambiguous dense-table cases the height gate was added for.
func sameLineFragments(_ a: CGRect, _ b: CGRect, seams: [CGFloat] = []) -> Bool {
    let inter = a.intersection(b)
    guard !inter.isNull, inter.width > 0 else { return false }
    let minH = min(a.height, b.height)
    guard minH > 0, inter.height / minH > 0.6 else { return false }
    if minH > minStitchLineHeight { return true }
    return seams.contains {
        $0 >= inter.minX - seamEdgeTolerance && $0 <= inter.maxX + seamEdgeTolerance
    }
}

/// Re-run OCR on the union region cropped from the full-res source and map the
/// result back to full-image normalized coords. A title is large text, so a
/// single-line crop reads cleanly in one pass — no seam to stitch. nil on failure.
private func rereadUnion(_ box: CGRect, source: CGImage, W: CGFloat, H: CGFloat) -> [(line: RecognizedLine, conf: Float)]? {
    // Small pad so edge glyphs aren't clipped; vertical pad kept tiny so an
    // adjacent row isn't pulled in.
    let padded = box.insetBy(dx: -box.width * 0.01, dy: -box.height * 0.08)
    let px = CGRect(x: padded.minX * W, y: padded.minY * H, width: padded.width * W, height: padded.height * H)
        .integral.intersection(CGRect(x: 0, y: 0, width: W, height: H))
    guard px.width >= 1, px.height >= 1, let crop = source.cropping(to: px) else { return nil }
    let lines = recognizeLines(in: upscaledForOCR(crop))
    guard !lines.isEmpty else { return nil }
    return lines.map { (transformLine($0.line, tile: px, imageW: W, imageH: H), $0.conf) }
}

// MARK: - Dense-table cross-column repair

/// Apply `columnGutterRepairs` decisions: drop merged reads whose cells are
/// already present, and re-OCR the rest column-by-column from the full-res
/// source (`rereadUnion` crops + upscales, the same proven path the title
/// stitch uses). Degrade, never worse: if any column side fails to re-read,
/// the original merged line is kept. A final dedup pass absorbs any overlap
/// between re-read pieces and pre-existing cell reads.
private func repairColumnSpanningReads(_ items: [(line: RecognizedLine, conf: Float)],
                                       source: CGImage,
                                       seams: [CGFloat]) -> [(line: RecognizedLine, conf: Float)] {
    let repairs = columnGutterRepairs(boxes: items.map { $0.line.box },
                                      texts: items.map { $0.line.text },
                                      seams: seams)
    guard !repairs.isEmpty else { return items }

    let W = CGFloat(source.width), H = CGFloat(source.height)
    var out: [(line: RecognizedLine, conf: Float)] = []
    var dropped = 0, split = 0
    for (i, item) in items.enumerated() {
        switch repairs[i] {
        case nil:
            out.append(item)
        case .drop:
            os_log("column repair DROP '%{public}@' x[%.3f…%.3f]", log: log, type: .info,
                   String(item.line.text.prefix(28)),
                   item.line.box.minX, item.line.box.maxX)
            dropped += 1
        case .reread(let subBoxes):
            var pieces: [(line: RecognizedLine, conf: Float)] = []
            var allSidesRead = true
            for box in subBoxes {
                if let reread = rereadUnion(box, source: source, W: W, H: H), !reread.isEmpty {
                    pieces.append(contentsOf: reread)
                } else {
                    allSidesRead = false
                    break
                }
            }
            // Log the OUTCOME so a false split is adjudicable from the log
            // alone: a legit split shows distinct cell texts; a false one
            // shows two halves of one sentence.
            let cuts = subBoxes.dropFirst().map { String(format: "%.3f", $0.minX) }
                .joined(separator: ",")
            let pieceTexts = pieces.map { "'\($0.line.text.prefix(36))'" }.joined(separator: " | ")
            os_log("column repair SPLIT '%{public}@' x[%.3f…%.3f] cuts{%{public}@} → %{public}@",
                   log: log, type: .info, String(item.line.text.prefix(60)),
                   item.line.box.minX, item.line.box.maxX, cuts,
                   allSidesRead ? pieceTexts : "REREAD FAILED, kept original")
            if allSidesRead {
                out.append(contentsOf: pieces)
                split += 1
            } else {
                out.append(item)
            }
        }
    }
    os_log("OCR column repair: %d merged reads dropped, %d split at gutters",
           log: log, type: .info, dropped, split)
    return dedupLines(out)
}

/// Intersection-over-union of two normalized boxes (0 = disjoint, 1 = identical).
private func boxIoU(_ a: CGRect, _ b: CGRect) -> CGFloat {
    let inter = a.intersection(b)
    guard !inter.isNull, inter.width > 0, inter.height > 0 else { return 0 }
    let ia = inter.width * inter.height
    let ua = a.width * a.height + b.width * b.height - ia
    return ua > 0 ? ia / ua : 0
}

/// Two OCR strings are the "same line" when identical or within a small edit
/// distance that scales with length (a couple of glyphs can differ between tiles).
private func textsSimilar(_ a: String, _ b: String) -> Bool {
    if a == b { return true }
    return editDistance(a, b) <= max(1, min(a.count, b.count) / 5)
}

/// Vision is normalized bottom-left origin; flip to top-left origin.
private func flipY(_ r: CGRect) -> CGRect {
    CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height)
}

/// Opportunistically refine the robust equal-width fallback with Vision boxes
/// for whitespace-delimited/alphanumeric tokens. Token-range geometry is much
/// more reliable than per-character geometry and prevents positional error from
/// accumulating across a long proportional-font line. Every accepted box is
/// validated against the line; bad Vision results simply keep the fallback.
private func tokenAwareCharacterBoxes(candidate: VNRecognizedText,
                                      displayText: String,
                                      lineBox: CGRect) -> [CGRect] {
    let sourceText = candidate.string
    let sourceChars = Array(sourceText)
    let displayChars = Array(displayText)
    guard sourceChars.count == displayChars.count, !sourceChars.isEmpty else {
        return subdivideLineBox(lineBox, count: displayChars.count)
    }

    var boxes = subdivideLineBox(lineBox, count: displayChars.count)
    let ranges = geometryTokenRanges(sourceChars)
    var accepted: [(range: Range<Int>, box: CGRect)] = []
    let tolerance = lineBox.insetBy(dx: -max(0.002, lineBox.width * 0.08),
                                    dy: -max(0.002, lineBox.height * 0.5))

    for range in ranges {
        let lower = sourceText.index(sourceText.startIndex, offsetBy: range.lowerBound)
        let upper = sourceText.index(sourceText.startIndex, offsetBy: range.upperBound)
        guard let observation = try? candidate.boundingBox(for: lower..<upper) else { continue }
        let tokenBox = flipY(observation.boundingBox)
        guard tokenBox.width > 0.000_001, tokenBox.height > 0.000_001,
              tolerance.contains(CGPoint(x: tokenBox.midX, y: tokenBox.midY)) else { continue }
        // A strict subrange reported as virtually the entire line is one of
        // Vision's known bad range results; retain the fallback for that token.
        if ranges.count > 1, tokenBox.width >= lineBox.width * 0.92 { continue }

        let tokenBoxes = subdivideLineBox(tokenBox, count: range.count)
        for (offset, index) in range.enumerated() { boxes[index] = tokenBoxes[offset] }
        accepted.append((range, tokenBox))
    }

    // Give spaces between two accepted tokens their actual visual gap rather
    // than a slice of the whole line. This also keeps phrase highlights tight.
    accepted.sort { $0.range.lowerBound < $1.range.lowerBound }
    for pairIndex in 0..<(max(0, accepted.count - 1)) {
        let left = accepted[pairIndex]
        let right = accepted[pairIndex + 1]
        let gap = left.range.upperBound..<right.range.lowerBound
        guard !gap.isEmpty,
              displayChars[gap].allSatisfy(\.isWhitespace),
              right.box.minX >= left.box.maxX else { continue }
        let vertical = left.box.union(right.box)
        let gapBox = CGRect(x: left.box.maxX, y: vertical.minY,
                            width: right.box.minX - left.box.maxX,
                            height: vertical.height)
        let gapBoxes = subdivideLineBox(gapBox, count: gap.count)
        for (offset, index) in gap.enumerated() { boxes[index] = gapBoxes[offset] }
    }
    return boxes
}

/// Contiguous geometry tokens: letters/numbers stay together, punctuation
/// stays separate from them, and whitespace is filled from adjacent token gaps.
private func geometryTokenRanges(_ chars: [Character]) -> [Range<Int>] {
    func kind(_ char: Character) -> Int {
        if char.isWhitespace { return 0 }
        return (char.isLetter || char.isNumber) ? 1 : 2
    }
    var ranges: [Range<Int>] = []
    var index = 0
    while index < chars.count {
        let tokenKind = kind(chars[index])
        guard tokenKind != 0 else { index += 1; continue }
        let start = index
        index += 1
        while index < chars.count, kind(chars[index]) == tokenKind { index += 1 }
        ranges.append(start..<index)
    }
    return ranges
}

// MARK: - Low-confidence region re-OCR

/// Lines at or below this confidence get a high-resolution second look. Clean
/// on-screen text recognizes at ~0.99, so this targets only photographed /
/// blurry / tiny text and leaves screenshots untouched (no extra cost).
private let refineConfidenceThreshold: Float = 0.9
/// Worst-case bound on the number of crop re-OCR requests, so a pathological
/// image (hundreds of weak lines) can't blow up recognition time.
private let refineMaxLines = 40
/// The same bound for automatic, background recognition on a Mac with no
/// Neural Engine, where each re-read costs ~120ms instead of ~14ms.
///
/// Not zero: measured screenshots carry ~6 weak lines, so this rarely binds on
/// an ordinary capture and mainly caps the pathological tail — which is what
/// produced the 15-37s captures in the field, where the 40-line cap was being
/// hit. Bounds the pass at roughly 1s on the slowest hardware measured.
private let refineMaxLinesWithoutNeuralEngine = 8
/// Re-OCR crops are upscaled so the text is about this tall in pixels — enough
/// resolution for Vision to resolve ambiguous glyphs without huge buffers.
private let refineTargetTextHeight: CGFloat = 96
/// How much to tighten each line outline vertically (fraction of line height,
/// split top/bottom) so the box hugs the text — see issue: close lines merging.
let lineQuadVerticalInset: CGFloat = 0.16

/// Even-subdivision character boxes that tile `lineBox` into `count` equal
/// columns (the robust caret model — see the call site for the rationale).
func subdivideLineBox(_ lineBox: CGRect, count: Int) -> [CGRect] {
    guard count > 0 else { return [] }
    let charWidth = lineBox.width / CGFloat(count)
    return (0..<count).map { i in
        CGRect(x: lineBox.minX + CGFloat(i) * charWidth, y: lineBox.minY,
               width: charWidth, height: lineBox.height)
    }
}

/// Decide whether a re-OCR of a cropped line should replace the original text.
/// A high-resolution crop padded for context often catches a neighbouring line,
/// so there can be several candidates: pick the one that is a *re-read of the
/// same line* — the smallest edit distance to the original — and accept it only
/// when it is non-empty, changed, a near-match (not a wholly different line),
/// and strictly more confident. So a confident misread (D8→D6) gets corrected
/// while an unrelated neighbour (a URL) is ignored.
func refinedText(oldText: String, oldConfidence: Float,
                 candidates: [(String, Float)]) -> String? {
    let usable = candidates.filter { !$0.0.isEmpty }
    guard let best = usable.min(by: {
        editDistance($0.0, oldText) < editDistance($1.0, oldText)
    }) else { return nil }
    let (text, conf) = best
    // A near-match is a re-read of the same token, not a different line. Scale
    // the tolerance with length (a longer code can absorb a couple more fixes).
    let nearMatchLimit = max(2, oldText.count / 4)
    guard text != oldText, conf > oldConfidence,
          editDistance(text, oldText) <= nearMatchLimit else { return nil }
    return text
}

/// Levenshtein edit distance (small strings — single OCR line tokens).
func editDistance(_ a: String, _ b: String) -> Int {
    let x = Array(a), y = Array(b)
    if x.isEmpty { return y.count }
    if y.isEmpty { return x.count }
    var prev = Array(0...y.count)
    var curr = [Int](repeating: 0, count: y.count + 1)
    for i in 1...x.count {
        curr[0] = i
        for j in 1...y.count {
            let cost = x[i - 1] == y[j - 1] ? 0 : 1
            curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
        }
        swap(&prev, &curr)
    }
    return prev[y.count]
}

/// Re-OCR every line whose confidence is at/below the threshold, in place.
private func refineLowConfidenceLines(_ lines: inout [RecognizedLine],
                                      confidences: [Float], source: CGImage,
                                      limits: RefinementLimits) throws {
    // Weakest first, so when `maxLines` binds, what gets dropped is the work
    // least likely to pay off. Index order (the previous behavior) would cut
    // an arbitrary tail instead. Every observed correction came from a line at
    // or below 0.5 confidence, so ordering genuinely changes what survives.
    let candidates = lines.indices
        .filter { confidences[$0] <= refineConfidenceThreshold }
        .sorted { confidences[$0] < confidences[$1] }
        .prefix(limits.maxLines)
    for i in candidates {
        try Task.checkCancellation()
        guard let newText = reocrLine(lines[i], oldConfidence: confidences[i],
                                      source: source, limits: limits)
        else { continue }
        // Keep the pass-1 geometry/quad; only the string (and its char-box
        // subdivision, which depends on character count) changes.
        lines[i] = RecognizedLine(text: newText, box: lines[i].box,
                                  charBoxes: subdivideLineBox(lines[i].box, count: newText.count),
                                  quad: lines[i].quad)
    }
}

/// Crop the line region from `source`, upscale+sharpen it, re-run OCR, and
/// return a corrected string if one clears `refinedText`'s bar. nil on any
/// failure or when no correction is warranted.
private func reocrLine(_ line: RecognizedLine, oldConfidence: Float,
                       source: CGImage, limits: RefinementLimits) -> String? {
    let W = CGFloat(source.width), H = CGFloat(source.height)
    // Pad the line box modestly (just enough breathing room for Vision); too
    // much vertical padding swallows neighbouring lines on tightly-spaced
    // labels. `refinedText` tolerates a caught neighbour, but less is cleaner.
    let padded = line.box.insetBy(dx: -line.box.width * 0.03,
                                  dy: -line.box.height * 0.25)
    let pixelRect = CGRect(x: padded.minX * W, y: padded.minY * H,
                           width: padded.width * W, height: padded.height * H)
        .intersection(CGRect(x: 0, y: 0, width: W, height: H))
        .integral
    guard pixelRect.width >= 1, pixelRect.height >= 1,
          let crop = source.cropping(to: pixelRect) else { return nil }

    // Re-OCR the upscaled crop — plus, when the budget allows, a SHARPENED
    // copy — and pool their candidates. Sharpening helps some blurry glyphs but
    // can itself close a "6" into an "8", so we never rely on it alone;
    // whichever variant reads the same line most confidently wins via
    // `refinedText`. The second variant doubles the pass's Vision requests,
    // which is why budgeted (automatic) recognition drops it; every
    // user-initiated path still pools both.
    var candidates: [(String, Float)] = []
    let variants = limits.useSharpenedVariant
        ? [upscaled(crop, sharpen: false), upscaled(crop, sharpen: true)]
        : [upscaled(crop, sharpen: false)]
    for prepared in variants {
        guard let prepared else { continue }
        candidates += reocrCandidates(prepared)
    }
    return refinedText(oldText: line.text, oldConfidence: oldConfidence, candidates: candidates)
}

/// Run a single OCR pass over a prepared crop and return non-empty candidates.
private func reocrCandidates(_ image: CGImage) -> [(String, Float)] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    request.automaticallyDetectsLanguage = true
    request.recognitionLanguages = ["en-US"]
    request.minimumTextHeight = 0.008
    guard (try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])) != nil
    else { return [] }
    return ((request.results ?? []) as [VNRecognizedTextObservation]).compactMap { obs in
        guard let c = obs.topCandidates(1).first, !c.string.isEmpty else { return nil }
        return (foldStrayFullwidth(c.string), c.confidence)
    }
}

/// `CGImage.cropping(to:)` returns a VIEW that shares the parent's backing
/// buffer with the parent's row stride. CoreImage's `CIImage(cgImage:)`
/// copies planes with full-stride reads, so on the crop's LAST row it reads
/// `bytesPerRow` bytes even though the crop's visible bytes end earlier —
/// when the parent buffer ends at a page boundary right there, the overrun
/// hits an unmapped page (field crash: SIGBUS in memmove under
/// `upscaledForOCR`). Redraw into a self-owned, tightly-sized sRGB buffer
/// before handing any possibly-cropped image to CoreImage. Returns the
/// original on failure (Vision paths remain unaffected either way).
func selfContainedForCoreImage(_ image: CGImage) -> CGImage {
    guard let ctx = CGContext(
        data: nil, width: image.width, height: image.height,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return image }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return ctx.makeImage() ?? image
}

/// Upscale a small line crop so its text is ~`refineTargetTextHeight` tall,
/// optionally applying a mild unsharp mask. Returns nil on failure; never
/// downscales.
private func upscaled(_ crop: CGImage, sharpen: Bool) -> CGImage? {
    let scale = min(max(refineTargetTextHeight / CGFloat(crop.height), 1), 6)
    var out = CIImage(cgImage: selfContainedForCoreImage(crop))
    if scale > 1, let lanczos = CIFilter(name: "CILanczosScaleTransform") {
        lanczos.setValue(out, forKey: kCIInputImageKey)
        lanczos.setValue(scale, forKey: kCIInputScaleKey)
        lanczos.setValue(1.0, forKey: kCIInputAspectRatioKey)
        out = lanczos.outputImage ?? out
    }
    if sharpen, let unsharp = CIFilter(name: "CIUnsharpMask") {
        unsharp.setValue(out, forKey: kCIInputImageKey)
        unsharp.setValue(2.0, forKey: kCIInputRadiusKey)
        unsharp.setValue(0.6, forKey: kCIInputIntensityKey)
        out = unsharp.outputImage ?? out
    }
    let extent = out.extent
    guard extent.width >= 1, extent.height >= 1,
          let cg = ocrUpscaleContext.createCGImage(out, from: extent) else { return nil }
    return cg
}

/// Lanczos-upscale ~2x for recognition so small/isolated text reads better.
/// Skipped when the image is already large (the gain plateaus and OCR cost
/// grows with pixel count). Returns the original on any failure.
private func upscaledForOCR(_ image: CGImage) -> CGImage {
    let scale: CGFloat = 2.0
    guard max(image.width, image.height) < 2600 else { return image }
    let ci = CIImage(cgImage: selfContainedForCoreImage(image))
    guard let filter = CIFilter(name: "CILanczosScaleTransform") else { return image }
    filter.setValue(ci, forKey: kCIInputImageKey)
    filter.setValue(scale, forKey: kCIInputScaleKey)
    filter.setValue(1.0, forKey: kCIInputAspectRatioKey)
    let target = CGRect(x: 0, y: 0,
                        width: CGFloat(image.width) * scale,
                        height: CGFloat(image.height) * scale)
    guard let out = filter.outputImage,
          let cg = ocrUpscaleContext.createCGImage(out, from: target) else { return image }
    return cg
}
