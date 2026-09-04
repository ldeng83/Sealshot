import AppKit
import CoreGraphics
import ImageIO
import Observation

/// Shared state between `EditorCanvasView`, `EditorWindowController`, and
/// `EditorController`. The controller mutates; views observe.
///
/// Coordinate convention: annotations are in the *currently visible* image's
/// coordinate space (post-crop if a crop is active). `commitCrop()` translates
/// the annotation list so this invariant always holds.
/// Immutable snapshot of the user-mutable parts of `EditorState`.
/// Stored on undo/redo stacks. `pendingCrop` and `selectedTool` /
/// `selectedColor` are NOT snapshotted — undo restores the
/// committed-content state, not the in-flight UI state.
/// The user-editable metadata trio at checkpoint time. Rides on snapshots
/// minted by metadata edits (rename / summary / tags) so ⌘Z can restore the
/// manifest, not just the canvas. Generators write other fields
/// (smartKeywords, generated summary), so those never appear here.
struct MetadataUndoPatch: Equatable, Codable {
    var userTitle: String?
    var userSummary: String?
    var tags: [String]

    init(userTitle: String?, userSummary: String?, tags: [String]) {
        self.userTitle = userTitle
        self.userSummary = userSummary
        self.tags = tags
    }

    init(from meta: CaptureMetadata?) {
        userTitle = meta?.userTitle
        userSummary = meta?.userSummary
        tags = meta?.tags ?? []
    }
}

struct EditorSnapshot: Equatable, Codable {
    let annotations: [Annotation]
    let croppedRect: CGRect?
    /// Region of the source actually shown (source coords); transparent outside.
    /// Set when the canvas is grown past its content so the margin stays
    /// transparent instead of revealing cropped-away source. nil = show all.
    /// Optional/defaulted so histories persisted before it existed keep decoding.
    var contentClip: CGRect? = nil
    let focusRect: CGRect?
    /// The capture's file URL at checkpoint time, so a rename can be undone.
    let sourceURL: URL?
    /// Canvas background fill at checkpoint time (v9). Optional/defaulted so
    /// histories persisted before it existed keep decoding (nil = transparent).
    var backgroundFill: SerializableColor? = nil
    /// When this snapshot was minted — its push order on the app-global
    /// timeline (`GlobalUndoStore`) interleaves ⌘Z across kinds. Optional so
    /// histories persisted before the field existed keep decoding.
    var at: Date?
    /// Human label of the action that produced this transition (e.g. "Add
    /// Arrow", "Move"), surfaced as an undo/redo hint. Rides across the
    /// undo↔redo stacks so redo knows what it's redoing. Optional (defaulted)
    /// for backward compatibility with histories persisted before it existed
    /// and call sites that don't label.
    var action: String? = nil
    /// Whether the background-removal cutout base was displayed at checkpoint
    /// time — lets ⌘Z step across Remove Background toggles. Optional for
    /// pre-existing persisted histories (nil → false).
    var showingCutout: Bool? = nil
    /// Whether the enhanced base was displayed at checkpoint time — makes the
    /// Enhance display toggle a ⌘Z step. Optional (nil → restore leaves the
    /// current setting alone, matching pre-field histories).
    var showingEnhanced: Bool? = nil
    /// The zoom factor at checkpoint time — zoom actions are ⌘Z steps
    /// (coalesced per gesture burst); any restore also lands the view at the
    /// zoom it had then. Optional for pre-existing histories (nil = leave).
    var zoom: CGFloat? = nil
    /// The FULL base-image pixel size at checkpoint time. Snapshots are
    /// self-describing about their coordinate space, so ⌘Z can step ACROSS a
    /// document Resize: restoring a snapshot whose size differs first
    /// resamples the document from the pristine source to this size (the
    /// controller orchestrates that rebuild), then applies the snapshot
    /// verbatim. nil (pre-field histories) = same size as current.
    var sourceImageSize: CGSize? = nil
    /// PRE-edit metadata trio for steps minted by a metadata edit (rename /
    /// summary / tags); nil on every other step means "leave the manifest
    /// alone". Optional for pre-existing persisted histories.
    var metadata: MetadataUndoPatch? = nil
}


enum BottomTab: Equatable {
    case recent
    case deleted
}

@MainActor
@Observable
final class EditorState {
    let sourceImage: CGImage
    var sourceURL: URL?

    /// Small already-decoded stand-in (the package's 720px thumbnail) drawn
    /// while the real base is still being decoded off the main thread. Decoding
    /// a full capture costs ~45ms on an Intel Mac and used to land on the main
    /// thread during the first draw after a switch, stalling the capture strip.
    /// nil for packages with no thumbnail entry — the old behaviour then.
    var placeholderImage: CGImage?

    /// The 2× enhanced bitmap, nil until enhanced or loaded from a v2 package.
    var enhancedImage: CGImage?
    /// True while an enhance run is in flight — the Enhance panel disables its
    /// controls (the overlay's Cancel is the only affordance mid-run).
    /// Transient, never persisted.
    var enhanceRunning: Bool = false
    /// Which base is displayed (true = enhanced). Only meaningful when
    /// `enhancedImage != nil`.
    ///
    /// Any change here is the USER deciding, which retires a speed-suppressed
    /// open: from then on the live value is what saves should record. Without
    /// this, turning Enhance off by hand after a suppressed open would keep
    /// persisting the old `true`.
    var showingEnhanced: Bool = false {
        didSet { enhanceOpenSuppressedRestore = nil }
    }

    /// Transparent background-removed base (same pixel size as `sourceImage`),
    /// nil until computed or loaded from the package (`cutout.png`).
    /// Non-destructive: a toggle-able alternate base like the enhanced image.
    var cutoutImage: CGImage?
    /// Whether the cutout base is displayed. Mutually exclusive with the
    /// enhanced base — set via `setShowingCutout` so the exclusion holds.
    var showingCutout: Bool = false

    /// Toggle the cutout display; enabling it hides the enhanced base (both
    /// are alternate bases — only one shows at a time).
    func setShowingCutout(_ on: Bool) {
        showingCutout = on && cutoutImage != nil
        if showingCutout { showingEnhanced = false }
        markDirty()
    }
    /// Applied clarity params baked into `enhancedImage` (persisted in the .seal).
    var enhanceParams: EnhanceParams = .default
    /// In-memory working copy the Enhance panel edits; Apply is enabled when it
    /// differs from `enhanceParams` (or no `enhancedImage` exists yet).
    var enhanceDraft: EnhanceParams = .default

    /// True while the Enhance sidebar panel is open. Transient UI state — not
    /// persisted, not part of the undo/redo stacks. Cleared whenever a drawing
    /// tool is selected or the Info panel is toggled on.
    var enhanceEditing = false

    /// True when the source file is in the Deleted folder. Blocks the
    /// canvas from creating/modifying annotations and the save coordinator
    /// from persisting changes. Set by EditorController.presentFile based
    /// on whether the URL lives under `<saveFolder>/Deleted/`.
    var isReadOnly: Bool = false

    var annotations: [Annotation] = []

    /// Live Capture: original (as-captured) rect per window layer, keyed by the
    /// `.image` annotation's assetID. Empty for non-scene captures. Used by the
    /// scene-aware `revertedToOriginal()` to restore the captured layout. Not
    /// persisted on the state itself — persistence is `manifest.sceneLayers`
    /// (written by LiveCaptureWriter).
    @ObservationIgnored var sceneOriginalFrames: [String: CGRect] = [:]

    /// The asset the object menu's "Export This Window…" should write for a
    /// right-click that landed on `hit`, or nil when the command doesn't apply
    /// (not a scene, no hit, not an image layer, or its PNG is missing —
    /// offering an export that silently writes nothing is worse than not
    /// offering it).
    ///
    /// Deliberately resolved from the CLICKED annotation, never from the
    /// selection: `EditorCanvasView.menu(for:)` retargets the selection only
    /// when the hit object isn't already selected, so right-clicking a member
    /// of a multi-selection leaves `selectedAnnotation` on the last-clicked
    /// window — a different one than the pointer is over.
    nonisolated static func exportableWindowAssetID(hit: UUID?,
                                                    annotations: [Annotation],
                                                    imageAssets: [String: Data],
                                                    isScene: Bool) -> String? {
        guard isScene, let hit,
              case let .image(_, assetID)? = annotations.first(where: { $0.id == hit })?.geometry,
              imageAssets[assetID] != nil else { return nil }
        return assetID
    }

    // MARK: - Image overlay assets

    /// Bitmap payloads for `.image` annotations, keyed by assetID; written
    /// into the package as `asset-<id>.png` on save. NEVER pruned in v1 —
    /// deleted annotations may be undone (incl. via persistent history), and
    /// stale bytes are preferable to a broken undo.
    var imageAssets: [String: Data] = [:]

    /// Decode cache for rendering. Not serialized.
    private var decodedAssets: [String: CGImage] = [:]

    /// Decoded bitmap for `assetID`, cached after the first decode.
    func assetImage(_ assetID: String) -> CGImage? {
        if let hit = decodedAssets[assetID] { return hit }
        guard let data = imageAssets[assetID],
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        decodedAssets[assetID] = img
        return img
    }

    /// All decoded assets, for the export renderer.
    func decodedImageAssets() -> [String: CGImage] {
        for id in imageAssets.keys { _ = assetImage(id) }
        return decodedAssets
    }

    /// Register pasted/loaded asset bytes (no checkpoint; callers own undo).
    func registerImageAsset(id: String, data: Data) {
        imageAssets[id] = data
        decodedAssets[id] = nil
    }

    /// Insert `image` as an overlay annotation centered at `point` (image
    /// space; nil = canvas center), downscaled for storage if larger than
    /// the canvas. One undo step; the new annotation becomes the selection.
    /// `atNaturalSize` keeps every pixel of `image` and lands it at the canvas
    /// origin, instead of capping the stored asset to the canvas and placing it
    /// at half the canvas's smaller side. For callers that grow the CANVAS to
    /// the image rather than shrinking the image onto the canvas — without it
    /// the canvas would grow around an already-downscaled, soft copy.
    func insertImageAnnotation(_ image: CGImage, at point: CGPoint?, recordUndo: Bool = true,
                               atNaturalSize: Bool = false) {
        let canvas = CGSize(width: sourceImage.width, height: sourceImage.height)
        let natural = CGSize(width: image.width, height: image.height)
        let target = atNaturalSize ? natural
            : overlayAssetTargetSize(imageSize: natural, canvasPixels: canvas)
        let stored = (Int(target.width) == image.width && Int(target.height) == image.height)
            ? image : (downscaledImage(image, to: target) ?? image)
        guard let png = try? CaptureOutputWriter.encodePNG(stored) else { return }
        let assetID = UUID().uuidString
        if recordUndo { recordUndoCheckpoint(action: "Insert Image") }
        imageAssets[assetID] = png
        decodedAssets[assetID] = stored
        let rect = atNaturalSize
            ? CGRect(origin: .zero, size: natural)
            : overlayInsertRect(
                imageSize: CGSize(width: stored.width, height: stored.height),
                canvas: canvas, at: point)
        let annotation = Annotation(
            geometry: .image(rect: rect, assetID: assetID),
            style: Style(strokeColor: SerializableColor(NSColor.black), strokeWidth: 0,
                         opacity: 1.0))
        annotations.append(annotation)
        selectedAnnotationID = annotation.id
    }

    /// Swap the bitmap behind an existing image annotation; the rect re-fits
    /// to the new aspect around its center. One undo step.
    func replaceImageAsset(annotationID: UUID, with image: CGImage) {
        guard let idx = annotations.firstIndex(where: { $0.id == annotationID }),
              case let .image(rect, _) = annotations[idx].geometry else { return }
        let canvas = CGSize(width: sourceImage.width, height: sourceImage.height)
        let target = overlayAssetTargetSize(
            imageSize: CGSize(width: image.width, height: image.height),
            canvasPixels: canvas)
        let stored = (Int(target.width) == image.width && Int(target.height) == image.height)
            ? image : (downscaledImage(image, to: target) ?? image)
        guard let png = try? CaptureOutputWriter.encodePNG(stored) else { return }
        let assetID = UUID().uuidString
        recordUndoCheckpoint(action: "Replace Image")
        imageAssets[assetID] = png
        decodedAssets[assetID] = stored
        annotations[idx].geometry = .image(
            rect: replacementFitRect(current: rect,
                                     newImageSize: CGSize(width: stored.width,
                                                          height: stored.height)),
            assetID: assetID)
    }

    /// Scale `image` down to `size` using high-quality interpolation.
    private func downscaledImage(_ image: CGImage, to size: CGSize) -> CGImage? {
        let w = Int(size.width), h = Int(size.height)
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// Committed crop rect in *original* image coordinates. `nil` means no
    /// crop. The cropped image is what the canvas displays and what gets
    /// saved.
    var croppedRect: CGRect?

    /// When the visible canvas has been GROWN past its content (an annotation
    /// dropped off the edge), this is the region of the source that's actually
    /// shown (source coords); everything outside it is transparent, so the grown
    /// margin never reveals cropped-away source. nil = no grow (show all source
    /// within `croppedRect`). `croppedRect` then acts as the grown canvas/viewport
    /// while this holds the content window. Cleared by Revert to Original / crop.
    var contentClip: CGRect?

    /// Pending crop being drawn by the user — set when the user mouseUp's
    /// the marquee, cleared on commit/abandon. While non-nil the canvas
    /// renders the marquee preview (dimmed exterior, blue outline).
    var pendingCrop: CGRect? = nil

    /// Live focus rect while a focus anchor is being dragged (image space). The
    /// canvas reads it to draw the exterior dim; the chrome overlay sets it
    /// during the drag and clears it on commit.
    var focusWorkingRect: CGRect? = nil

    /// Rubber-band selection rect (image space) while a marquee drag is active;
    /// nil otherwise. Written by EditorCanvasView's marquee drag, DRAWN by the
    /// SelectionChromeOverlay so its outline stays a constant on-screen weight.
    var marqueeRect: CGRect? = nil

    /// Non-destructive focus crop, in the *currently visible* image coordinate
    /// space (post-`croppedRect`). `nil` = no focus crop: anchors cover the full
    /// visible image, nothing is dimmed. Output (export/copy/thumbnail) is
    /// cropped to this; the on-screen canvas keeps the full image + dim.
    var focusRect: CGRect?

    /// Solid fill drawn BEHIND the base image (shows through the base's
    /// transparent regions and fills a blank canvas). `nil` = transparent
    /// (the canvas shows a checkerboard). Persisted (annotations envelope v9)
    /// and undoable.
    var backgroundFill: SerializableColor?

    /// Size of the currently visible image (post destructive crop).
    var visibleImageSize: CGSize {
        croppedRect?.size ?? CGSize(width: sourceImage.width, height: sourceImage.height)
    }

    /// The rect the overlay handles operate on — `focusRect` or, when nil, the
    /// full visible bounds.
    var effectiveFocusRect: CGRect {
        focusRect ?? CGRect(origin: .zero, size: visibleImageSize)
    }

    /// True when there is no real focus sub-region — no focus, or a focus that
    /// covers essentially the whole visible image (tolerant to sub-pixel drag
    /// results). "Crop to Focus Area" / "Reset Focus Area" are no-ops then.
    var focusIsFullImage: Bool {
        guard let f = focusRect else { return true }
        let full = CGRect(origin: .zero, size: visibleImageSize)
        return abs(f.minX - full.minX) < 1 && abs(f.minY - full.minY) < 1
            && abs(f.maxX - full.maxX) < 1 && abs(f.maxY - full.maxY) < 1
    }

    /// Region to OCR for AI text actions, in source-image pixel space: the focus
    /// area when set (it's in visible/post-crop space, so offset by the crop
    /// origin), else the crop, else the whole image. Pure for testing.
    nonisolated static func aiOCRRect(sourceSize: CGSize,
                                      croppedRect: CGRect?,
                                      focusRect: CGRect?) -> CGRect {
        let base = croppedRect ?? CGRect(origin: .zero, size: sourceSize)
        guard let focus = focusRect else { return base }
        return CGRect(x: base.origin.x + focus.origin.x,
                      y: base.origin.y + focus.origin.y,
                      width: focus.width, height: focus.height)
    }

    /// Non-nil while a text box is being edited; drives the sidebar's live text
    /// styling panel. Transient UI state — never persisted or put on the undo stack.
    var activeTextEditing: TextEditingSession?

    /// Smart-redaction scan lifecycle (see `EditorState+SmartRedaction`).
    /// Transient UI state — never persisted or put on the undo stack.
    /// Proposal rects are bound to the *currently visible* image space, so
    /// anything that changes that space (crop, undo/redo) resets this to idle;
    /// a re-scan is cheap and always available.
    var redactionScan: RedactionScanState = .idle {
        didSet {
            if oldValue.phase != redactionScan.phase { redactionReviewGeneration &+= 1 }
        }
    }

    /// Bumped only when the scan PHASE changes (idle/scanning/found/empty) —
    /// the sidebar's rebuild key for the review panel. Kept-flag toggles
    /// mutate `redactionScan` without changing phase, so the panel is NOT
    /// rebuilt (a rebuild flashes the list and drops hover state); rows keep
    /// their own checkboxes current instead.
    var redactionReviewGeneration = 0

    /// Proposal row hovered in the review panel — the canvas emphasizes its
    /// rects so the user can tell which row maps to which region. Transient.
    var redactionFocusID: UUID? = nil

    /// Review-list scroll offset, preserved across sidebar rebuilds (toggling
    /// a checkbox mutates `redactionScan`, which rebuilds the whole panel — a
    /// fresh scroll view would snap back to the top). Deliberately unobserved:
    /// scroll position must never itself trigger a rebuild.
    @ObservationIgnored var redactionListScrollOffset: CGFloat = 0

    var selectedTool: EditorTool = .select {
        didSet {
            if selectedTool != oldValue {
                pendingCrop = nil
                // Selection persists in the neutral Select/Hand tools; switching
                // to a drawing/crop tool clears it.
                if selectedTool != .select && selectedTool != .hand {
                    selectedAnnotationIDs = []
                    primarySelectionID = nil
                }
                // Sidebar-owning modes are peers of the tools: picking ANY tool
                // exits them so the tool's controls (or layers list) show.
                sidebarPanelMode = sidebarPanelMode.afterToolSelected()
                activateToolColors(for: selectedTool)
                activateToolOpacity(for: selectedTool)
            }
        }
    }

    var selectedColor: NSColor = .red {
        didSet { persistLiveColor(.stroke) }
    }

    /// Contrasting outline (casing) color used when CREATING the next
    /// pen/line/arrow/shape/step. `nil` = no outline (the default). Per-tool,
    /// like every other creation color.
    var selectedOutlineColor: NSColor? = nil {
        didSet { persistLiveColor(.outline) }
    }

    /// Fill color used when CREATING the next rectangle or ellipse. `nil` = no
    /// fill (outline only). Existing shapes keep their stored fill unchanged.
    var shapeFillColor: NSColor? = nil {
        didSet { persistLiveColor(.fill) }
    }

    /// Fill / number colors used when CREATING the next badge. Existing badges
    /// keep their stored colors.
    var badgeFillColor: NSColor = .systemRed {
        didSet { persistLiveColor(.badgeFill) }
    }
    var badgeNumberColor: NSColor = .white {
        didSet { persistLiveColor(.badgeNumber) }
    }
    /// Radius (image space) used when CREATING the next badge by a click.
    /// Existing badges keep their stored radius.
    var badgeRadius: CGFloat = 34   // 50% of the 8…60 size slider

    // MARK: Per-tool color memory

    /// The live color vars above (`selectedColor`, `shapeFillColor`, badge and
    /// blur colors) always hold the ACTIVE tool's colors. Switching tools
    /// swaps them through `toolColorStore` (persisted, per tool × role), so
    /// changing the pen's color never repaints the next rectangle — the same
    /// per-tool memory `strokeWidthByTool` and `ToolShadowDefaults` already
    /// provide for width and shadows. Every live change writes through
    /// immediately; activation only loads.
    @ObservationIgnored private var toolColorStore = ToolColorDefaults()
    /// Which tool the live color vars currently belong to. Survives visits to
    /// non-drawing tools (Select/Hand/Crop), which own no colors.
    @ObservationIgnored private var toolColorOwner: EditorTool?
    /// Suppresses write-through while activation loads stored values.
    @ObservationIgnored private var isLoadingToolColors = false

    /// The color slots a tool exposes. Tools absent here (Select, Hand, Crop,
    /// Live Text) have no creation colors.
    static func colorRoles(for tool: EditorTool) -> [ToolColorRole] {
        switch tool {
        case .pen, .line, .arrow, .penArrow: return [.stroke, .outline]
        case .text: return [.stroke]   // text has its own per-run outline
        case .rectangle, .ellipse: return [.stroke, .fill, .outline]
        case .badge: return [.badgeFill, .badgeNumber, .outline]
        case .blur: return [.blurSolid]
        case .select, .hand, .textSelect, .crop: return []
        }
    }

    /// Built-in default per role — what a never-customized tool starts with
    /// (matches the live vars' declared defaults, so behavior is unchanged
    /// until the user picks colors).
    private static func builtInColorDefault(_ role: ToolColorRole) -> SerializableColor? {
        switch role {
        case .stroke: return SerializableColor(.red)
        case .fill: return nil
        case .badgeFill: return SerializableColor(.systemRed)
        case .badgeNumber: return SerializableColor(.white)
        case .blurSolid: return SerializableColor(NSColor(white: 0.13, alpha: 1))
        case .outline: return nil   // off by default
        }
    }

    private func liveColor(_ role: ToolColorRole) -> SerializableColor? {
        switch role {
        case .stroke: return SerializableColor(selectedColor)
        case .fill: return shapeFillColor.map { SerializableColor($0) }
        case .badgeFill: return SerializableColor(badgeFillColor)
        case .badgeNumber: return SerializableColor(badgeNumberColor)
        case .blurSolid: return SerializableColor(blurSolidColor)
        case .outline: return selectedOutlineColor.map { SerializableColor($0) }
        }
    }

    private func setLiveColor(_ value: SerializableColor?, _ role: ToolColorRole) {
        switch role {
        case .stroke: if let v = value { selectedColor = v.nsColor }
        case .fill: shapeFillColor = value?.nsColor
        case .badgeFill: if let v = value { badgeFillColor = v.nsColor }
        case .badgeNumber: if let v = value { badgeNumberColor = v.nsColor }
        case .blurSolid: if let v = value { blurSolidColor = v.nsColor }
        case .outline: selectedOutlineColor = value?.nsColor
        }
    }

    /// Write-through from a live var's didSet to the owning tool's slot.
    private func persistLiveColor(_ role: ToolColorRole) {
        guard !isLoadingToolColors, let owner = toolColorOwner,
              Self.colorRoles(for: owner).contains(role) else { return }
        toolColorStore.set(liveColor(role), role, for: owner)
    }

    /// Make `tool` the owner of the live color vars, loading its remembered
    /// colors (or built-in defaults). No-op for colorless tools, so the live
    /// values persist across Select/Hand visits.
    func activateToolColors(for tool: EditorTool) {
        let roles = Self.colorRoles(for: tool)
        guard !roles.isEmpty, tool != toolColorOwner else { return }
        toolColorOwner = tool
        isLoadingToolColors = true
        defer { isLoadingToolColors = false }
        for role in roles {
            if let stored = toolColorStore.color(role, for: tool) {
                setLiveColor(stored, role)
            } else {
                setLiveColor(Self.builtInColorDefault(role), role)
            }
        }
    }

    // MARK: Per-tool opacity memory

    /// The live `creationOpacity` var always holds the ACTIVE tool's opacity.
    /// Switching tools swaps it through `toolOpacityStore` (persisted, per
    /// tool), so lowering the arrow's opacity never dims the next rectangle —
    /// the exact per-tool memory the color/width/shadow defaults already
    /// provide. Every live change writes through immediately; activation only
    /// loads.
    @ObservationIgnored private var toolOpacityStore = ToolOpacityDefaults()
    /// Which tool the live `creationOpacity` currently belongs to. Survives
    /// visits to opacity-less tools (Blur/Select/Hand/Crop).
    @ObservationIgnored private var toolOpacityOwner: EditorTool?
    /// Suppresses write-through while activation loads the stored value.
    @ObservationIgnored private var isLoadingToolOpacity = false

    /// Tools that expose a creation-opacity default. Blur is always fully
    /// opaque (its strength/solid-opacity are separate), and the neutral tools
    /// own no opacity, so those are absent — activation is a no-op for them and
    /// the live value persists across their visits.
    static func hasOpacityDefault(for tool: EditorTool) -> Bool {
        switch tool {
        case .pen, .line, .arrow, .penArrow, .rectangle, .ellipse, .badge, .text: return true
        case .blur, .select, .hand, .textSelect, .crop: return false
        }
    }

    /// Built-in opacity a never-customized tool starts with (matches the live
    /// var's declared default, so behavior is unchanged until the user picks).
    private static let builtInOpacityDefault: Double = 1.0

    /// Write-through from `creationOpacity`'s didSet to the owning tool's slot.
    private func persistLiveOpacity() {
        guard !isLoadingToolOpacity, let owner = toolOpacityOwner,
              Self.hasOpacityDefault(for: owner) else { return }
        toolOpacityStore.set(creationOpacity, for: owner)
    }

    /// Make `tool` the owner of the live `creationOpacity`, loading its
    /// remembered opacity (or the built-in default). No-op for opacity-less
    /// tools, so the live value persists across Blur/Select visits.
    func activateToolOpacity(for tool: EditorTool) {
        guard Self.hasOpacityDefault(for: tool), tool != toolOpacityOwner else { return }
        toolOpacityOwner = tool
        isLoadingToolOpacity = true
        defer { isLoadingToolOpacity = false }
        creationOpacity = toolOpacityStore.opacity(for: tool) ?? Self.builtInOpacityDefault
    }

    /// Remember an inline-committed text box's stroke color + opacity as the
    /// Text tool's creation defaults. Writes straight to the persisted stores
    /// and updates the live vars ONLY if `.text` still owns them — so committing
    /// a text edit by switching to another tool (which already re-took the live
    /// vars) never repaints that tool with the text's color/opacity. Called from
    /// the inline-edit commit path, which bypasses the object-panel adopt hooks.
    func rememberTextToolStyle(color: NSColor, opacity: Double) {
        toolColorStore.set(SerializableColor(color), .stroke, for: .text)
        toolOpacityStore.set(opacity, for: .text)
        if toolColorOwner == .text { selectedColor = color }
        if toolOpacityOwner == .text { creationOpacity = opacity }
    }

    /// Per-tool remembered shadow defaults (persisted). Editing one tool's
    /// shadow never affects another. New objects inherit their tool's value.
    private var toolShadowDefaults = ToolShadowDefaults()

    func shadowDefault(for tool: EditorTool) -> ShadowStyle {
        toolShadowDefaults.shadow(for: tool)
    }
    func setShadowDefault(_ shadow: ShadowStyle, for tool: EditorTool) {
        toolShadowDefaults.set(shadow, for: tool)
    }

    /// All currently-selected annotations. Source of truth for selection
    /// outlines, delete, and copy/cut. Cleared when the user switches to a
    /// drawing/crop tool (selection persists only in `.select`) or clicks
    /// empty canvas.
    var selectedAnnotationIDs: Set<UUID> = []

    /// The last-clicked member of `selectedAnnotationIDs` — drives the Object
    /// panel and the resize handles. Invariant: `nil` iff the set is empty,
    /// otherwise a member of the set.
    var primarySelectionID: UUID? = nil

    /// Annotation currently under the pointer (hover), independent of the
    /// selection. Observed by SelectionChromeOverlay to draw hover anchor-dots.
    /// Written by EditorCanvasView's mouse-tracking code.
    var hoveredAnnotationID: UUID? = nil

    /// Annotation currently open in the inline text editor; chrome (canvas body
    /// fill + overlay handles) skips it so editing is not obscured.
    var editingAnnotationID: UUID? = nil

    /// Objects whose row is expanded in the Select-tool layers list. Transient
    /// UI state — observed by the sidebar so toggling rebuilds the panel, but
    /// NOT part of `EditorSnapshot` (never on the undo/redo stacks). Stale ids
    /// (after a delete/undo) are harmless: the list only renders ids that still
    /// exist in `annotations`.
    var expandedObjectIDs: Set<UUID> = []

    /// Toggle whether `id`'s row is expanded in the objects list.
    func toggleExpanded(_ id: UUID) {
        if expandedObjectIDs.contains(id) { expandedObjectIDs.remove(id) }
        else { expandedObjectIDs.insert(id) }
    }

    /// The video `.seal` currently playing in the canvas, if any. Set by
    /// EditorWindowController.playVideoInCanvas / dismissCanvasVideo; observed by
    /// the sidebar so Info mode shows the playing recording's info, not the image.
    var playingVideoURL: URL? = nil

    /// Progress (0…1) of the open recording's on-the-fly summary generation, or
    /// nil when not generating. Drives the determinate "Summarizing video…" bar in
    /// the video Info panel. Set by EditorWindowController.
    var videoSummaryProgress: Double? = nil

    /// True while the open recording's tags are being generated (the video
    /// metadata pass). Drives the indeterminate "Generating tags…" bar in the
    /// video Info panel, mirroring `isGeneratingTags` for images. Set by
    /// EditorWindowController from `VideoMetadataCoordinator` notifications.
    var isGeneratingVideoTags: Bool = false

    /// What the right sidebar is currently showing (Properties, Info, or Find).
    /// Observed by the sidebar (to swap content) and the window (to highlight
    /// the toolbar 'i' pill), but NOT part of `EditorSnapshot` (never on the
    /// undo/redo stacks). Info is now a transient mode (like a tool) — not
    /// persisted — so the editor always opens in Properties.
    var sidebarPanelMode: SidebarPanelMode = .info

    /// Transient Find in Image inputs and result state. These are intentionally
    /// outside snapshots/undo: searching never edits the capture or its export.
    var imageTextSearchQuery: String = ""
    var imageTextSearchScope: ImageTextSearchScope = .wholeImage
    var imageTextSearchStatus: ImageTextSearchStatus = .idle
    var imageTextSearchScanStage: ImageTextSearchScanStage = .ready

    /// Whether Info MODE is active — drives the toolbar 'i' pill highlight.
    /// 'i' behaves like a tool button: it stays lit while Info mode is on, even
    /// when a selected object temporarily shows its properties in the sidebar
    /// (selecting an object never changes the toolbar highlight). Whether Info is
    /// actually the panel ON SCREEN is a separate, selection-gated decision the
    /// sidebar makes via `SidebarPanelMode.showsInfo(...)`.
    var showsInfoPanel: Bool { sidebarPanelMode.isInfo }
    var showsImageTextSearchPanel: Bool { sidebarPanelMode.isImageTextSearch }

    /// True when file Info is actually the thing ON SCREEN — Info mode is on AND
    /// nothing is selected (the sidebar yields to a selection's properties). This
    /// is what the pill's show/no-op decision keys on, matching the sidebar's own
    /// `SidebarPanelMode.showsInfo`.
    private var infoIsDisplayed: Bool {
        sidebarPanelMode == .info && selectedAnnotationIDs.isEmpty
    }

    /// Show file Info from the toolbar 'i' pill. The pill behaves like a tool
    /// button, not an on/off switch: clicking it when Info is already on screen
    /// does nothing (Info keeps displaying). Entering Info clears any object
    /// selection, because the sidebar only DISPLAYS Info when nothing is selected
    /// — without this, clicking 'i' with a just-drawn (auto-selected) object lit
    /// the pill but left the object's properties on screen instead of Info.
    func showInfoPanel() {
        guard !infoIsDisplayed else { return }
        clearSelection()
        sidebarPanelMode = .info
        enhanceEditing = false
    }

    /// Show Find in Image as an exclusive toolbar/sidebar mode. The controller
    /// arms Live Text underneath to reuse its full OCR pipeline, while Search
    /// alone owns the visible highlight. Search never creates an undo checkpoint.
    func showImageTextSearchPanel() {
        clearSelection()
        if focusRect == nil { imageTextSearchScope = .wholeImage }
        imageTextSearchStatus = .recognizing
        imageTextSearchScanStage = .recognizingCurrentBase
        sidebarPanelMode = .imageTextSearch
        enhanceEditing = false
    }

    /// Toggle file Info on/off from the View menu ("Show / Hide Info Panel"). A
    /// true toggle: hide when Info is on screen, otherwise show it (clearing the
    /// selection so it actually displays, same as `showInfoPanel`). The active
    /// tool is left untouched — its pill is just de-highlighted while 'i' is on.
    func toggleInfoPanel() {
        if infoIsDisplayed {
            sidebarPanelMode = .properties
        } else {
            clearSelection()
            sidebarPanelMode = .info
        }
        enhanceEditing = false
    }

    /// Esc's resting state: drop to the neutral Select tool but surface file
    /// Info (the 'i' pill), rather than leaving a drawing tool armed. The tool
    /// must be set first — `selectedTool.didSet` forces Info off via
    /// `afterToolSelected()`, so Info is turned on afterwards.
    func escapeToInfo() {
        selectedTool = .select
        sidebarPanelMode = .info
        enhanceEditing = false
    }

    /// The user picked a tool from the toolbar. Always exits Info — including the
    /// case where the tool is unchanged (e.g. clicking Select while Select is the
    /// active tool and Info is on), which `selectedTool.didSet` can't catch
    /// because it only fires on a change. Without this the 'i' pill and the tool
    /// pill would both stay highlighted.
    func userSelectedTool(_ tool: EditorTool) {
        let wasSearching = sidebarPanelMode.isImageTextSearch
        selectedTool = tool
        sidebarPanelMode = .properties
        if wasSearching {
            imageTextSearchScanStage = .ready
            imageTextSearchStatus = .idle
        }
        enhanceEditing = false
    }

    /// True while a slider drag is interactively mutating a style. The sidebar
    /// skips its rebuild while this is set, so the live slider isn't destroyed
    /// and recreated mid-drag (which made the inline objects-list sliders jump).
    var styleEditingInProgress: Bool = false

    /// Bumped once when an interactive style edit ends, to force a single
    /// sidebar rebuild (the skipped rebuilds during the drag are coalesced
    /// into this one).
    var sidebarRefreshToken: Int = 0

    /// True while this image's tags are being (re)generated — drives the Info
    /// panel's Tags progress bar.
    var isGeneratingTags: Bool = false
    /// Stepped 0…1 progress for the open image's tag / summary generation,
    /// reported at real pipeline milestones (OCR → generated → done) by
    /// MetadataCoordinator. nil when not generating. Drive determinate bars.
    var imageTagsProgress: Double? = nil
    var imageSummaryProgress: Double? = nil
    /// True while this image's summary is being generated — drives the Info
    /// panel's Summary progress bar.
    var isGeneratingSummary: Bool = false

    /// Begin an interactive style edit (slider drag): suppress sidebar rebuilds.
    func beginStyleEdit() { styleEditingInProgress = true }

    /// End an interactive style edit: re-enable rebuilds and trigger one.
    func endStyleEdit() {
        styleEditingInProgress = false
        sidebarRefreshToken &+= 1
    }

    /// Backward-compatible single-selection accessor. Reads the primary
    /// selection; writing replaces the whole selection with the given id
    /// (or clears it). Existing single-select call sites keep working.
    var selectedAnnotationID: UUID? {
        get { primarySelectionID }
        set {
            if let id = newValue {
                selectedAnnotationIDs = [id]
                primarySelectionID = id
            } else {
                selectedAnnotationIDs = []
                primarySelectionID = nil
            }
        }
    }

    /// Current canvas zoom. 1.0 = native pixels (100% / Original); range
    /// [0.25, 1.0] — capped at 100% so the image never upscales / blurs.
    /// Driven by the meta-row buttons and ⌘+/⌘−/⌘0.
    var zoom: CGFloat = 1.0

    /// Which strip the bottom area currently shows.
    var bottomTab: BottomTab = .recent

    /// Per-tool creation stroke width. Each drawing tool remembers its own
    /// width so changing it for, say, Arrow doesn't bleed into Rectangle.
    /// Existing annotations keep their stored stroke width unchanged.
    private var strokeWidthByTool: [EditorTool: CGFloat] = [:]

    /// Stroke width used when CREATING the next annotation with the *active*
    /// tool. Reads/writes the active tool's slot, defaulting to 4.0.
    var strokeWidth: CGFloat {
        get { strokeWidthByTool[selectedTool] ?? 4.0 }
        set { strokeWidthByTool[selectedTool] = newValue }
    }

    /// Per-tool creation outline width (paired with `selectedOutlineColor`), so
    /// each tool remembers its own casing thickness. Existing annotations keep
    /// their stored `Style.outlineWidth`.
    private var outlineWidthByTool: [EditorTool: CGFloat] = [:]

    /// Outline width used when CREATING the next annotation with the *active*
    /// tool. Reads/writes the active tool's slot, defaulting to 3.0.
    var outlineWidth: CGFloat {
        get { outlineWidthByTool[selectedTool] ?? 3.0 }
        set { outlineWidthByTool[selectedTool] = newValue }
    }

    /// Per-tool shaft dash style, so Arrow and Line remember their own. Existing
    /// annotations keep their stored `Style.dashStyle`.
    private var dashStyleByTool: [EditorTool: DashStyle] = [:]

    /// Shaft dash style used when CREATING the next arrow/line with the *active*
    /// tool. Reads/writes the active tool's slot, defaulting to `.solid`.
    var dashStyle: DashStyle {
        get { dashStyleByTool[selectedTool] ?? .solid }
        set { dashStyleByTool[selectedTool] = newValue }
    }

    /// Cap drawn at the START of the next arrow. Default `.none` (single-headed).
    var arrowStartCap: ArrowCap = .none

    /// Cap drawn at the END of the next arrow. Default `.filled` (single-headed).
    var arrowEndCap: ArrowCap = .filled

    /// Shaft profile of the next STRAIGHT arrow. `.tapered` is the product
    /// default — wide at the head, narrowing to the tail. Freehand (pen)
    /// arrows always render uniform and ignore this.
    var arrowShaftStyle: ShaftStyle = .tapered

    /// Opacity used when CREATING the next annotation (0...1), shared across
    /// tools like `selectedColor`/`strokeWidth`. Existing annotations keep
    /// their stored opacity.
    var creationOpacity: Double = 1.0 {
        didSet { persistLiveOpacity() }
    }

    /// Corner radius used when CREATING the next rectangle. Ignored by other
    /// geometries; existing rectangles keep their stored radius. Defaults to the
    /// midpoint (50%) of the toolbar's 0–40 corner-radius slider.
    var shapeCornerRadius: CGFloat = 20

    // Typographic defaults for the next text box, remembered across launches
    // (persisted as one `TextTypographyDefaults` blob via the `didSet`s below).
    // Color and opacity are NOT here — those are per-tool creation defaults
    // (`selectedColor` / `creationOpacity`). Written by the Text-tool default
    // panel and re-captured when a text edit commits; read by the text
    // creation-style builders. Existing boxes keep their own stored values.

    /// Font size used when CREATING the next text box.
    var textFontSize: CGFloat = 18 { didSet { persistTextTypography() } }

    /// Bold flag used when CREATING the next text box.
    var textIsBold: Bool = false { didSet { persistTextTypography() } }

    /// Font family used when CREATING the next text box (`nil` = System).
    var textFontFamily: String? = AnnotationTextFont.remembered { didSet { persistTextTypography() } }

    var textWeight: TextWeight? = nil { didSet { persistTextTypography() } }
    var textIsItalic: Bool = false { didSet { persistTextTypography() } }
    var textUnderline: Bool = false { didSet { persistTextTypography() } }
    var textStrikethrough: Bool = false { didSet { persistTextTypography() } }
    var textHighlight: NSColor? = nil { didSet { persistTextTypography() } }
    var textOutlineColor: NSColor? = nil { didSet { persistTextTypography() } }
    var textOutlineWidth: CGFloat = 6 { didSet { persistTextTypography() } }
    var textAlignment: TextAlignment = .left { didSet { persistTextTypography() } }
    var textVerticalAlignment: TextVerticalAlignment = .top { didSet { persistTextTypography() } }
    var textLineSpacing: CGFloat = 0 { didSet { persistTextTypography() } }

    /// Suppresses the typography `didSet` write-backs while `loadTextTypography`
    /// seeds the vars from the store (a load must not re-persist).
    @ObservationIgnored private var isLoadingTextTypography = false

    /// Snapshot the current typographic defaults into the persisted store.
    /// Called from every typography var's `didSet`.
    private func persistTextTypography() {
        guard !isLoadingTextTypography else { return }
        TextTypographyDefaultsStore.current = TextTypographyDefaults(
            fontFamily: textFontFamily, fontSize: textFontSize, isBold: textIsBold,
            weight: textWeight, isItalic: textIsItalic, underline: textUnderline,
            strikethrough: textStrikethrough,
            highlight: textHighlight.map { SerializableColor($0) },
            outlineColor: textOutlineColor.map { SerializableColor($0) },
            outlineWidth: textOutlineWidth, alignment: textAlignment,
            verticalAlignment: textVerticalAlignment, lineSpacing: textLineSpacing)
    }

    /// Seed the typographic defaults from the persisted store (call once at
    /// init). Guarded so the seeding writes don't recursively re-persist.
    private func loadTextTypography() {
        let d = TextTypographyDefaultsStore.current
        isLoadingTextTypography = true
        defer { isLoadingTextTypography = false }
        textFontFamily = d.fontFamily
        textFontSize = d.fontSize
        textIsBold = d.isBold
        textWeight = d.weight
        textIsItalic = d.isItalic
        textUnderline = d.underline
        textStrikethrough = d.strikethrough
        textHighlight = d.highlight?.nsColor
        textOutlineColor = d.outlineColor?.nsColor
        textOutlineWidth = d.outlineWidth
        textAlignment = d.alignment
        textVerticalAlignment = d.verticalAlignment
        textLineSpacing = d.lineSpacing
    }

    /// Blur effect mode used when CREATING the next blur region. Existing blurs
    /// keep their stored mode. (Pixelate/Mosaic are temporarily retired from the
    /// picker, so the creation default is Gaussian.)
    var blurMode: BlurMode = .gaussian

    /// Blur strength (0…1) used when CREATING the next Gaussian blur region.
    /// Existing blurs keep their stored strength. Defaults to full strength.
    var blurStrength: Double = 1.0

    /// Fill opacity (0…1) used when CREATING the next Solid block-out. Kept
    /// separate from `blurStrength` so Solid defaults to a full, opaque cover
    /// (a privacy block-out should hide completely) while Gaussian keeps its
    /// medium strength. Existing blurs keep their stored value.
    var blurSolidOpacity: Double = 1.0

    /// Region shape the Blur tool draws next (rectangle / ellipse / freehand).
    var blurRegionShape: BlurRegionShape = .rect

    /// Brush width (image space) used when CREATING the next freehand blur.
    var blurBrushWidth: CGFloat = 40

    /// Fill color used when CREATING the next blur with the Solid effect.
    /// Existing blurs keep their stored color (`Style.fillColor`).
    var blurSolidColor: NSColor = NSColor(white: 0.13, alpha: 1) {
        didSet { persistLiveColor(.blurSolid) }
    }

    /// W/H aspect ratio constraint while drawing a new crop. `nil` = Free
    /// (no constraint). Existing in-progress crop rects are not modified
    /// when this changes; the new value only affects subsequent drags.
    var cropAspectRatio: CGFloat?

    /// Carry the per-tool *creation* settings (the prefs that style the next
    /// annotation a user draws) from a previous state to this one, so switching
    /// images mid-session keeps the user's chosen widths/colors/etc. Document
    /// content (annotations, crop) and the active tool are intentionally NOT
    /// copied — the swap carries `selectedTool` on its own.
    func adoptCreationSettings(from other: EditorState) {
        // Colors: both states share the persisted per-tool store, so carrying
        // the owner and its live values (loading-guarded — a raw copy would
        // write through to whatever tool THIS state's vars last owned).
        isLoadingToolColors = true
        toolColorOwner = other.toolColorOwner
        selectedColor = other.selectedColor
        selectedOutlineColor = other.selectedOutlineColor
        shapeFillColor = other.shapeFillColor
        badgeFillColor = other.badgeFillColor
        badgeNumberColor = other.badgeNumberColor
        blurSolidColor = other.blurSolidColor
        isLoadingToolColors = false
        strokeWidthByTool = other.strokeWidthByTool
        outlineWidthByTool = other.outlineWidthByTool
        dashStyleByTool = other.dashStyleByTool
        arrowStartCap = other.arrowStartCap
        arrowEndCap = other.arrowEndCap
        arrowShaftStyle = other.arrowShaftStyle
        // Opacity: same per-tool store as colors — carry the owner and value
        // loading-guarded so a raw copy doesn't write through to whatever tool
        // THIS state's live var last owned.
        isLoadingToolOpacity = true
        toolOpacityOwner = other.toolOpacityOwner
        creationOpacity = other.creationOpacity
        isLoadingToolOpacity = false
        shapeCornerRadius = other.shapeCornerRadius
        textFontSize = other.textFontSize
        textIsBold = other.textIsBold
        textFontFamily = other.textFontFamily
        badgeRadius = other.badgeRadius
        blurMode = other.blurMode
        blurStrength = other.blurStrength
        blurSolidOpacity = other.blurSolidOpacity
        blurRegionShape = other.blurRegionShape
        blurBrushWidth = other.blurBrushWidth
        cropAspectRatio = other.cropAspectRatio
    }

    /// Adopt an edited object's style as its tool's creation default
    /// (last-used-wins). Inverse of the creation-style builders; geometry-aware,
    /// keyed by `tool` (NOT `selectedTool`, which is `.select` while editing).
    func adoptStyleAsToolDefault(_ style: Style, for tool: EditorTool) {
        // The live color/opacity vars must belong to the edited object's tool
        // before the writes below, or the write-through didSets would persist
        // this object's color/opacity into whichever tool last owned them.
        activateToolColors(for: tool)
        activateToolOpacity(for: tool)
        switch tool {
        case .rectangle, .ellipse:
            selectedColor = style.strokeColor.nsColor
            shapeFillColor = style.fillColor?.nsColor
            selectedOutlineColor = style.outlineColor?.nsColor
            strokeWidthByTool[tool] = style.strokeWidth
            outlineWidthByTool[tool] = style.outlineWidth
            creationOpacity = style.opacity
            if tool == .rectangle { shapeCornerRadius = style.cornerRadius }
            setShadowDefault(style.shadow, for: tool)
        case .arrow, .line, .pen, .penArrow:
            selectedColor = style.strokeColor.nsColor
            selectedOutlineColor = style.outlineColor?.nsColor
            strokeWidthByTool[tool] = style.strokeWidth
            outlineWidthByTool[tool] = style.outlineWidth
            creationOpacity = style.opacity
            if tool == .arrow || tool == .penArrow { arrowStartCap = style.startCap; arrowEndCap = style.endCap }
            // Shaft profile is straight-arrow-only: freehand arrows render
            // uniform, so adopting from one would silently flip the default.
            if tool == .arrow { arrowShaftStyle = style.shaftStyle }
            if tool == .arrow || tool == .line { dashStyleByTool[tool] = style.dashStyle }
            setShadowDefault(style.shadow, for: tool)
        case .badge:
            badgeNumberColor = style.strokeColor.nsColor
            if let fill = style.fillColor { badgeFillColor = fill.nsColor }
            selectedOutlineColor = style.outlineColor?.nsColor
            outlineWidthByTool[.badge] = style.outlineWidth
            creationOpacity = style.opacity
            setShadowDefault(style.shadow, for: .badge)
        case .text:
            creationOpacity = style.opacity
            setShadowDefault(style.shadow, for: .text)
        default:
            break
        }
    }

    /// Convenience accessor.
    var selectedAnnotation: Annotation? {
        guard let id = primarySelectionID else { return nil }
        return annotations.first(where: { $0.id == id })
    }

    /// Observable counter — bumped on every checkpoint/apply. The canvas view
    /// ignores it, but it lets observers refresh reactively.
    var historyEpoch: Int = 0

    /// True after any user-initiated edit (annotation added, crop
    /// committed, undo, redo). Cleared by `markClean()` after a
    /// successful save. EditorWindowController.hasUnsavedEdits reads
    /// this to decide whether to autoSave on file-switch or window-close.
    ///
    /// Loading a file via direct assignment of `annotations`/`croppedRect`
    /// does NOT set this flag — only changes that go through
    /// `recordUndoCheckpoint` (i.e., user edits) do.
    var isDirty: Bool = false

    /// True while a canvas mouse interaction (move/resize/rotate/draw drag)
    /// is in flight. Heavy observers — autosave, strip-preview composite,
    /// sidebar rebuild — defer their work while set so a pointer pause
    /// mid-drag can't trigger a main-thread hitch; clearing it (mouseUp)
    /// fires their observations and the deferred work runs once.
    var interactionInProgress: Bool = false

    /// Called by the save coordinator after a successful write.
    func markClean() { isDirty = false }

    /// Mark the session dirty for changes that don't go through the undo stack
    /// but still need persisting (e.g. enhancing, flipping original/enhanced).
    func markDirty() { isDirty = true }

    /// Whether the last Live Text recognition found any text. `nil` = idle /
    /// still recognizing (unknown). Drives the sidebar's Live Text panel — the
    /// copy buttons disable and a "no text" hint shows when this is `false`.
    /// Set by the canvas OCR pass; observed by the sidebar.
    var liveTextHasText: Bool? = nil

    // MARK: Live Text auto-enhance session

    /// `showingEnhanced` value to restore when the Live Text tool is left;
    /// nil = no session active (enhanced was already the user's visible base,
    /// Set when a capture opened with Enhance Clarity forced off for speed —
    /// holds the user's own choice so a save can still record it: the canvas
    /// shows one thing while the manifest must keep saying another.
    @ObservationIgnored var enhanceOpenSuppressedRestore: Bool? = nil

    /// Source-pixel count from which a capture is "large" enough that decoding
    /// its enhanced copy is worth avoiding on a switch.
    ///
    /// Expressed in SOURCE pixels because that is what the caller knows before
    /// deciding whether to decode — the cost is the enhanced image, which is
    /// 2x linear, so roughly four times this.
    /// `nonisolated`: an immutable threshold, read by the pure decision below
    /// (the class is `@MainActor` for its mutable state).
    nonisolated static let enhanceAutoOffMinSourcePixels = 1_000_000

    /// Whether a capture should open with Enhance Clarity off.
    ///
    /// Restoring it means decoding `enhanced.png` on every switch even when the
    /// user never looks at it, and without a Neural Engine that decode
    /// dominates the switch. Small captures decode fast enough that suppressing
    /// them would cost the user their setting for nothing. Pure for testing.
    nonisolated static func suppressesEnhancedOnOpen(
        sourcePixels: Int, machine: OCRPerformanceClass
    ) -> Bool {
        machine == .cpuOnly && sourcePixels >= enhanceAutoOffMinSourcePixels
    }

    /// Open with the plain base while remembering what the user actually chose.
    ///
    /// Order matters: `showingEnhanced`'s `didSet` retires a suppression (any
    /// write is treated as the user deciding), so the restore has to be stored
    /// AFTER the write, not before — otherwise this clears its own record.
    func suppressEnhancedForOpen() {
        guard enhanceOpenSuppressedRestore == nil else { return }
        let chosen = showingEnhanced
        showingEnhanced = false
        enhanceOpenSuppressedRestore = chosen
    }

    /// What saves should write for the manifest's `showingEnhanced`: the choice
    /// a speed-suppressed open is standing in for, else the live value. Keeps
    /// that stand-in out of the `.seal` no matter when an autosave, capture
    /// swap, or crash happens.
    var persistedShowingEnhanced: Bool {
        enhanceOpenSuppressedRestore ?? showingEnhanced
    }

    /// Label for the Live Text progress overlay. One pass, one label: Live Text
    /// reads whatever base is on screen and never generates another.
    var liveTextProgressLabel: String { "Recognizing text…" }

    /// Base/scale a SAVE should composite from — follows the persisted
    /// enhanced choice, not the Live Text session's temporary flip, so a
    /// mid-session autosave can't write an enhanced-looking composite next
    /// to a `showingEnhanced: false` manifest.
    var persistedDisplayBase: CGImage {
        if showingCutout, let cutout = cutoutImage { return cutout }
        return (persistedShowingEnhanced && enhancedImage != nil) ? enhancedImage! : sourceImage
    }
    var persistedDisplayScale: CGFloat {
        CGFloat(persistedDisplayBase.width) / CGFloat(sourceImage.width)
    }

    /// Cancel an in-flight Live Text read from the progress overlay's Cancel
    /// button: leave the tool.
    ///
    /// Leaving the tool is the point. Text-select with no recognized layout is
    /// a dead tool, and staying in it lets the next state change re-enter
    /// `ensureRecognition()` and restart the very read the user just cancelled.
    func cancelLiveTextRead() {
        selectedTool = .select
    }

    /// The image the canvas/composite should render: enhanced when shown and
    /// available, else the canonical source. Annotations stay in source coords.
    var displayBase: CGImage {
        if showingCutout, let cutout = cutoutImage { return cutout }
        return (showingEnhanced && enhancedImage != nil) ? enhancedImage! : sourceImage
    }

    /// Ratio of the active base's pixel width to the source's — 1.0 for the
    /// original, 2.0 for the enhanced base. Annotations are scaled by this.
    var displayScale: CGFloat {
        CGFloat(displayBase.width) / CGFloat(sourceImage.width)
    }


    init(sourceImage: CGImage, sourceURL: URL?,
         enhancedImage: CGImage? = nil, showingEnhanced: Bool = false,
         pristineSource: CGImage? = nil) {
        self.sourceImage = sourceImage
        self.sourceURL = sourceURL
        self.enhancedImage = enhancedImage
        self.showingEnhanced = showingEnhanced
        self.pristineSource = pristineSource
        loadTextTypography()
    }

    // MARK: - Document resize (Resize popover)

    /// The package's ORIGINAL source pixels while a document Resize is active
    /// (nil = the document is at native size and `sourceImage` IS pristine).
    /// Saves always write the pristine image to `source.png`, so Resize's
    /// "Reset to original" keeps working across save/reopen cycles.
    let pristineSource: CGImage?

    /// Per-axis factors from pristine-source space to the current (resized)
    /// document space; (1, 1) when no resize is active.
    var resizeFactors: (x: CGFloat, y: CGFloat) {
        guard let pristine = pristineSource, pristine.width > 0, pristine.height > 0
        else { return (1, 1) }
        return (CGFloat(sourceImage.width) / CGFloat(pristine.width),
                CGFloat(sourceImage.height) / CGFloat(pristine.height))
    }

    /// Persisted document-resample target (annotations.json v8): the visible
    /// size while a resize is active, nil at native size.
    var resizedSize: CGSize? {
        pristineSource == nil ? nil : visibleImageSize
    }

    /// `croppedRect` mapped back to pristine-source space for persistence —
    /// on disk the crop is always relative to the pristine `source.png`.
    var persistedCroppedRect: CGRect? {
        guard let crop = croppedRect else { return nil }
        let f = resizeFactors
        guard f.x != 1 || f.y != 1 else { return crop }
        return CGRect(x: crop.minX / f.x, y: crop.minY / f.y,
                      width: crop.width / f.x, height: crop.height / f.y)
    }

    /// The image written to `source.png` — always the pristine pixels.
    var persistedSourceImage: CGImage { pristineSource ?? sourceImage }

    /// True when any edit is layered on the pristine original — drives the
    /// "Revert to Original Image" command's enabled state. Tool-creation
    /// settings are NOT edits.
    var hasEdits: Bool {
        croppedRect != nil || focusRect != nil || !annotations.isEmpty
            || showingEnhanced || enhancedImage != nil
            || showingCutout || cutoutImage != nil
            || backgroundFill != nil
            || resizedSize != nil || pristineSource != nil
            || !imageAssets.isEmpty
    }

    /// A fresh state that is this capture reverted to its pristine original:
    /// the pristine base with every edit field at its default. Tool-creation
    /// settings carry over. Marked dirty so autosave rewrites the package.
    func revertedToOriginal() -> EditorState {
        let fresh = EditorState(sourceImage: persistedSourceImage, sourceURL: sourceURL,
                                enhancedImage: nil, showingEnhanced: false, pristineSource: nil)
        fresh.isReadOnly = isReadOnly
        fresh.adoptCreationSettings(from: self)
        // ALWAYS carry the image-asset bytes, even though revert drops the
        // annotations that reference them — assets are never pruned (see
        // `imageAssets`), so the autosave after a revert must not strip
        // asset-*.png from the package. A scene that loses its layer
        // annotations to an edge-case revert stays pixel-recoverable.
        fresh.imageAssets = imageAssets
        // Live Capture scene ONLY: "original" means the captured window LAYOUT,
        // not a bare backdrop — the window layers are annotations, so a plain
        // revert (empty annotations) would wipe them. Rebuild the image layers at
        // their captured frames, preserving current stacking order, and drop
        // everything else (annotations drawn on top, crop, canvas growth). Every
        // non-scene capture keeps the plain revert-to-pristine behavior above.
        SceneDiag.note("REVERT \(SceneDiag.name(sourceURL)): sceneFrames=\(sceneOriginalFrames.count) "
            + "imageAnnotations=\(annotations.filter { $0.geometry.isImage }.count) "
            + "totalAnnotations=\(annotations.count) assets=\(imageAssets.count)")
        if !sceneOriginalFrames.isEmpty {
            fresh.sceneOriginalFrames = sceneOriginalFrames
            var layers: [Annotation] = []
            for ann in annotations {
                guard case let .image(rect, assetID) = ann.geometry else { continue }
                if let data = imageAssets[assetID] { fresh.registerImageAsset(id: assetID, data: data) }
                let original = sceneOriginalFrames[assetID] ?? rect
                layers.append(Annotation(id: ann.id,
                                         geometry: .image(rect: original, assetID: assetID),
                                         style: ann.style, transform: ann.transform))
            }
            fresh.annotations = layers
        }
        fresh.markDirty()
        return fresh
    }

    /// The size Resize's "Reset to original" returns to: the pristine visible
    /// size (crop honored, expressed in pristine pixels).
    var pristineVisibleSize: CGSize {
        if let crop = persistedCroppedRect { return crop.size }
        let pristine = pristineSource ?? sourceImage
        return CGSize(width: pristine.width, height: pristine.height)
    }

    /// Mint a snapshot of the currently committed state — the shared body
    /// behind `recordUndoCheckpoint` and the controller's undo/redo counterpart
    /// pushes onto the global timeline.
    func makeSnapshot(action: String?, metadata: MetadataUndoPatch? = nil) -> EditorSnapshot {
        EditorSnapshot(
            annotations: annotations,
            croppedRect: croppedRect,
            contentClip: contentClip,
            focusRect: focusRect,
            sourceURL: sourceURL,
            backgroundFill: backgroundFill,
            at: Date(),
            action: action,
            showingCutout: showingCutout,
            showingEnhanced: showingEnhanced,
            zoom: zoom,
            sourceImageSize: CGSize(width: sourceImage.width, height: sourceImage.height),
            metadata: metadata
        )
    }

    /// The counterpart snapshot for `snapshot` about to be popped off its
    /// stack: mints a fresh snapshot of the CURRENT state, carrying the
    /// popped snapshot's action label and mirroring its metadata trio.
    func counterpartSnapshot(for snapshot: EditorSnapshot) -> EditorSnapshot {
        makeSnapshot(action: snapshot.action, metadata: counterpartMetadata(for: snapshot))
    }

    /// Restore `snapshot`'s fields onto the current state — the shared body
    /// behind the controller's timeline undo/redo. Does NOT touch any stack.
    func applySnapshot(_ snapshot: EditorSnapshot) {
        pendingRestoredMetadata = snapshot.metadata
        annotations = snapshot.annotations
        croppedRect = snapshot.croppedRect
        contentClip = snapshot.contentClip
        focusRect = snapshot.focusRect
        sourceURL = snapshot.sourceURL
        setShowingCutout(snapshot.showingCutout ?? false)
        if let enhanced = snapshot.showingEnhanced {
            showingEnhanced = enhanced && enhancedImage != nil && !showingCutout
        }
        if let restoredZoom = snapshot.zoom { zoom = restoredZoom }
        backgroundFill = snapshot.backgroundFill
        reconcileSelectionWithAnnotations()
        pendingCrop = nil
        redactionScan = .idle
        historyEpoch &+= 1
        isDirty = true
    }

    /// Notified with every minted checkpoint snapshot — the app-global
    /// timeline's hook into the per-image history. The controller records the
    /// snapshot onto `GlobalUndoStore` (which owns the undo/redo stacks now).
    @ObservationIgnored var onCheckpoint: ((EditorSnapshot) -> Void)?

    /// Notified when an optimistic checkpoint is cancelled (`discardLast…`) —
    /// the controller removes the matching top edit from `GlobalUndoStore`.
    @ObservationIgnored var onDiscardCheckpoint: ((String) -> Void)?

    /// Mint a checkpoint of the current committed state and hand it to the
    /// global timeline (`onCheckpoint`). Marks the document dirty. Call this
    /// BEFORE making a destructive change.
    func recordUndoCheckpoint(action: String? = nil, metadata: MetadataUndoPatch? = nil) {
        let snapshot = makeSnapshot(action: action, metadata: metadata)
        UndoDiag.note("checkpoint '\(action ?? "-")' — \(UndoDiag.name(sourceURL))")
        historyEpoch &+= 1
        isDirty = true
        onCheckpoint?(snapshot)
    }


    // MARK: - Metadata steps (manifest-backed, controller-applied)

    /// Reads the CURRENT user-editable trio from the open document's manifest
    /// (controller-injected) — builds the redo counterpart when a metadata
    /// step is popped. nil until wired or when the read fails.
    @ObservationIgnored var metadataPatchProvider: (() -> MetadataUndoPatch?)?

    /// A popped metadata step's trio, parked here because the state can't
    /// write the manifest itself and ordering matters: the controller applies
    /// it AFTER file-move reconciliation (a rename undo moves the file first).
    private var pendingRestoredMetadata: MetadataUndoPatch?
    func consumePendingRestoredMetadata() -> MetadataUndoPatch? {
        defer { pendingRestoredMetadata = nil }
        return pendingRestoredMetadata
    }

    /// Counterpart trio for a snapshot about to be popped: metadata steps
    /// mirror the CURRENT manifest values (read before anything is restored);
    /// every other step carries nil and leaves the manifest alone.
    private func counterpartMetadata(for snapshot: EditorSnapshot) -> MetadataUndoPatch? {
        guard snapshot.metadata != nil else { return nil }
        return metadataPatchProvider?()
    }

    /// Cancel the newest optimistic checkpoint — for a gesture that
    /// checkpointed and then failed/cancelled. Delegates to the global timeline
    /// via `onDiscardCheckpoint` (label-guarded there so an interleaved edit's
    /// step is never dropped).
    func discardLastUndoCheckpoint(ifAction action: String) {
        onDiscardCheckpoint?(action)
    }

    /// Zoom actions join ⌘Z with COALESCING: a continuous gesture (slider
    /// drag, ⌘-scroll burst, repeated ⌘±) records ONE step — a fresh
    /// checkpoint only when the last zoom checkpoint went stale (>1s ago);
    /// every call refreshes the burst window.
    private var lastZoomCheckpointAt: Date = .distantPast
    func checkpointZoomIfNeeded() {
        defer { lastZoomCheckpointAt = Date() }
        guard !isReadOnly,
              Date().timeIntervalSince(lastZoomCheckpointAt) > 1.0 else { return }
        recordUndoCheckpoint(action: "Zoom")
    }

    // MARK: - Cross-size history (⌘Z across a document Resize)

    /// Whether `snapshot` lives in a DIFFERENT base-image size than the
    /// current document — a document Resize sits between here and there, so the
    /// controller must rebuild the document at the snapshot's size before
    /// applying it (`restoreAcrossResize`).
    func snapshotRequiresRebuild(_ snapshot: EditorSnapshot) -> Bool {
        guard let size = snapshot.sourceImageSize else { return false }
        return Int(size.width) != sourceImage.width
            || Int(size.height) != sourceImage.height
    }

    /// Park a to-be-restored snapshot's metadata trio so the controller can
    /// apply it after a cross-size rebuild's file-move reconciliation. Mirrors
    /// what `applySnapshot` does for the in-place path, but for the rebuild
    /// path where the OLD state (holding the park) is swapped out.
    func parkRestoredMetadata(from snapshot: EditorSnapshot) {
        pendingRestoredMetadata = snapshot.metadata
    }

    /// Drop any selection entries that no longer exist in `annotations`, and
    /// repair the primary so it stays nil-or-a-member. Called after undo/redo,
    /// which restore annotations without restoring selection.
    private func reconcileSelectionWithAnnotations() {
        let live = Set(annotations.map { $0.id })
        selectedAnnotationIDs.formIntersection(live)
        if let p = primarySelectionID, !live.contains(p) {
            primarySelectionID = selectedAnnotationIDs.first
        }
        if selectedAnnotationIDs.isEmpty { primarySelectionID = nil }
    }

    /// Commit `pendingCrop` to `croppedRect` and translate/clip annotations.
    /// No-op for nil or zero-area pending rects.
    /// The four crop-panel actions, so the panel can flash a checkmark on the
    /// matching button whether it was triggered by click or shortcut.
    enum CropAction: Equatable { case crop, copy, cut, soft }

    /// Bumped each time a crop action runs — from a panel-button click OR its
    /// keyboard shortcut, since both converge on the methods below. The crop
    /// panel observes it to flash a confirmation checkmark on the matching button.
    struct CropActionSignal: Equatable { var action: CropAction; var seq: Int }
    private(set) var cropActionSignal: CropActionSignal?
    @ObservationIgnored private var cropActionSeq = 0
    private func emitCropAction(_ action: CropAction) {
        cropActionSeq += 1
        cropActionSignal = CropActionSignal(action: action, seq: cropActionSeq)
    }

    func commitCrop() {
        guard let pending = pendingCrop,
              pending.width > 0,
              pending.height > 0
        else {
            pendingCrop = nil
            return
        }
        recordUndoCheckpoint(action: "Crop")
        annotations = cropAndClipAnnotations(annotations, to: pending)
        croppedRect = pending
        contentClip = nil   // a fresh crop redefines the content; drop any grow
        focusRect = nil
        pendingCrop = nil
        redactionScan = .idle
        emitCropAction(.crop)
    }

    /// Discard any in-progress crop without affecting committed state.
    func abandonCrop() {
        pendingCrop = nil
    }

    /// Copy the composited pixels inside `pendingCrop` to the clipboard as PNG.
    /// Image and selection are unchanged. Returns false when there is no selection.
    @discardableResult
    func copyCropRegion() -> Bool {
        let ok = copyCropPixelsToPasteboard()
        if ok { emitCropAction(.copy) }
        return ok
    }

    /// Copy the selection's pixels to the pasteboard WITHOUT emitting a crop
    /// action (so Cut's internal copy doesn't also flash the Copy button).
    private func copyCropPixelsToPasteboard() -> Bool {
        guard let rect = pendingCrop else { return false }
        // Use displayBase/croppedRect/displayScale so that an active destructive
        // crop or enhanced image produces the correct pixels (matches the canvas).
        guard let png = compositedRegionPNG(image: displayBase, annotations: annotations,
                                            assets: imageAssets, rect: rect,
                                            crop: croppedRect, scale: displayScale) else { return false }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.declareTypes([.png], owner: nil)
        pb.setData(png, forType: .png)
        return true
    }

    /// Copy the selection to the clipboard, then remove it from the image by
    /// appending a `.cut` (transparent-hole) annotation. Undoable. Clears the
    /// selection. Returns false when there is no selection.
    @discardableResult
    func cutCropRegion() -> Bool {
        guard let rect = pendingCrop else { return false }
        _ = copyCropPixelsToPasteboard()   // no emit — this is a Cut, not a Copy
        recordUndoCheckpoint(action: "Cut")
        let annotation = Annotation(
            geometry: .cut(rect: rect),
            style: Style(strokeColor: SerializableColor(NSColor.black), strokeWidth: 0))
        annotations.append(annotation)
        pendingCrop = nil
        emitCropAction(.cut)
        return true
    }

    /// Tear the selection off as its own movable image object, leaving a
    /// transparent hole where the original pixels were. Placed at an edge-aware
    /// offset from the selection origin. One undo step reverts both the hole and
    /// the lifted object. Clears the selection. Returns false when there is no selection.
    @discardableResult
    func softCropRegion() -> Bool {
        guard let rect = pendingCrop else { return false }
        // Use displayBase/croppedRect/displayScale so that an active destructive
        // crop or enhanced image produces the correct pixels (matches the canvas).
        guard let region = compositedRegion(image: displayBase, annotations: annotations,
                                            assets: imageAssets, rect: rect,
                                            crop: croppedRect, scale: displayScale) else { return false }
        recordUndoCheckpoint(action: "Soft Crop")
        // Punch the hole first (drawn beneath the lifted object).
        let cutAnnotation = Annotation(
            geometry: .cut(rect: rect),
            style: Style(strokeColor: SerializableColor(NSColor.black), strokeWidth: 0))
        annotations.append(cutAnnotation)
        // Object geometry stays in visible-image (post-crop) coords; use the
        // visible size for the boundary clamp so the offset is correct under crop.
        let bounds = CGRect(origin: .zero, size: visibleImageSize)
        let off = softCropOffset(selection: rect, imageBounds: bounds)
        // insertImageAnnotation centers the object at the supplied point.
        let center = CGPoint(x: rect.origin.x + off.x + rect.width / 2,
                             y: rect.origin.y + off.y + rect.height / 2)
        insertImageAnnotation(region, at: center, recordUndo: false)
        pendingCrop = nil
        emitCropAction(.soft)
        return true
    }

    /// Mutate the geometry of the annotation with `id` via the given closure.
    /// Records an undo checkpoint before applying so `⌘Z` reverts the
    /// whole operation.
    func updateGeometry(id: UUID, mutate: (inout Geometry) -> Void) {
        guard let idx = annotations.firstIndex(where: { $0.id == id }) else { return }
        recordUndoCheckpoint(action: "Edit")
        var geometry = annotations[idx].geometry
        mutate(&geometry)
        annotations[idx].geometry = geometry
    }

    /// Mutate the selected annotation's style in place. Does NOT record an undo
    /// checkpoint — the caller checkpoints once at the start of an interaction
    /// (e.g. a slider drag) so the whole drag is one undo step. No-op when
    /// nothing is selected. Marks the document dirty.
    func updateSelectedStyle(_ mutate: (inout Style) -> Void) {
        guard let id = primarySelectionID else { return }
        updateStyle(id: id, mutate)
    }

    /// Mutate a specific annotation's style in place (the objects-list rows edit
    /// objects other than the primary selection). Same reflow + dirty behavior
    /// as `updateSelectedStyle`; no undo checkpoint (the caller checkpoints once
    /// per interaction). No-op for an unknown id.
    func updateStyle(id: UUID, _ mutate: (inout Style) -> Void) {
        guard let idx = annotations.firstIndex(where: { $0.id == id }) else { return }
        let oldStyle = annotations[idx].style
        var style = oldStyle
        mutate(&style)
        annotations[idx].style = style
        // Text boxes reflow grow-only, and only when the text FIT before the
        // edit — a deliberately height-shrunk mask stays put (see
        // reflowedTextRect). Width preserved.
        if case let .text(rect, runs) = annotations[idx].geometry {
            let clamped = reflowedTextRect(rect: rect, oldRuns: runs, oldStyle: oldStyle,
                                           newRuns: runs, newStyle: style)
            annotations[idx].geometry = .text(rect: clamped, runs: runs)
        }
        if let tool = geometryTool(annotations[idx].geometry) {
            adoptStyleAsToolDefault(style, for: tool)
        }
        isDirty = true
    }

    /// Grow-only reflow after a STYLE/RUNS edit — but never "repair" a mask
    /// the user deliberately height-shrunk: if the text already overflowed
    /// the box BEFORE the edit, the shrunk mask is intentional and stays put
    /// (the edit only changes what's hidden). A box that FIT before still
    /// grows so a bigger font / wider spacing never clips it.
    private func reflowedTextRect(rect: CGRect, oldRuns: [TextRun], oldStyle: Style,
                                  newRuns: [TextRun], newStyle: Style) -> CGRect {
        let fitBefore = textBoxHeight(
            runs: oldRuns, width: oldStyle.effectiveTextLayoutWidth(rect: rect),
            lineSpacing: oldStyle.lineSpacing) <= rect.height + 0.5
        guard fitBefore else { return rect }
        return clampTextHeight(rect: rect, runs: newRuns, anchorBottom: false,
                               lineSpacing: newStyle.lineSpacing,
                               layoutWidth: newStyle.effectiveTextLayoutWidth(rect: rect))
    }

    /// Mutate the selected TEXT box's runs in place (e.g. uniform color / font
    /// / bold from the object panel), reflowing the box height. Does NOT record
    /// an undo checkpoint — the caller checkpoints once per interaction, like
    /// `updateSelectedStyle`. No-op unless a text box is the primary selection.
    func updateSelectedTextRuns(_ mutate: (inout [TextRun]) -> Void) {
        guard let id = primarySelectionID else { return }
        updateTextRuns(id: id, mutate)
    }

    /// Mutate a specific text box's runs (objects-list inline editing). No-op
    /// Mutate a text box's paragraph-level Style (alignment / vertical alignment
    /// / line spacing). The box rectangle is preserved — vertical alignment only
    /// means something when the box is taller than its text, so we must NOT
    /// shrink it back to content height. It only *grows* if a line-spacing change
    /// would otherwise clip the text. No-op unless `id` is a text box.
    func updateTextBoxStyle(id: UUID, _ mutate: (inout Style) -> Void) {
        guard let idx = annotations.firstIndex(where: { $0.id == id }),
              case let .text(rect, runs) = annotations[idx].geometry else { return }
        let oldStyle = annotations[idx].style
        mutate(&annotations[idx].style)
        let clamped = reflowedTextRect(rect: rect, oldRuns: runs, oldStyle: oldStyle,
                                       newRuns: runs, newStyle: annotations[idx].style)
        annotations[idx].geometry = .text(rect: clamped, runs: runs)
        adoptTextDefaults(fromTextAt: idx)
        isDirty = true
    }

    /// Adopt an edited text object's FULL styling as the Text tool's creation
    /// defaults (last-used-wins) so the next new box inherits it — the object
    /// panel's counterpart to the inline-edit commit capture. Reads the leading
    /// run (the object panel styles all runs uniformly) plus the box-level style.
    /// Color and opacity route through the per-tool stores (activate `.text`
    /// first so the write-through lands in the Text slot, not whatever tool the
    /// live vars last owned while `.select` is active).
    private func adoptTextDefaults(fromTextAt idx: Int) {
        guard annotations.indices.contains(idx),
              case let .text(_, runs) = annotations[idx].geometry else { return }
        let style = annotations[idx].style
        textAlignment = style.textAlignment
        textVerticalAlignment = style.textVerticalAlignment
        textLineSpacing = style.lineSpacing
        activateToolColors(for: .text)
        activateToolOpacity(for: .text)
        creationOpacity = style.opacity
        if let run = runs.first {
            selectedColor = run.color.nsColor
            textFontSize = run.fontSize
            textIsBold = run.isBold
            textFontFamily = run.fontFamily
            AnnotationTextFont.remembered = run.fontFamily
            textWeight = run.weight
            textIsItalic = run.isItalic
            textUnderline = run.underline
            textStrikethrough = run.strikethrough
            textHighlight = run.highlight?.nsColor
            textOutlineColor = run.outlineColor?.nsColor
            textOutlineWidth = run.outlineWidth
        }
    }

    /// Freeze the layout width when a text-box resize drag begins (the live
    /// preview then keeps its wrap, shrinking just hides text). No-op unless
    /// `id` names a text annotation.
    func beginTextBoxResize(id: UUID) {
        guard let idx = annotations.firstIndex(where: { $0.id == id }),
              case let .text(rect, _) = annotations[idx].geometry else { return }
        annotations[idx].style.textLayoutWidth =
            annotations[idx].style.effectiveTextLayoutWidth(rect: rect)
    }

    /// Normalize after a manual resize drag ends: enlarging to/past the frozen
    /// layout width re-couples (adopts `rect.width`); anything narrower keeps
    /// the frozen layout width as a mask. No-op unless `id` names a text
    /// annotation with a frozen layout width (i.e. `beginTextBoxResize` ran).
    func endTextBoxResize(id: UUID) {
        guard let idx = annotations.firstIndex(where: { $0.id == id }),
              case let .text(rect, _) = annotations[idx].geometry,
              let layout = annotations[idx].style.textLayoutWidth else { return }
        if rect.width + 0.5 >= layout { annotations[idx].style.textLayoutWidth = nil }
        isDirty = true
    }

    /// unless `id` names a text annotation.
    func updateTextRuns(id: UUID, _ mutate: (inout [TextRun]) -> Void) {
        guard let idx = annotations.firstIndex(where: { $0.id == id }),
              case let .text(rect, runs) = annotations[idx].geometry else { return }
        var newRuns = runs
        mutate(&newRuns)
        // Grow-only, and only when the text FIT before the edit (see
        // reflowedTextRect): a fitting box grows so new content never clips;
        // a deliberately height-shrunk mask stays put.
        let style = annotations[idx].style
        let clamped = reflowedTextRect(rect: rect, oldRuns: runs, oldStyle: style,
                                       newRuns: newRuns, newStyle: style)
        annotations[idx].geometry = .text(rect: clamped, runs: newRuns)
        adoptTextDefaults(fromTextAt: idx)
        isDirty = true
    }

    /// Set the selected badge's radius (image space). Does NOT record an undo
    /// checkpoint — the caller checkpoints once per interaction, like
    /// `updateSelectedStyle`. No-op unless a badge is the primary selection.
    func updateSelectedBadgeRadius(_ radius: CGFloat) {
        guard let id = primarySelectionID else { return }
        updateBadgeRadius(id: id, radius)
    }

    /// Set a specific badge's radius (objects-list inline editing). No-op unless
    /// `id` names a badge annotation. Radius is clamped to ≥ 4.
    func updateBadgeRadius(id: UUID, _ radius: CGFloat) {
        guard let idx = annotations.firstIndex(where: { $0.id == id }),
              case let .badge(center, _) = annotations[idx].geometry else { return }
        annotations[idx].geometry = .badge(center: center, radius: max(4, radius))
        badgeRadius = radius
        isDirty = true
    }

    /// Select only `id`, replacing any existing selection.
    func selectOnly(_ id: UUID) {
        selectedAnnotationIDs = [id]
        primarySelectionID = id
    }

    /// Highlight `id` from the objects list without descending into its
    /// property panel: make it the primary (so the canvas emphasizes it) and
    /// add it to the selection if not already a member. The rest of the
    /// selection is left intact, so a multi-selection stays in the list.
    func focusObject(_ id: UUID) {
        selectedAnnotationIDs.insert(id)
        primarySelectionID = id
    }

    /// Toggle `id` in/out of the selection. When removing the current
    /// primary, the primary falls back to any remaining member.
    func toggleSelection(_ id: UUID) {
        if selectedAnnotationIDs.contains(id) {
            selectedAnnotationIDs.remove(id)
            if primarySelectionID == id { primarySelectionID = selectedAnnotationIDs.first }
        } else {
            selectedAnnotationIDs.insert(id)
            primarySelectionID = id
        }
    }

    /// Replace the selection wholesale (used by marquee selection). `primary`
    /// is clamped to set membership so the invariant always holds.
    func setSelection(_ ids: Set<UUID>, primary: UUID?) {
        selectedAnnotationIDs = ids
        primarySelectionID = primary.flatMap { ids.contains($0) ? $0 : nil }
    }

    /// Clear all selection.
    func clearSelection() {
        selectedAnnotationIDs = []
        primarySelectionID = nil
    }

    /// Select every annotation. A single object becomes the primary; a
    /// multi-selection has no object highlighted by default (the user focuses
    /// one explicitly). No-op when there are no annotations.
    func selectAll() {
        guard !annotations.isEmpty else { return }
        selectedAnnotationIDs = Set(annotations.map { $0.id })
        primarySelectionID = annotations.count == 1 ? annotations.first?.id : nil
    }

    /// Delete every selected annotation. Records one undo checkpoint and
    /// clears the selection. No-op when nothing is selected.
    func deleteSelected() {
        guard !selectedAnnotationIDs.isEmpty else { return }
        recordUndoCheckpoint(action: "Delete")
        annotations.removeAll { selectedAnnotationIDs.contains($0.id) }
        selectedAnnotationIDs = []
        primarySelectionID = nil
    }

    /// Move the selected annotations in depth. One undo step; a move that
    /// changes nothing (already at the extreme) records no checkpoint.
    func reorderSelected(_ op: ZOrderOperation) {
        guard !isReadOnly, !selectedAnnotationIDs.isEmpty else { return }
        let reordered = reorderAnnotations(annotations,
                                           selected: selectedAnnotationIDs, op)
        guard reordered.map(\.id) != annotations.map(\.id) else { return }
        let label: String
        switch op {
        case .toFront: label = "Bring to Front"
        case .forward: label = "Bring Forward"
        case .backward: label = "Send Backward"
        case .toBack: label = "Send to Back"
        }
        recordUndoCheckpoint(action: label)
        annotations = reordered
    }

    /// Repack every image object at NATIVE size into a roughly-16:9,
    /// non-overlapping layout centered on the current canvas — so the user can
    /// inspect each image at full quality. No-op with fewer than 2 image objects.
    /// One undoable step. Only repositions `.image` annotations (non-image
    /// annotations are left untouched). The caller grows the canvas to fit
    /// afterwards (e.g. `expandCanvasToFitAnnotations`).
    func autoArrangeImages(order: ArrangeOrder, gap: CGFloat = 12) {
        let imageIdx = annotations.indices.filter { annotations[$0].geometry.isImage }
        guard imageIdx.count > 1 else { return }
        recordUndoCheckpoint(action: "Auto Arrange Images")

        let sizes: [CGSize] = imageIdx.map {
            if case let .image(rect, _) = annotations[$0].geometry { return rect.size }
            return .zero
        }
        var rects = ImageAutoArranger.arrange(sizes: sizes, order: order, gap: gap)

        // Center the packed block on the current canvas center (visible space).
        let box = rects.dropFirst().reduce(rects.first ?? .zero) { $0.union($1) }
        let vis = visibleImageSize
        let dx = (vis.width - box.width) / 2 - box.minX
        let dy = (vis.height - box.height) / 2 - box.minY
        rects = rects.map { $0.offsetBy(dx: dx, dy: dy) }

        for (k, i) in imageIdx.enumerated() {
            if case let .image(_, assetID) = annotations[i].geometry {
                annotations[i].geometry = .image(rect: rects[k], assetID: assetID)
            }
        }
        markDirty()
    }

    /// Whether flip controls apply to this geometry. Badges are excluded — a
    /// mirrored step number reads wrong — but text can be flipped (mirrored) on
    /// request, like every other object.
    static func isFlippable(_ geometry: Geometry) -> Bool {
        switch geometry {
        case .badge: return false
        default: return true
        }
    }

    /// Set an absolute rotation (panel field / stepper). One undo step;
    /// writing the current value records nothing.
    func setRotation(annotationID: UUID, degrees: CGFloat) {
        guard !isReadOnly,
              let idx = annotations.firstIndex(where: { $0.id == annotationID })
        else { return }
        let normalized = normalizedDegrees(degrees)
        guard annotations[idx].transform.rotationDegrees != normalized else { return }
        recordUndoCheckpoint(action: "Rotate")
        annotations[idx].transform.rotationDegrees = normalized
    }

    /// Flip every flippable member of the selection about its own center.
    /// One undo step for the whole gesture; no-op when nothing flippable.
    func flipSelected(horizontal: Bool) {
        guard !isReadOnly else { return }
        let targets = annotations.enumerated().filter {
            selectedAnnotationIDs.contains($0.element.id)
                && Self.isFlippable($0.element.geometry)
        }
        guard !targets.isEmpty else { return }
        recordUndoCheckpoint(action: horizontal ? "Flip Horizontal" : "Flip Vertical")
        for (idx, a) in targets {
            if let mirrored = Self.mirroredPointGeometry(a.geometry, horizontal: horizontal) {
                // Point-based shapes mirror their POINTS instead of carrying a
                // flip flag. Identical on screen — the flag mirrors about the
                // same bounds centre — but it leaves the transform out of the
                // way of endpoint dragging.
                //
                // A stored flip is anchored to the object's own bounds centre,
                // and dragging an endpoint MOVES that centre. For a two-point
                // shape the two cancel exactly: mirroring `end` about the
                // midpoint of `start`/`end` puts it back where `start` is,
                // whatever the cursor does, so a flipped line's handle could
                // not follow the pointer at all. Rects don't have this problem
                // (their centre is independent of which edge you drag), so
                // they keep the flag — see the `else` branch.
                //
                // Negating the rotation matches `flippedH()`: a screen mirror
                // N satisfies N·R(θ) = R(−θ)·N, and N commutes with the flip
                // scales, so mirroring the points and negating θ reproduces
                // the same display.
                annotations[idx].geometry = mirrored
                annotations[idx].transform.rotationDegrees =
                    normalizedDegrees(-a.transform.rotationDegrees)
            } else {
                annotations[idx].transform = horizontal
                    ? a.transform.flippedH() : a.transform.flippedV()
            }
        }
    }

    /// `geometry` with its points mirrored about its own bounds centre, or nil
    /// for geometries that aren't defined by a point list (a rect carries no
    /// orientation of its own, so mirroring its corners changes nothing —
    /// those keep the transform flag).
    static func mirroredPointGeometry(_ geometry: Geometry, horizontal: Bool) -> Geometry? {
        let b = geometryBounds(geometry)
        let center = CGPoint(x: b.midX, y: b.midY)
        func mirror(_ p: CGPoint) -> CGPoint {
            horizontal ? CGPoint(x: 2 * center.x - p.x, y: p.y)
                       : CGPoint(x: p.x, y: 2 * center.y - p.y)
        }
        switch geometry {
        case let .arrow(start, end):   return .arrow(start: mirror(start), end: mirror(end))
        case let .line(start, end):    return .line(start: mirror(start), end: mirror(end))
        case let .pen(points):         return .pen(points: points.map(mirror))
        case let .penArrow(points):    return .penArrow(points: points.map(mirror))
        default:                       return nil
        }
    }

    /// Append already-cloned (fresh-id) annotations, record undo, and make
    /// them the new selection. No-op for an empty array.
    ///
    /// `undoAction` names the step in the undo history — paste and duplicate
    /// share this path but must not both report "Paste".
    func insertPasted(_ pasted: [Annotation], undoAction: String = "Paste") {
        guard !pasted.isEmpty else { return }
        recordUndoCheckpoint(action: undoAction)
        annotations.append(contentsOf: pasted)
        selectedAnnotationIDs = Set(pasted.map { $0.id })
        // A single pasted object is highlighted; a pasted group has no default
        // primary (matches marquee / select-all).
        primarySelectionID = pasted.count == 1 ? pasted.first?.id : nil
    }

    /// How far a duplicate lands from its original, in image space. A fixed
    /// down-right nudge, not paste's cursor-centering: a duplicate belongs
    /// beside the thing it came from, and it must be visibly offset or the
    /// action reads as "nothing happened".
    static let duplicateOffset = CGVector(dx: 12, dy: 12)

    /// Clone the selection in place and select the clones.
    ///
    /// Deliberately does NOT write the clipboard — ⌘D would otherwise destroy
    /// whatever the user copied earlier, which is why this can't just be
    /// copy-then-paste. Duplicated `.image` annotations keep their original
    /// `assetID`: the asset dictionary is per-document, so no bitmap is copied.
    func duplicateSelected() {
        guard !isReadOnly else { return }
        let selected = annotations.filter { selectedAnnotationIDs.contains($0.id) }
        guard !selected.isEmpty else { return }
        insertPasted(clonedForPaste(selected, translatedBy: Self.duplicateOffset),
                     undoAction: "Duplicate")
    }
}
