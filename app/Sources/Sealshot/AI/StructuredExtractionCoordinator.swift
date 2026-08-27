import CoreGraphics

// MARK: - ExtractionStatus

enum ExtractionStatus: Equatable {
    case ok
    case partial(String)
    case failed(String)
}

// MARK: - StructuredExtractionCoordinator

enum StructuredExtractionCoordinator {

    // MARK: Pure merge (fully testable, no Vision/OS imports)

    /// Combines geometry-derived tables, Vision document data, and (future) entity
    /// recognition results into a single `StructuredItems` value plus a status.
    ///
    /// Rules:
    /// - Geometry tables are always added first.
    /// - Vision-native tables that are equal to any geometry table are dropped (dedupe).
    /// - Remaining native tables are appended.
    /// - Detected-data lists (urls, dates, …) come from `doc`.
    /// - `entities` contacts/formFields/codeBlocks/stackTraces/urls/etc. are folded in.
    /// - `.failed(reason)` — the document/OCR step errored AND the final items are empty
    ///   (nothing at all was produced).
    /// - `.partial(reason)` — at least one tier errored but other tiers produced output,
    ///   OR an entity tier errored regardless of output (a sub-pipeline failed).
    /// - `.ok` — no errors.
    static func merge(
        geometryTables: [StructuredTable],
        keyValues: [StructuredField] = [],
        doc: DocumentData?,
        docError: String?,
        entities: StructuredItems?,
        entityError: String?,
        dataDetectorFallback: (urls: [String], phones: [String], addresses: [String], dates: [String]) = ([], [], [], [])
    ) -> (items: StructuredItems, status: ExtractionStatus) {

        var items = StructuredItems()

        // 1. Geometry tables.
        items.tables = geometryTables

        // 1b. Key-value fields (geometric tier) seed formFields.
        items.formFields = keyValues

        // 2. Vision-native tables: dedupe against geometry, append the rest.
        if let nativeTables = doc?.nativeTables {
            for native in nativeTables {
                if !items.tables.contains(native) {
                    items.tables.append(native)
                }
            }
        }

        // 3. Detected-data lists from DocumentData.
        if let doc {
            items.urls       = doc.urls
            items.dates      = doc.dates
            items.emails     = doc.emails
            items.phones     = doc.phones
            items.addresses  = doc.addresses
            items.money      = doc.money
        }

        // 4. Fold in entity items.
        if let entities {
            items.contacts    += entities.contacts
            items.formFields  += entities.formFields
            items.codeBlocks  += entities.codeBlocks
            items.stackTraces += entities.stackTraces
            items.urls        += entities.urls
            items.dates       += entities.dates
            items.emails      += entities.emails
            items.phones      += entities.phones
            items.addresses   += entities.addresses
            items.money       += entities.money
        }

        // Dedup form fields (order-preserving) so a KV pair and an identical
        // entity field don't both appear.
        items.formFields = dedupedFields(items.formFields)

        // 5. Dedup the six detected-data lists (order-preserving unique).
        // This prevents duplicates when both doc and entities contribute the same values.
        items.urls       = deduped(items.urls)
        items.dates      = deduped(items.dates)
        items.emails     = deduped(items.emails)
        items.phones     = deduped(items.phones)
        items.addresses  = deduped(items.addresses)
        items.money      = deduped(items.money)

        // 5b. NSDataDetector fallback — fill only the lists nothing else found, so
        // dates/phones/URLs/addresses still extract when Vision's macOS-26 document
        // detectors are unavailable. Never overwrites richer Vision/entity results.
        if items.urls.isEmpty      { items.urls = deduped(dataDetectorFallback.urls) }
        if items.phones.isEmpty    { items.phones = deduped(dataDetectorFallback.phones) }
        if items.addresses.isEmpty { items.addresses = deduped(dataDetectorFallback.addresses) }
        if items.dates.isEmpty     { items.dates = deduped(dataDetectorFallback.dates) }

        // 6. Determine status.
        let status = computeStatus(
            items: items,
            docError: docError,
            entityError: entityError
        )

        return (items, status)
    }

    private static func dedupedFields(_ list: [StructuredField]) -> [StructuredField] {
        var result: [StructuredField] = []
        for field in list where !result.contains(field) { result.append(field) }
        return result
    }

    private static func deduped(_ list: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for item in list {
            if !seen.contains(item) {
                seen.insert(item)
                result.append(item)
            }
        }
        return result
    }

    private static func computeStatus(
        items: StructuredItems,
        docError: String?,
        entityError: String?
    ) -> ExtractionStatus {

        let hasDocError    = docError != nil
        let hasEntityError = entityError != nil
        let isEmpty        = StructuredExtractionResult.isEmpty(items)

        // .failed: the document step crashed AND nothing else produced output.
        // Combine error messages if both doc and entity tiers failed.
        if hasDocError && isEmpty {
            let reason: String
            if hasEntityError {
                reason = [docError, entityError].compactMap { $0 }.joined(separator: "; ")
            } else {
                reason = docError ?? ""
            }
            return .failed(reason)
        }

        // .partial: any tier errored but we still have some output,
        //           or an entity error occurred (a sub-pipeline failed even if no NER output).
        if hasDocError || hasEntityError {
            let reasons = [docError, entityError].compactMap { $0 }.joined(separator: "; ")
            return .partial(reasons)
        }

        return .ok
    }

    // MARK: Table tier (pure, testable)

    /// Table tier with detection-or-fallback. Detected boxes (≥1) drive
    /// `buildTables(inBoxes:)`; an empty box list falls back to today's geometry.
    static func tableTier(boxes: [CGRect], tokens: [LayoutToken],
                          tolerance: CGFloat, columnSeparation: CGFloat) -> [StructuredTable] {
        if boxes.isEmpty {
            return TableReconstructor.buildTables(
                tokens, tolerance: tolerance, minGap: 0.12, columnSeparation: columnSeparation)
        }
        return TableReconstructor.buildTables(
            inBoxes: boxes, tokens: tokens,
            tolerance: tolerance, columnSeparation: columnSeparation,
            inset: TATRModelContract.tokenInset)
    }

    // MARK: Async orchestration (thin glue — not unit-tested)

    /// Runs the full structured-extraction pipeline on a single image:
    /// 1. OCR-layout (once).
    /// 2. Geometry table reconstruction.
    /// 3. DocumentDataExtractor on macOS 26+ (catch → docError).
    /// 4. `merge(...)` to combine all tiers.
    ///
    /// The GLiNER entity tier wires in later; `entities` is nil for now.
    static func extract(
        image: CGImage,
        recognizer: OCRLayoutRecognizer = OCRLayoutRecognizer(),
        includeTables: Bool = true,
        onProgress: (@MainActor (Double, String) -> Void)? = nil
    ) async -> (items: StructuredItems, status: ExtractionStatus) {

        // Step 1: OCR layout.
        await report(onProgress, .reading)
        let tokens: [LayoutToken]
        do {
            tokens = try await recognizer.recognize(image)
        } catch {
            return merge(geometryTables: [], doc: nil,
                         docError: "OCR failed: \(error.localizedDescription)",
                         entities: nil, entityError: nil)
        }
        if Task.isCancelled {
            return merge(geometryTables: [], doc: nil, docError: nil, entities: nil, entityError: nil)
        }

        // Step 2: Table detection (TATR) → reconstruction, with geometry fallback.
        await report(onProgress, .tables)
        // tolerance = max(0.008, medianTokenHeight * 0.6); fallback to 0.008 on empty.
        let tolerance: CGFloat = {
            guard !tokens.isEmpty else { return 0.008 }
            let heights = tokens.map(\.rect.height).sorted()
            let median  = heights[heights.count / 2]
            return max(0.008, median * 0.6)
        }()

        // Skip the (expensive) TATR table detection entirely when tables aren't
        // wanted — e.g. Markdown extract, where forcing prose into a table garbles it.
        // Also skip on cancel: the detached task doesn't inherit cancellation, so
        // once started the Core ML pass runs to completion in the background.
        let boxes = includeTables && !Task.isCancelled ? await Task.detached(priority: .userInitiated) {
            TATRDetector().detect(image)
        }.value : []
        let geometryTables = includeTables
            ? tableTier(boxes: boxes, tokens: tokens, tolerance: tolerance, columnSeparation: 0.04)
            : []

        // Key-value pairs (geometric tier) from the same tokens.
        let keyValues = KeyValueExtractor.extract(
            tokens, tolerance: tolerance, columnSeparation: 0.04)

        // Step 3: DocumentDataExtractor (macOS 26+ only).
        await report(onProgress, .detecting)
        var doc: DocumentData? = nil
        var docError: String?  = nil

        if #available(macOS 26, *), !Task.isCancelled {
            do {
                doc = try await DocumentDataExtractor().extract(image)
            } catch {
                docError = "DocumentDataExtractor failed: \(error.localizedDescription)"
            }
        }

        // Step 4: GLiNER entity extraction (Apple Silicon only; model must be downloaded).
        await report(onProgress, .entities)
        var entities: StructuredItems? = nil
        var entityError: String? = nil

        if !Task.isCancelled, RedactionEngineLoader.isAppleSilicon {
            let transcript = TableReconstructor.geometryOrderedTranscript(tokens, tolerance: tolerance)
            let modelPath: String? = await MainActor.run {
                if case .ready(let p) = RedactionModelManager.shared.state { return p } else { return nil }
            }
            if let modelPath {
                // Run the blocking engine OFF the main actor (engine load blocks ~1s).
                entities = await Task.detached(priority: .userInitiated) {
                    GLiNERExtractor().extract(transcript: transcript, modelPath: modelPath)
                }.value
            } else {
                entityError = "Enhanced extraction model not downloaded."
            }
        }

        // NSDataDetector fallback from the OCR transcript (all-macOS).
        let ocrTranscript = tokens.map(\.text).joined(separator: "\n")
        let ddFallback = DataDetectorTier.detect(in: ocrTranscript)

        // Step 5: Merge all tiers.
        return merge(geometryTables: geometryTables, keyValues: keyValues, doc: doc, docError: docError,
                     entities: entities, entityError: entityError, dataDetectorFallback: ddFallback)
    }

    /// Emit a stage label + fraction on the main actor, if a callback is set.
    private static func report(_ cb: (@MainActor (Double, String) -> Void)?, _ stage: ExtractionStage) async {
        guard let cb else { return }
        await MainActor.run { cb(stage.fraction, stage.label) }
    }
}
