import CoreGraphics
import Foundation
import RedactionEngineInterface

/// Scans a captured image for sensitive text and returns proposed redaction
/// regions in 1× image space. OCR runs through the shared `TextRecognizer`
/// (on-device Vision, off the main actor, cancellable); tall images such as
/// stitched scroll captures are processed in overlapping vertical tiles so
/// Vision sees text at a usable resolution throughout.
@MainActor
final class SmartRedactionAnalyzer {

    private let recognizer = TextRecognizer()
    private let maxTileHeight: CGFloat
    private let tileOverlap: CGFloat

    init(maxTileHeight: CGFloat = 2400, tileOverlap: CGFloat = 240) {
        self.maxTileHeight = maxTileHeight
        self.tileOverlap = tileOverlap
    }

    /// Human-readable scan phases (shown in the progress overlay). `thorough` is
    /// the Foundation-Model pass — the variable, sometimes-long step.
    enum ScanPhase {
        static let reading = "Reading text…"
        static let detecting = "Detecting sensitive info…"
        static let thorough = "Thorough AI scan…"
        static let finalizing = "Finalizing…"
    }

    func analyze(_ image: CGImage,
                 engine: RedactionEngine? = nil,
                 onProgress: (@MainActor (Double, String) -> Void)? = nil) async throws -> (detections: [Detection], financialDocument: Bool) {
        let size = CGSize(width: image.width, height: image.height)
        let tiles = DetectionGeometry.verticalTiles(for: size,
                                                    maxTileHeight: maxTileHeight,
                                                    overlap: tileOverlap)
        // OCR every tile first — the model needs the full text before we can ask
        // it to find what the rules missed or flag false positives. OCR is the
        // bulk of the work, so it drives most of the progress bar (0 → 0.7).
        var layouts: [(layout: RecognizedTextLayout, tile: CGRect)] = []
        for (i, tile) in tiles.enumerated() {
            try Task.checkCancellation()
            let tileImage: CGImage
            if tiles.count == 1 {
                tileImage = image
            } else if let cropped = image.cropping(to: tile) {
                tileImage = cropped
            } else {
                continue
            }
            layouts.append((try await recognizer.recognize(tileImage), tile))
            onProgress?(Double(i + 1) / Double(tiles.count) * 0.7, ScanPhase.reading)
        }

        // Engine path (GLiNER2): anchored floor (label→value + addresses) + engine
        // detections. The NLTagger NER and Foundation-Model block are both skipped —
        // GLiNER2 replaces them, and re-running the NER would bring back the false
        // positives ("Treasury stock") this path exists to remove.
        if let engine {
            onProgress?(0.75, ScanPhase.detecting)
            // The blocking model detect must run off the main/cooperative actor.
            let ocrText = layouts.flatMap { $0.layout.lines.map(\.text) }.joined(separator: "\n")
            // Tune the model's label set to the document type (multi-label; an
            // empty classification falls back to the full union — recall safe).
            let docTypes = RedactionDocTypeClassifier.classify(ocrText)
            let entityTypes = RedactionCategories.entityTypes(for: docTypes)
            let found = await Task.detached {
                engine.detect(text: ocrText, entityTypes: entityTypes)
            }.value

            // Optional open-vocabulary backstop ("Thorough scan", macOS 26 + AI):
            // run the Foundation Model behind the structured detectors to catch
            // the long tail. Deduped against everything already found; its
            // false-positive flags damp the floor. Empty/off → engine path as-is.
            var additionalFindings: [RedactionFinding] = []
            var falsePositives: Set<String> = []
            if RedactionBackstopGate.shouldRun(thorough: ThoroughScanPreference().enabled,
                                               aiEnabled: AIFeaturePreference().enabled,
                                               fmAvailable: AIAvailability.isFoundationModelAvailable),
               #available(macOS 26, *) {
                try Task.checkCancellation()
                onProgress?(0.85, ScanPhase.thorough)
                let alreadyDetected = layouts.flatMap { Self.engineFloorTexts(in: $0.layout) } + found.map(\.text)
                let review = await FoundationRedactionDetector().review(ocrText: ocrText,
                                                                        alreadyDetected: alreadyDetected)
                additionalFindings = Self.newFindings(review.additional, excluding: alreadyDetected)
                falsePositives = Set(review.falsePositives)
            }
            onProgress?(0.95, ScanPhase.finalizing)

            var all: [Detection] = []
            for (layout, tile) in layouts {
                all.append(contentsOf: Self.detections(in: layout, tile: tile,
                                                       falsePositiveTexts: falsePositives,
                                                       includeContextual: false))
                all.append(contentsOf: Self.engineDetections(found, in: layout, tile: tile))
                all.append(contentsOf: Self.contextualDetections(findings: additionalFindings,
                                                                 in: layout, tile: tile))
            }
            // Financial docs: a deterministic money floor catches figures GLiNER2
            // misses (parenthesized negatives, bare comma-numbers). Gated off for
            // non-financial docs so we don't redact every number everywhere.
            if docTypes.contains(.financial) {
                for (layout, tile) in layouts {
                    all.append(contentsOf: Self.moneyFloorDetections(in: layout, tile: tile))
                }
            }
            for (layout, tile) in layouts {
                all.append(contentsOf: Self.alwaysOnDetections(in: layout, tile: tile))
            }
            if all.contains(where: { $0.category == .creditCard }) {
                for (layout, tile) in layouts { all.append(contentsOf: Self.cardExpiryDetections(in: layout, tile: tile)) }
            }
            onProgress?(1.0, ScanPhase.finalizing)
            return (DetectionConsolidation.consolidate(DetectionRelabel.corrected(all)), docTypes.contains(.financial))
        }

        // Optional on-device Foundation Model augmentation: additive detections
        // plus false-positive flags. Empty (and harmless) when AI is off, the
        // model is unavailable, or it errors — the regex floor is never weakened.
        var additionalFindings: [RedactionFinding] = []
        var falsePositives: Set<String> = []
        // Same gate as the engine path: the Thorough-scan toggle governs the
        // FM pass EVERYWHERE. (It previously only gated the engine path, so
        // with the enhanced model removed and Thorough off, scans still ran —
        // and showed — "Thorough AI scan…".)
        if RedactionBackstopGate.shouldRun(thorough: ThoroughScanPreference().enabled,
                                           aiEnabled: AIFeaturePreference().enabled,
                                           fmAvailable: AIAvailability.isFoundationModelAvailable),
           #available(macOS 26, *) {
            onProgress?(0.75, ScanPhase.thorough)
            let ocrText = layouts.flatMap { $0.layout.lines.map(\.text) }.joined(separator: "\n")
            let detected = layouts.flatMap { Self.regexMatchTexts(in: $0.layout) }
            let review = await FoundationRedactionDetector().review(ocrText: ocrText,
                                                                    alreadyDetected: detected)
            // Drop FM finds that a rule/NER detector already caught — the model
            // re-reports them and they'd show as duplicate generic rows.
            additionalFindings = Self.newFindings(review.additional, excluding: detected)
            falsePositives = Set(review.falsePositives)
        }
        onProgress?(0.95, ScanPhase.finalizing)

        let basicDocTypes = RedactionDocTypeClassifier.classify(
            layouts.flatMap { $0.layout.lines.map(\.text) }.joined(separator: "\n"))
        let financialDocument = basicDocTypes.contains(.financial)

        var all: [Detection] = []
        for (layout, tile) in layouts {
            // Regex first so dedup keeps the rules' detections over any overlap.
            all.append(contentsOf: Self.detections(in: layout, tile: tile,
                                                   falsePositiveTexts: falsePositives))
            all.append(contentsOf: Self.contextualDetections(findings: additionalFindings,
                                                             in: layout, tile: tile))
        }
        if financialDocument {
            for (layout, tile) in layouts {
                all.append(contentsOf: Self.moneyFloorDetections(in: layout, tile: tile))
            }
        }
        for (layout, tile) in layouts {
            all.append(contentsOf: Self.alwaysOnDetections(in: layout, tile: tile))
        }
        if all.contains(where: { $0.category == .creditCard }) {
            for (layout, tile) in layouts { all.append(contentsOf: Self.cardExpiryDetections(in: layout, tile: tile)) }
        }
        onProgress?(1.0, ScanPhase.finalizing)
        return (DetectionConsolidation.consolidate(DetectionRelabel.corrected(all)), financialDocument)
    }

    // MARK: - Grouped credit-card numbers (4-digit groups split across OCR tokens)

    private struct CardCell { let digits: String; let rect: CGRect }

    /// Runs of exactly 4 horizontally-adjacent 4-digit groups on a row whose first
    /// digit is a card BIN (3–6) — one run per card number. Shared by the card-number
    /// and cardholder-name detectors.
    private static func cardRuns(in layout: RecognizedTextLayout, tile: CGRect) -> [[CardCell]] {
        var cells: [CardCell] = []
        for line in layout.lines {
            let chars = line.characters
            var i = 0
            while i < chars.count {
                guard chars[i].isNumber else { i += 1; continue }
                var j = i
                while j < chars.count, chars[j].isNumber { j += 1 }
                if j - i == 4, let nb = DetectionGeometry.normalizedBox(for: i..<j, in: line) {
                    let r = DetectionGeometry.imageRect(fromNormalized: nb, imageSize: tile.size)
                        .offsetBy(dx: tile.minX, dy: tile.minY)
                    cells.append(CardCell(digits: String(chars[i..<j]), rect: r))
                }
                i = j
            }
        }
        guard cells.count >= 4 else { return [] }
        let medianH = cells.map { $0.rect.height }.sorted()[cells.count / 2]
        let sorted = cells.sorted { $0.rect.midY != $1.rect.midY ? $0.rect.midY < $1.rect.midY : $0.rect.minX < $1.rect.minX }
        var rows: [[CardCell]] = []
        var cur: [CardCell] = []
        for c in sorted {
            if let last = cur.last, abs(c.rect.midY - last.rect.midY) > 0.6 * medianH { rows.append(cur); cur = [] }
            cur.append(c)
        }
        if !cur.isEmpty { rows.append(cur) }
        var runs: [[CardCell]] = []
        for row in rows {
            let r = row.sorted { $0.rect.minX < $1.rect.minX }
            var run: [CardCell] = []
            func flush() {
                if run.count == 4, let first = run.first?.digits.first, "3456".contains(first) { runs.append(run) }
                run = []
            }
            for c in r {
                if let last = run.last {
                    let gap = c.rect.minX - last.rect.maxX
                    if gap >= -2, gap < 1.5 * last.rect.width { run.append(c) } else { flush(); run = [c] }
                } else { run = [c] }
            }
            flush()
        }
        return runs
    }

    /// A credit-card number printed as spaced 4-digit groups is split by OCR, so the
    /// 16-contiguous-digit regex never matches and detection falls to GLiNER2
    /// (unreliable, partial rects). Stitches adjacent 4-digit groups on a row into a
    /// card with a rect per group — deterministic, every group covered.
    static func creditCardGroupDetections(in layout: RecognizedTextLayout, tile: CGRect) -> [Detection] {
        cardRuns(in: layout, tile: tile).map { run in
            Detection(category: .creditCard, snippet: run.map { $0.digits }.joined(separator: " "),
                      confidence: 0.9, rects: DetectionGeometry.mergedRects(run.map { $0.rect }),
                      customLabel: nil, reason: "A credit card number (grouped digits).")
        }
    }

    /// The cardholder name printed directly below a card number. Deterministic by
    /// position: the name-like line immediately under the number row (a real name
    /// would otherwise need the NER, which a placeholder/short name can miss).
    static func cardholderNameDetections(in layout: RecognizedTextLayout, tile: CGRect) -> [Detection] {
        let runs = cardRuns(in: layout, tile: tile)
        guard !runs.isEmpty else { return [] }
        var out: [Detection] = []
        for run in runs {
            let rects = run.map { $0.rect }
            let minX = rects.map(\.minX).min()!, maxX = rects.map(\.maxX).max()!
            let maxY = rects.map(\.maxY).max()!, h = rects.map(\.height).max()!
            var best: RecognizedLine?
            var bestGap = CGFloat.greatestFiniteMagnitude
            for line in layout.lines {
                let lr = DetectionGeometry.imageRect(fromNormalized: line.box, imageSize: tile.size)
                    .offsetBy(dx: tile.minX, dy: tile.minY)
                let gap = lr.minY - maxY
                guard gap >= -0.3 * h, gap < 2.0 * h else { continue }
                let overlapX = min(maxX, lr.maxX) - max(minX, lr.minX)
                guard overlapX > 0.2 * (maxX - minX), gap < bestGap, isCardholderName(line.text) else { continue }
                bestGap = gap; best = line
            }
            if let nameLine = best {
                let r = DetectionGeometry.imageRect(fromNormalized: nameLine.box, imageSize: tile.size)
                    .offsetBy(dx: tile.minX, dy: tile.minY)
                out.append(Detection(category: .contextual, snippet: nameLine.text.trimmingCharacters(in: .whitespaces),
                                     confidence: 0.9, rects: [r], customLabel: "cardholder name",
                                     reason: "The cardholder name on a payment card."))
            }
        }
        return out
    }

    /// A line under a card number that looks like a name (letters, 1–4 words, no
    /// digits) and isn't a card label (BANK NAME / CREDIT CARD / VALID THRU …).
    static func isCardholderName(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard t.count >= 3, t.count <= 30, !t.contains(where: { $0.isNumber }),
              t.contains(where: { $0.isLetter }) else { return false }
        let words = t.split(separator: " ")
        guard (1...4).contains(words.count) else { return false }
        let labels: Set<String> = ["bank name", "credit card", "debit card", "valid thru",
                                   "valid from", "member since", "cardholder", "card holder",
                                   "expires", "expiry", "your bank"]
        return !labels.contains(t.lowercased())
    }

    /// Card expiry (MM/YY) — printed near the card number and often split across
    /// OCR tokens (`01/` + `25`). Joins each row's tokens and matches MM/YY, so a
    /// split expiry is caught. Call only when a card number is present (gate),
    /// otherwise it would match ordinary dates. `.contextual` at 0.9 → checked.
    private static let expiryRegex = try! NSRegularExpression(pattern: #"\b(0[1-9]|1[0-2])\s*/\s*\d{2}\b"#)
    static func cardExpiryDetections(in layout: RecognizedTextLayout, tile: CGRect) -> [Detection] {
        let lines = layout.lines.filter { !$0.text.isEmpty }
        guard !lines.isEmpty else { return [] }
        let sorted = lines.sorted { $0.box.midY < $1.box.midY }
        let medH = sorted.map { $0.box.height }.sorted()[sorted.count / 2]
        var rows: [[RecognizedLine]] = []
        var cur: [RecognizedLine] = []
        for l in sorted {
            if let last = cur.last, abs(l.box.midY - last.box.midY) > 0.6 * medH { rows.append(cur); cur = [] }
            cur.append(l)
        }
        if !cur.isEmpty { rows.append(cur) }
        var out: [Detection] = []
        for row in rows {
            let ordered = row.sorted { $0.box.minX < $1.box.minX }
            let joined = ordered.map { $0.text }.joined(separator: " ")
            guard let m = expiryRegex.firstMatch(in: joined, range: NSRange(joined.startIndex..., in: joined)) else { continue }
            let value = (joined as NSString).substring(with: m.range)
            let rects = ordered.filter { $0.text.contains(where: { $0.isNumber }) }.map { l in
                DetectionGeometry.imageRect(fromNormalized: l.box, imageSize: tile.size)
                    .offsetBy(dx: tile.minX, dy: tile.minY)
            }
            guard !rects.isEmpty else { continue }
            out.append(Detection(category: .contextual, snippet: value, confidence: 0.9,
                                 rects: DetectionGeometry.mergedRects(rects),
                                 customLabel: "card expiry", reason: "A card expiration date."))
        }
        return out
    }

    // MARK: - Geometry-aware label→value (value on the line below the label)

    /// A sensitive field label at the start of a line — optionally preceded by
    /// ONE short modifier word ("RESTING heart rate", "Serial / Barcode",
    /// "Total Weight") — followed by a boundary (end / non-alphanumeric) so
    /// "account" never matches "accountant". The one-word prefix trades a
    /// small false-positive surface ("Edit Contact" buttons anchor as labels)
    /// for compound-header coverage; the value gates still bound the damage.
    private static let labelLineRegex = try! NSRegularExpression(
        pattern: #"^\s*(?:[A-Za-z][A-Za-z.]{0,11}\s*/?\s+)?("#
            + SensitiveLabels.geometryLabelAlternation + #")(?=$|[^A-Za-z0-9])"#,
        options: [.caseInsensitive])

    /// The sensitive label a line STARTS with (group 1), or nil.
    private static func leadingLabel(_ text: String) -> String? {
        let ns = text as NSString
        guard let m = labelLineRegex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1, m.range(at: 1).location != NSNotFound else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    /// Deterministic, always-on: when a line is "label-like" (a sensitive label,
    /// no digits, label ≥35% of the line — so bilingual passport labels qualify
    /// but prose does not), redact the value on the directly-below OR
    /// right-adjacent x/y-overlapping line (form UIs put the label LEFT and the
    /// value in a field BESIDE it — the claims-workstation miss). A line that
    /// is itself "label + digit-bearing value" with no separator ("DOB
    /// 1975-12-12") redacts its own remainder. Fills the gaps the same-line
    /// anchored regex leaves; independent of GLiNER2/FM. `.contextual` at
    /// 0.9 → checked by default.
    static func labeledValueDetections(in layout: RecognizedTextLayout, tile: CGRect) -> [Detection] {
        let lines = layout.lines
        var out: [Detection] = []
        for (i, line) in lines.enumerated() {
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            guard let label = leadingLabel(line.text) else { continue }
            // Codes-family headings ("Backup Verification codes") sit over a
            // GRID of bare numeric codes — 2FA backup codes no standalone
            // rule can safely match. Collect every code-like token in the
            // block beneath; buttons/prose fail the code-likeness gate.
            if isCodesLabel(label) {
                let grid = codeGridDetections(below: line, in: lines, tile: tile)
                if !grid.isEmpty {
                    out.append(contentsOf: grid)
                    continue
                }
                // No grid below — a single "Confirmation code | VS-83421"
                // key/value row resolves through the standard paths.
            }
            if trimmed.contains(where: { $0.isNumber }) {
                // Self-labeled: the value follows the label on the SAME line
                // without the separator the anchored regex requires.
                if let det = selfLabeledDetection(line: line, label: label, tile: tile) {
                    out.append(det)
                }
                continue
            }
            // Label-like gate: label covers a real fraction of the line.
            guard Double(label.count) >= 0.35 * Double(max(trimmed.count, 1)) else { continue }
            guard let (valueLine, value, isBelow) = valueField(for: i, label: label, in: lines) else { continue }
            let normalizedLabel = label.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " .:#-"))
            func emit(_ cellLine: RecognizedLine, _ cellValue: String) {
                let rect = DetectionGeometry.imageRect(fromNormalized: cellLine.box, imageSize: tile.size)
                    .offsetBy(dx: tile.minX, dy: tile.minY)
                out.append(Detection(
                    category: .contextual, snippet: String(cellValue.prefix(64)), confidence: 0.9,
                    rects: [rect],
                    customLabel: normalizedLabel,
                    reason: "Value labeled '\(label.trimmingCharacters(in: .whitespaces))'."))
            }
            emit(valueLine, value)
            // A table header labels its whole COLUMN, not one cell (the weight
            // column: one "Weight" header, N rows — only row 1 would catch).
            // Walk down collecting further cells; beside-values are single
            // form fields, never columns.
            // Walk only under labels that plausibly head a TABLE COLUMN.
            // Form-field labels (secrets, guardian, contact, demographics)
            // have exactly one value — walking below them collects the form's
            // next rows ("Status", "Course Details") as junk.
            if isBelow, isColumnCapableLabel(label) {
                for cell in columnCellsBelow(first: valueLine, label: line.box,
                                             isWordValue: isWordValueLabel(label), in: lines) {
                    emit(cell, cell.text.trimmingCharacters(in: .whitespaces))
                }
            }
        }
        return out
    }

    /// Hard cap on column cells collected under one header (runaway guard).
    private static let columnMaxRows = 40

    /// Cells stacked beneath `first` in the same column: x-overlapping the
    /// header, valid values, at a consistent row pitch. Stops at a section
    /// break (top-to-top step > 2.5× the running pitch), a label-shaped or
    /// invalid line, or the cap — so a summary figure below the table, or the
    /// next form section, is never swallowed.
    private static func columnCellsBelow(first: RecognizedLine, label: CGRect,
                                         isWordValue: Bool,
                                         in lines: [RecognizedLine]) -> [RecognizedLine] {
        var out: [RecognizedLine] = []
        var current = first
        var pitch = max(first.box.height, first.box.minY - label.minY)
        while out.count < columnMaxRows {
            var best: RecognizedLine?
            var bestStep = CGFloat.greatestFiniteMagnitude
            for l in lines {
                let step = l.box.minY - current.box.minY
                guard step > 0.5 * current.box.height, step <= 2.5 * pitch else { continue }
                let overlapX = min(label.maxX, l.box.maxX) - max(label.minX, l.box.minX)
                guard overlapX > 0.2 * label.width, step < bestStep else { continue }
                bestStep = step; best = l
            }
            guard let next = best else { break }
            // Walked cells carry the SAME value gates as beside-values: a
            // real value column is digit-bearing (weights, IDs) or belongs
            // to a word-value label (names, allergies). A key/label column
            // ("Environment", "Cluster" under a stray header) fails here and
            // ends the walk.
            let v = next.text.trimmingCharacters(in: .whitespaces)
            guard isValidValue(v), !isHeaderLike(v),
                  v.contains(where: { $0.isNumber }) || isWordValue else { break }
            out.append(next)
            pitch = bestStep
            current = next
        }
        return out
    }

    /// The label's value field: the line directly BELOW (passport-style stacked
    /// fields — checked first, preserving the original behavior), else the line
    /// BESIDE it to the right (form-style label/field rows). A beside value
    /// must carry at least one digit — names beside "Name:" belong to the NER,
    /// and a neighbouring column header ("Claim #" → "Claimant") must not fire —
    /// UNLESS the label's values are inherently words ("Blood Type: O+").
    private static func valueField(for i: Int, label: String,
                                   in lines: [RecognizedLine]) -> (RecognizedLine, String, isBelow: Bool)? {
        // Resolution order, tuned against real layouts:
        //  1. DIGIT-BEARING beside — key/value grids ("ticket | PRIV-4410"):
        //     the below-neighbour there is the NEXT KEY, which would cascade.
        //  2. Below — passports, form fields ("credential (API key)" over its
        //     token), table columns. Never preempted by a digit-less beside,
        //     because form rows put action buttons ("Generate New") beside
        //     the label at the same height as the real value below.
        //  3. Word-value digit-less beside, last resort — "Blood Type: | O+",
        //     "Full Name: | Jasen Gaylord", where nothing valid sits below.
        let beside = besideValueLine(of: i, in: lines)
        let besideValue = beside.map { $0.text.trimmingCharacters(in: .whitespaces) }
        if let beside, let value = besideValue,
           isValidValue(value), !isHeaderLike(value),
           value.contains(where: { $0.isNumber }) {
            return (beside, value, false)
        }
        if let below = belowValueLine(of: i, in: lines) {
            let value = below.text.trimmingCharacters(in: .whitespaces)
            if isValidValue(value),
               !isRoleNameLabel(label) || isNameShaped(value) {
                return (below, value, true)
            }
        }
        if let beside, let value = besideValue,
           isValidValue(value), !isHeaderLike(value), isWordValueLabel(label),
           !isRoleNameLabel(label) || isNameShaped(value) {
            return (beside, value, false)
        }
        return nil
    }

    /// A sibling column header masquerading as a beside-value: ALL-CAPS
    /// letters/spaces only ("LANGUAGE SPOKEN", "ROLE", "SEVERITY"). Real
    /// values are mixed case or carry digits/symbols ("PRIV-4410", "O+",
    /// "Wife") — those fall through this veto to the accept path, while a
    /// vetoed beside lets the label resolve DOWNWARD (its actual value in
    /// label-above-value grids).
    private static func isHeaderLike(_ value: String) -> Bool {
        value.count >= 2 && value.allSatisfy { $0.isUppercase || $0 == " " }
    }

    private static func isCodesLabel(_ label: String) -> Bool {
        let n = label.lowercased()
        return n == "otp" || n.contains("code")
    }

    /// A code-like token: strip separators → 6–14 alphanumerics, at least
    /// half digits ("38045294", "ab12-cd34"). Buttons ("GENERATE NEW CODES")
    /// and prose fail on length or letter share.
    static func isCodeLike(_ text: String) -> Bool {
        let stripped = text.filter { $0 != " " && $0 != "-" }
        guard stripped.count >= 6, stripped.count <= 14,
              stripped.allSatisfy({ $0.isLetter || $0.isNumber }) else { return false }
        let digits = stripped.filter(\.isNumber).count
        return Double(digits) >= 0.5 * Double(stripped.count)
    }

    /// Every code-like line in the block beneath a codes heading: within a
    /// bounded vertical window (the grid), anywhere to the right of the
    /// heading's left edge (grids span several columns).
    private static func codeGridDetections(below label: RecognizedLine,
                                           in lines: [RecognizedLine],
                                           tile: CGRect) -> [Detection] {
        let window = label.box.maxY ... (label.box.maxY + 12 * label.box.height)
        var out: [Detection] = []
        for l in lines {
            guard l.box.minY > window.lowerBound, l.box.minY <= window.upperBound,
                  l.box.minX >= label.box.minX - 0.02 else { continue }
            let text = l.text.trimmingCharacters(in: .whitespaces)
            guard isCodeLike(text), out.count < 24 else { continue }
            let rect = DetectionGeometry.imageRect(fromNormalized: l.box, imageSize: tile.size)
                .offsetBy(dx: tile.minX, dy: tile.minY)
            out.append(Detection(
                category: .contextual, snippet: text, confidence: 0.9, rects: [rect],
                customLabel: "backup code",
                reason: "A verification/backup code under a codes heading."))
        }
        return out
    }

    private static let secretLabelStems: [String] = [
        "secret", "credential", "token", "api key", "password",
    ]
    /// Role labels (claimant, tenant, student…) whose value is a person's
    /// NAME: the value must be name-shaped (2–4 capitalized words, no
    /// digits) — otherwise a bare "Student"/"Tenant" section heading anchors
    /// on the neighbouring heading or grade text.
    private static let roleNameLabelStems: [String] = [
        "claimant", "tenant", "landlord", "buyer", "seller", "borrower",
        "applicant", "insured", "adjuster", "student", "guardian", "prepared for",
    ]
    private static func isRoleNameLabel(_ label: String) -> Bool {
        let n = label.lowercased()
        guard !n.contains("name"), !n.contains("id") else { return false }   // explicit forms keep normal gates
        return roleNameLabelStems.contains { n.contains($0) }
    }
    private static let nameShapeRegex = try! NSRegularExpression(
        pattern: #"^[A-Z][A-Za-z'\-]+(?:\s+[A-Z][A-Za-z'\-]*\.?){1,3}$"#)
    private static func isNameShaped(_ value: String) -> Bool {
        let r = NSRange(value.startIndex..., in: value)
        return !value.contains(where: { $0.isNumber })
            && nameShapeRegex.firstMatch(in: value, range: r) != nil
    }

    private static func isSecretLabel(_ label: String) -> Bool {
        let n = label.lowercased()
        return secretLabelStems.contains { n.contains($0) }
    }

    /// Labels that head table COLUMNS in the wild (a header + N stacked
    /// cells): id/number columns, weights, names, clinical lists. Everything
    /// else is treated as a single-value form field (no walk).
    private static let columnCapableLabelStems: [String] = [
        "number", "no", "#", "id", "weight", "height", "tracking", "barcode", "claim",
        "plate", "dx", "icd", "cpt",
        "case", "docket", "policy", "booking", "reservation", "confirmation",
        "name", "allerg", "reaction", "medication", "immunization", "vaccine",
        "diagnosis", "dob", "birth",
    ]
    private static func isColumnCapableLabel(_ label: String) -> Bool {
        let n = label.lowercased()
        guard !isSecretLabel(n) else { return false }
        return columnCapableLabelStems.contains { n.contains($0) }
    }

    /// Labels whose values are inherently non-numeric (blood type "O+",
    /// ethnicity "Asian") — exempt from the beside path's digit gate. Id-ish
    /// labels (claim #, account…) keep the gate. A neighbouring column header
    /// still can't slip through as a value: headers are themselves label-shaped
    /// and `isValidValue` rejects them.
    private static let wordValueLabelStems: [String] = [
        "blood type", "ethnicity", "race", "religio", "gender", "sex",
        "marital", "nationality", "allerg", "reaction", "diagnosis", "relationship",
        "name", "guardian", "contact",
        "claimant", "tenant", "landlord", "buyer", "seller", "borrower",
        "applicant", "insured", "adjuster", "student", "surname", "given",
        "prepared for", "dx", "icd", "cpt", "procedure",
        "medication", "immunization", "vaccine",
        "secret", "credential", "token", "api key", "password",
    ]
    private static func isWordValueLabel(_ label: String) -> Bool {
        let n = label.lowercased()
        return wordValueLabelStems.contains { n.contains($0) }
    }

    /// How far right of the label its value field may start, as a fraction of
    /// the image width. Forms put the value column a long way out (the medical
    /// template's field column starts ~25% of the page right of its labels —
    /// a line-height-relative bound rejected every field on it). Nearest-wins
    /// plus the value-validity gates keep a far unrelated column from binding.
    private static let besideValueMaxGap: CGFloat = 0.35

    /// The nearest line to the RIGHT of `i` on the same visual row.
    private static func besideValueLine(of i: Int, in lines: [RecognizedLine]) -> RecognizedLine? {
        let label = lines[i].box
        var best: RecognizedLine?
        var bestGap = CGFloat.greatestFiniteMagnitude
        for (j, l) in lines.enumerated() where j != i {
            let vOverlap = min(label.maxY, l.box.maxY) - max(label.minY, l.box.minY)
            guard vOverlap > 0.5 * min(label.height, l.box.height) else { continue }
            let gap = l.box.minX - label.maxX
            guard gap >= -0.1 * label.height, gap <= besideValueMaxGap else { continue }
            if gap < bestGap { bestGap = gap; best = l }
        }
        return best
    }

    /// "DOB 1975-12-12" — a line that IS its own label + value, separated only
    /// by whitespace (the anchored regex requires `:`/`=`). Precision gates so
    /// prose never matches: 1–4 remainder tokens, EVERY token carries a digit
    /// ("Patient 5 was discharged" fails on "was").
    private static func selfLabeledDetection(line: RecognizedLine, label: String,
                                             tile: CGRect) -> Detection? {
        let chars = Array(line.text)
        // Character offset where the label match ends (label may be preceded
        // by whitespace the anchored regex consumed).
        guard let labelStart = line.text.range(of: label)?.lowerBound else { return nil }
        var idx = line.text.distance(from: line.text.startIndex, to: labelStart) + label.count
        while idx < chars.count, chars[idx] == " " || chars[idx] == ":" || chars[idx] == "-" { idx += 1 }
        var end = chars.count
        while end > idx, chars[end - 1] == " " { end -= 1 }
        guard end > idx else { return nil }
        let value = String(chars[idx..<end])
        let tokens = value.split(separator: " ")
        guard value.count <= 48, (1...4).contains(tokens.count),
              tokens.allSatisfy({ $0.contains(where: { $0.isNumber }) }) else { return nil }
        guard let nb = DetectionGeometry.normalizedBox(for: idx..<end, in: line) else { return nil }
        let rect = DetectionGeometry.imageRect(fromNormalized: nb, imageSize: tile.size)
            .offsetBy(dx: tile.minX, dy: tile.minY)
        return Detection(
            category: .contextual, snippet: String(value.prefix(64)), confidence: 0.9,
            rects: [rect],
            customLabel: label.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " .:#-")),
            reason: "Value labeled '\(label.trimmingCharacters(in: .whitespaces))'.")
    }

    /// The line directly below `i` that horizontally overlaps it (the value cell).
    private static func belowValueLine(of i: Int, in lines: [RecognizedLine]) -> RecognizedLine? {
        let label = lines[i].box
        var best: RecognizedLine?
        var bestGap = CGFloat.greatestFiniteMagnitude
        for (j, l) in lines.enumerated() where j != i {
            let gap = l.box.minY - label.maxY                 // top-left: below = larger minY
            guard gap >= -0.2 * label.height, gap < 1.5 * label.height else { continue }
            let overlapX = min(label.maxX, l.box.maxX) - max(label.minX, l.box.minX)
            guard overlapX > 0.2 * label.width else { continue }
            if gap < bestGap { bestGap = gap; best = l }
        }
        return best
    }

    /// A value cell is non-empty, has real content, isn't itself a label, and is
    /// a single field (not a paragraph).
    private static func isValidValue(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 48 else { return false }
        guard value.contains(where: { $0.isLetter || $0.isNumber }) else { return false }
        guard !value.hasSuffix(":") else { return false }   // a header/label, not a value
        return leadingLabel(value) == nil
    }

    /// Deterministic passport number from a TD3 MRZ second line — catches the
    /// printed value (top of the passport) AND the MRZ occurrence, independent of
    /// GLiNER2/FM (which detect it unreliably / only with Thorough scan).
    /// `.contextual` "passport number" → high-risk (keyword) → always kept.
    static func passportNumberDetections(in layout: RecognizedTextLayout, tile: CGRect) -> [Detection] {
        var out: [Detection] = []
        for line in layout.lines {
            guard let number = SensitiveTextRules.passportNumberFromMRZLine(line.text) else { continue }
            let rects = spanRectsAllOccurrences(number, in: layout, tile: tile)
            guard !rects.isEmpty else { continue }
            out.append(Detection(
                category: .contextual, snippet: number, confidence: 0.95,
                rects: rects, customLabel: "passport number",
                reason: "Passport number from the machine-readable zone."))
        }
        return out
    }

    /// The deterministic passes that must run in EVERY scan.
    ///
    /// ONE list, called from both analysis paths — the engine path (a
    /// redaction model installed) and the deterministic-floor path (no model,
    /// or AI switched off). They were two copies, and a pass added to one of
    /// them silently did nothing in the other: the private-key and
    /// wrapped-value passes landed only on the floor path, which is the one
    /// the corpus harness exercises (it disables AI for reproducible reports),
    /// so every test and every corpus run passed while the app — with a model
    /// installed — kept missing the same private key. Adding a pass here now
    /// reaches both by construction.
    static func alwaysOnDetections(in layout: RecognizedTextLayout, tile: CGRect) -> [Detection] {
        // Passport number from the MRZ (fires only on MRZ lines).
        passportNumberDetections(in: layout, tile: tile)
            + privateKeyBlockDetections(in: layout, tile: tile)
            + wrappedValueDetections(in: layout, tile: tile)
            + labeledValueDetections(in: layout, tile: tile)
            + creditCardGroupDetections(in: layout, tile: tile)
            + cardholderNameDetections(in: layout, tile: tile)
    }

    /// A quoted value that WRAPS is redacted along its whole length.
    ///
    /// Every other path works one recognized line at a time, so a value the
    /// viewer soft-wrapped is redacted only as far as its first line and the
    /// remainder stays on screen — a JWT whose second half is legible is not
    /// redacted in any useful sense. Reported from the field on a narrow
    /// window, where an access token, a private key, a service-account address
    /// and two connection strings all wrapped.
    ///
    /// Works on QUOTE PARITY rather than on recognizing the value, because the
    /// value is exactly what OCR renders worst: the reported screenshot turned
    /// `eyJhbGciOiJIUzI1NiJ9` into `eÿJhbĞci0iJIUzI1NiJ9` and split the label
    /// `"access_token"` into `"access` + `token":`. A row that leaves a string
    /// open continues into the next row whatever the characters are.
    ///
    /// Gated on the row carrying a sensitive LABEL, so ordinary wrapped prose
    /// in a quoted string is never swept up, and bounded to `maxWrapRows` so a
    /// single unbalanced quote cannot blank the rest of a document.
    static func wrappedValueDetections(in layout: RecognizedTextLayout,
                                       tile: CGRect) -> [Detection] {
        let maxWrapRows = 6
        let rows = visualRows(of: layout.lines)
        var out: [Detection] = []
        var row = 0
        while row < rows.count {
            defer { row += 1 }
            let current = rows[row]
            let text = current.map(\.text).joined(separator: " ")
            // A field row carrying a sensitive label, whose value spills over.
            guard isFieldRow(text), labelAnywhere(text), leavesValueOpen(text),
                  row + 1 < rows.count,
                  isContinuationRow(rows[row + 1].map(\.text).joined(separator: " "))
            else { continue }

            var rects: [CGRect] = []
            // The opening row, from where the value starts to the row's end.
            if let openingIndex = current.lastIndex(where: { $0.text.contains("\"") }) {
                let openingLine = current[openingIndex]
                if let quoteIndex = openingLine.text.lastIndex(of: "\"") {
                    let start = openingLine.text.distance(from: openingLine.text.startIndex,
                                                          to: quoteIndex)
                    appendRect(for: start..<openingLine.text.count, in: openingLine,
                               tile: tile, into: &rects)
                }
                for line in current[(openingIndex + 1)...] {
                    appendRect(for: 0..<line.text.count, in: line, tile: tile, into: &rects)
                }
            }

            // Every following row that is still a continuation.
            var next = row + 1
            while next < rows.count, next - row <= maxWrapRows,
                  isContinuationRow(rows[next].map(\.text).joined(separator: " ")) {
                for line in rows[next] {
                    appendRect(for: 0..<line.text.count, in: line, tile: tile, into: &rects)
                }
                next += 1
            }
            guard rects.count > 1 else { continue }
            out.append(Detection(
                category: .contextual,
                snippet: SensitiveTextRules.displaySnippet(for: text.trimmingCharacters(in: .whitespaces)),
                confidence: 0.9, rects: rects, customLabel: "wrapped value",
                reason: "A sensitive field's value continues onto the next line."))
            row = next - 1
        }
        return out
    }

    /// A row that opens a field: it STARTS with a quoted key.
    ///
    /// The colon is deliberately not required. OCR drops it often — the
    /// reported screenshot lost it on `"username" "jordan.example"`,
    /// `"ssn" "123-45-6789"` and four more — and demanding it classified those
    /// rows as continuations, which dragged their neighbours into the
    /// redaction. Leading noise before the key is tolerated in turn
    /// (`("expiration_ date": …`), as is a mismatched closing quote.
    private static let fieldRowRegex = try! NSRegularExpression(
        pattern: #"^\s*[^A-Za-z0-9]{0,2}["'`][A-Za-z0-9_\-. ]{1,60}["'`]"#)

    private static func isFieldRow(_ text: String) -> Bool {
        let ns = text as NSString
        return fieldRowRegex.firstMatch(
            in: text, range: NSRange(location: 0, length: ns.length)) != nil
    }

    /// Whether the row's value is unfinished, so the next row can be its
    /// remainder. A row that closes its string, ends the field, or opens a
    /// nested object has nothing to continue — without this, a heading row
    /// like `"cloud_credentials": {` claimed the field below it and its
    /// consolidated detection displaced the AWS-key match underneath.
    private static func leavesValueOpen(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespaces).last else { return false }
        return !"\"'`,;{}[]".contains(last)
    }

    /// A row that CONTINUES the previous one rather than starting a field.
    ///
    /// Quote parity looked like the obvious test and is not usable: OCR reads
    /// a closing `"` as `'` often enough that balanced rows come back odd, and
    /// on the reported screenshot that alone dragged five unrelated rows into
    /// the redaction. Structure survives the noise — in a structured document
    /// every real row opens with a quoted key or a brace, and a soft-wrapped
    /// remainder opens with neither.
    private static func isContinuationRow(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        guard let first = trimmed.first, !"{}[]".contains(first) else { return false }
        guard !isFieldRow(trimmed) else { return false }
        // The tail of a VALUE always carries something other than words — a
        // quote, digits, punctuation, an underscore. Plain words are the row
        // below a field in a UI screenshot, not its continuation: without
        // this, `"date_time": … https://…/INC-2174` ran on into the window's
        // `Cancel  Unlock` buttons and blacked them out.
        return trimmed.contains { !$0.isLetter && !$0.isWhitespace }
    }

    /// Recognized lines grouped into visual rows (same baseline band), each
    /// ordered left to right. OCR splits a single row into several lines —
    /// `"access` and `token": "…` are separate lines on one row — and a label
    /// broken that way matches nothing until the row is put back together.
    private static func visualRows(of lines: [RecognizedLine]) -> [[RecognizedLine]] {
        let sorted = lines.sorted { $0.box.midY < $1.box.midY }
        var rows: [[RecognizedLine]] = []
        for line in sorted {
            if var last = rows.last, let reference = last.first,
               abs(line.box.midY - reference.box.midY) < max(line.box.height, reference.box.height) / 2 {
                last.append(line)
                rows[rows.count - 1] = last.sorted { $0.box.minX < $1.box.minX }
            } else {
                rows.append([line])
            }
        }
        return rows
    }

    /// A sensitive label ANYWHERE in the row.
    ///
    /// Deliberately not `labelLineRegex`, which anchors at line start and uses
    /// the narrower geometry vocabulary: a structured row opens with a quote
    /// (`"access token": …`), so an anchored match never fires, and the keys
    /// at issue here (access token, private key, service account) live in the
    /// value vocabulary.
    private static let anyLabelRegex = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9])("# + SensitiveLabels.valueLabelAlternation
            + #")(?=$|[^A-Za-z0-9])"#,
        options: [.caseInsensitive])

    private static func labelAnywhere(_ text: String) -> Bool {
        let ns = text as NSString
        return anyLabelRegex.firstMatch(
            in: text, range: NSRange(location: 0, length: ns.length)) != nil
    }

    private static func appendRect(for range: Range<Int>, in line: RecognizedLine,
                                   tile: CGRect, into rects: inout [CGRect]) {
        guard let box = DetectionGeometry.normalizedBox(for: range, in: line) else { return }
        rects.append(DetectionGeometry.imageRect(fromNormalized: box, imageSize: tile.size)
            .offsetBy(dx: tile.minX, dy: tile.minY))
    }

    /// Everything BETWEEN a `BEGIN PRIVATE KEY` marker and its `END` — the key
    /// material itself.
    ///
    /// The markers are matched per line by `SensitiveTextRules`, but boxing
    /// only the markers and leaving the bytes between them visible is worse
    /// than useless for a private key. OCR breaks a key block into separate
    /// lines, and does so even when the key is a single line in the source: a
    /// real screenshot of `"private_key": "-----BEGIN…KEY-----"` came back as
    /// five fragments on one row — label, BEGIN marker, key material, END
    /// marker, closing quote — so "between" is taken in READING order (top to
    /// bottom, then left to right), which covers both the wrapped PEM block
    /// and the single-row JSON string.
    static func privateKeyBlockDetections(in layout: RecognizedTextLayout,
                                          tile: CGRect) -> [Detection] {
        let ordered = layout.lines.enumerated().sorted { a, b in
            // Same visual row (within half a line height) → left to right.
            if abs(a.element.box.minY - b.element.box.minY)
                < max(a.element.box.height, b.element.box.height) / 2 {
                return a.element.box.minX < b.element.box.minX
            }
            return a.element.box.minY < b.element.box.minY
        }.map(\.element)

        var out: [Detection] = []
        var openedAt: Int?
        for (i, line) in ordered.enumerated() {
            if SensitiveTextRules.isPrivateKeyBeginMarker(line.text) {
                openedAt = i
                continue
            }
            guard SensitiveTextRules.isPrivateKeyEndMarker(line.text),
                  let start = openedAt else { continue }
            openedAt = nil
            // The fragments strictly between the two markers.
            for inner in ordered[(start + 1)..<i] {
                let text = inner.text.trimmingCharacters(in: .whitespaces)
                // A stray label or quote fragment carries no key material.
                guard text.count >= 8 else { continue }
                let rect = DetectionGeometry.imageRect(fromNormalized: inner.box,
                                                       imageSize: tile.size)
                    .offsetBy(dx: tile.minX, dy: tile.minY)
                out.append(Detection(
                    category: .contextual, snippet: SensitiveTextRules.displaySnippet(for: text),
                    confidence: 0.97, rects: [rect], customLabel: "private key",
                    reason: "Key material between BEGIN and END PRIVATE KEY markers."))
            }
        }
        return out
    }

    /// Deterministic money figures for FINANCIAL documents — catches what GLiNER2
    /// misses (parenthesized negatives, bare comma-numbers). `.contextual`
    /// "money amount" so it composes with the financial money-keep + consolidation.
    static func moneyFloorDetections(in layout: RecognizedTextLayout, tile: CGRect) -> [Detection] {
        var out: [Detection] = []
        for line in layout.lines {
            for match in SensitiveTextRules.moneyTokenMatches(in: line.text) {
                guard let nb = DetectionGeometry.normalizedBox(for: match.range, in: line) else { continue }
                let rect = DetectionGeometry.imageRect(fromNormalized: nb, imageSize: tile.size)
                    .offsetBy(dx: tile.minX, dy: tile.minY)
                out.append(Detection(
                    category: .contextual,
                    snippet: SensitiveTextRules.displaySnippet(for: match.text),
                    confidence: 0.9,
                    rects: DetectionGeometry.mergedRects([rect]),
                    customLabel: "money amount",
                    reason: "A monetary figure on a financial document."))
            }
        }
        return out
    }

    /// Full matched text of every rule/NLP detection in a layout — passed to the
    /// model so it can judge which are false positives.
    static func regexMatchTexts(in layout: RecognizedTextLayout) -> [String] {
        layout.lines.flatMap { line in
            SensitiveTextRules.combinedMatches(
                in: line.text, additional: ContextualDetectors.matches(in: line.text)).map(\.text)
        }
    }

    /// Full match texts of the engine-path structured floor (regex rules +
    /// anchored label→value/address; no NLTagger NER) — fed to the FM backstop's
    /// dedup so it never re-reports an already-detected field. Full texts (not
    /// truncated snippets) so dedup is accurate. Pure.
    static func engineFloorTexts(in layout: RecognizedTextLayout) -> [String] {
        layout.lines.flatMap { line in
            SensitiveTextRules.combinedMatches(
                in: line.text, additional: ContextualDetectors.anchoredMatches(in: line.text)).map(\.text)
        }
    }

    /// Keep only the FM findings whose text isn't already covered by a rule/NER
    /// detection (case/whitespace-insensitive). Pure — testable without the model.
    static func newFindings(_ findings: [RedactionFinding], excluding detected: [String]) -> [RedactionFinding] {
        let seen = Set(detected.map { Self.normalizeFindingText($0) })
        return findings.filter { !seen.contains(Self.normalizeFindingText($0.text)) }
    }

    private static func normalizeFindingText(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Map model-found findings to `.contextual` detections in full-image pixel
    /// space, carrying the model's precise type label + reason. Values split
    /// across OCR lines are mapped via `spanRectsAllOccurrences` (every occurrence
    /// of a repeated value; multi-line values via `spanRects`). Pure —
    /// testable without the model.
    static func contextualDetections(findings: [RedactionFinding], in layout: RecognizedTextLayout,
                                     tile: CGRect) -> [Detection] {
        var detections: [Detection] = []
        for finding in findings {
            let rects = spanRectsAllOccurrences(finding.text, in: layout, tile: tile)
            guard !rects.isEmpty else { continue }
            let label = finding.type.trimmingCharacters(in: .whitespacesAndNewlines)
            let why = finding.reason.trimmingCharacters(in: .whitespacesAndNewlines)
            detections.append(Detection(
                category: .contextual,
                snippet: SensitiveTextRules.displaySnippet(for: finding.text.trimmingCharacters(in: .whitespacesAndNewlines)),
                confidence: SensitiveCategory.contextual.baseConfidence,
                rects: DetectionGeometry.mergedRects(rects),
                customLabel: label.isEmpty ? nil : label,
                reason: why.isEmpty ? nil : why))
        }
        return detections
    }

    /// Map engine (GLiNER2) detections to `Detection`s in full-image pixel space,
    /// reusing the same span-location + box mapping as the rule/FM detectors. A
    /// known label maps to its `SensitiveCategory`; an unknown one becomes
    /// `.contextual` carrying the model's label. Values are mapped via
    /// `spanRectsAllOccurrences` (every occurrence; multi-line via `spanRects`).
    /// Pure — testable without MLX.
    static func engineDetections(_ found: [EngineDetection], in layout: RecognizedTextLayout,
                                 tile: CGRect) -> [Detection] {
        var out: [Detection] = []
        for f in found {
            let rects = spanRectsAllOccurrences(f.text, in: layout, tile: tile)
            guard !rects.isEmpty else { continue }
            let mapped = RedactionCategories.category(forEngineLabel: f.label)
            out.append(Detection(
                category: mapped ?? .contextual,
                snippet: SensitiveTextRules.displaySnippet(for: f.text.trimmingCharacters(in: .whitespacesAndNewlines)),
                confidence: f.confidence,
                rects: DetectionGeometry.mergedRects(rects),
                customLabel: mapped == nil ? f.label : nil))
        }
        return out
    }

    /// Map one tile's OCR layout to detections in full-image pixel space.
    /// Pure — separated from `analyze` so the mapping is testable without
    /// Vision.
    ///
    /// `includeContextual` gates only the NLTagger NER layer; the anchored
    /// label→value + address layer always runs (so labeled fields are caught on
    /// the engine path too).
    static func detections(in layout: RecognizedTextLayout, tile: CGRect,
                           falsePositiveTexts: Set<String> = [],
                           includeContextual: Bool = true) -> [Detection] {
        var detections: [Detection] = []
        for line in layout.lines {
            let combined = SensitiveTextRules.combinedMatches(
                in: line.text,
                additional: ContextualDetectors.anchoredMatches(in: line.text)
                    + (includeContextual ? ContextualDetectors.namedEntityMatches(in: line.text) : []))
            for match in combined {
                guard let normalized = DetectionGeometry.normalizedBox(for: match.range,
                                                                       in: line) else { continue }
                let rect = DetectionGeometry.imageRect(fromNormalized: normalized,
                                                       imageSize: tile.size)
                    .offsetBy(dx: tile.minX, dy: tile.minY)
                detections.append(Detection(
                    category: match.category,
                    snippet: SensitiveTextRules.displaySnippet(for: match.text),
                    confidence: dampedConfidence(
                        base: match.category.baseConfidence,
                        isFlaggedFalsePositive: isFalsePositive(match.text, flagged: falsePositiveTexts)),
                    rects: DetectionGeometry.mergedRects([rect])))
            }
        }
        return detections
    }
}
