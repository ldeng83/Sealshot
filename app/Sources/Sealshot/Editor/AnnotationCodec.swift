import Foundation
import CoreGraphics

/// On-disk shape for the annotation list embedded in a saved PNG's metadata.
/// `version` is bumped when the shape changes. The current writer emits
/// version 6 (adds per-annotation transform: rotation/flip); version 5 adds
/// `.image` geometry; version 4 adds `.blur` + `Style` blur fields; version 3
/// has the same envelope shape minus blur — all four decode through the current
/// model. The reader also accepts version 2 (`.text` stored a single `string`)
/// and the legacy version 1 (`Annotation { kind }`), migrating both.
private struct AnnotationsEnvelope: Codable {
    let version: Int
    let annotations: [Annotation]
    let croppedRect: CGRect?
    let focusRect: CGRect?
    /// v8: the document was resampled to this pixel size (after the crop, when
    /// one is set). `source.png` stays pristine at its captured size, so
    /// Resize's "Reset to original" works forever; annotations/focus are
    /// stored in RESIZED space, croppedRect in pristine-source space. nil =
    /// native size (all pre-v8 files decode to nil via the optional key).
    var resizedSize: CGSize?
    /// Whether the background-removed base (`cutout.png`) is the displayed
    /// one. Folded into v9 alongside backgroundFill (all landed in the same
    /// unreleased span); optional key — absent decodes to nil → false.
    var showingCutout: Bool?
    /// v9: a solid fill drawn BEHIND the base image (shows through the base's
    /// transparent regions / on a blank canvas). nil = transparent (all pre-v9
    /// files decode to nil via the optional key).
    var backgroundFill: SerializableColor?
    /// v11: region of the source actually shown when the canvas has been GROWN
    /// past its content (in the same space as `croppedRect`). Everything outside
    /// it is transparent, so a grown margin never reveals cropped-away source.
    /// nil = no grow (all pre-v11 files decode to nil via the optional key).
    var contentClip: CGRect?
}

/// Minimal probe that decodes only `version` so the reader can branch on the
/// envelope shape without committing to a full decode.
private struct VersionProbe: Codable {
    let version: Int
}

// MARK: - Legacy (version 1) mirror types

/// Mirror of the OLD `AnnotationKind` enum (pre-split). Kept byte-identical in
/// shape so synthesized `Codable` decodes legacy JSON exactly as it was
/// written. Used only for migration.
private enum LegacyKind: Codable, Equatable {
    case arrow(start: CGPoint, end: CGPoint, color: SerializableColor, strokeWidth: CGFloat)
    case rectangle(rect: CGRect, color: SerializableColor, strokeWidth: CGFloat)
}

/// Mirror of the OLD `Annotation` struct (pre-split): `{ id, kind }`.
private struct LegacyAnnotation: Codable {
    let id: UUID
    let kind: LegacyKind
}

/// Mirror of the OLD envelope for version 1.
private struct LegacyEnvelope: Codable {
    let version: Int
    let annotations: [LegacyAnnotation]
    let croppedRect: CGRect?
}

/// Map a legacy annotation into the current model. Geometry comes straight
/// from the legacy kind; the legacy color + stroke width become the style's
/// stroke, and the new properties take their defaults so the migrated
/// appearance is identical to before the split.
private func migrate(_ legacy: LegacyAnnotation) -> Annotation {
    switch legacy.kind {
    case let .arrow(start, end, color, strokeWidth):
        return Annotation(
            id: legacy.id,
            geometry: .arrow(start: start, end: end),
            style: Style(strokeColor: color, strokeWidth: strokeWidth)
        )
    case let .rectangle(rect, color, strokeWidth):
        return Annotation(
            id: legacy.id,
            geometry: .rectangle(rect: rect),
            style: Style(strokeColor: color, strokeWidth: strokeWidth)
        )
    }
}

// MARK: - Legacy (version 2) mirror — only `.text` changed shape (string → runs)

private enum V2Geometry: Codable {
    case arrow(start: CGPoint, end: CGPoint)
    case rectangle(rect: CGRect)
    case text(rect: CGRect, string: String)
    case ellipse(rect: CGRect)
    case line(start: CGPoint, end: CGPoint)
    case badge(center: CGPoint, radius: CGFloat)
}
private struct V2Annotation: Codable {
    let id: UUID
    let geometry: V2Geometry
    let style: Style
}
private struct V2Envelope: Codable {
    let version: Int
    let annotations: [V2Annotation]
    let croppedRect: CGRect?
}
private func migrateV2(_ a: V2Annotation) -> Annotation {
    let geometry: Geometry
    switch a.geometry {
    case let .arrow(s, e):  geometry = .arrow(start: s, end: e)
    case let .rectangle(r): geometry = .rectangle(rect: r)
    case let .ellipse(r):   geometry = .ellipse(rect: r)
    case let .line(s, e):   geometry = .line(start: s, end: e)
    case let .badge(c, r):  geometry = .badge(center: c, radius: r)
    case let .text(rect, string):
        geometry = .text(rect: rect, runs: [TextRun(
            text: string, color: a.style.strokeColor,
            fontSize: a.style.fontSize, isBold: a.style.isBold)])
    }
    return Annotation(id: a.id, geometry: geometry, style: a.style)
}

/// Encode an annotation list plus optional crop rect as versioned JSON.
/// Used by `AnnotatedPNGIO` to embed in PNG metadata. Throws on encode
/// failure (extremely unlikely with `Codable` value types). Always writes
/// version 8.
internal func encodeAnnotations(
    _ annotations: [Annotation],
    crop: CGRect?,
    contentClip: CGRect? = nil,
    focus: CGRect? = nil,
    resizedSize: CGSize? = nil,
    showingCutout: Bool = false,
    backgroundFill: SerializableColor? = nil
) throws -> Data {
    let envelope = AnnotationsEnvelope(
        version: 12,  // v12 adds Style.textLayoutWidth (text mask model)
        annotations: annotations,
        croppedRect: crop,
        focusRect: focus,
        resizedSize: resizedSize,
        showingCutout: showingCutout ? true : nil,
        backgroundFill: backgroundFill,
        contentClip: contentClip
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(envelope)
}

/// Decode the JSON written by `encodeAnnotations`. Accepts version 8 (current,
/// adds resizedSize), 7 (adds .cut transparent-hole geometry), 6 (pre-cut),
/// 5 (pre-transform), 4 (same shape, no .image), and 3 (same shape, no blur),
/// version 2 (`.text` as single string), and version 1 (legacy), migrating the
/// older ones on read. Throws on malformed data or an unknown version.
internal func decodeAnnotations(
    from data: Data
) throws -> (annotations: [Annotation], crop: CGRect?, focus: CGRect?,
            resizedSize: CGSize?, showingCutout: Bool,
            backgroundFill: SerializableColor?, contentClip: CGRect?) {
    let decoder = JSONDecoder()
    let probe = try decoder.decode(VersionProbe.self, from: data)
    switch probe.version {
    case 3, 4, 5, 6, 7, 8, 9, 10, 11, 12:
        // v3–v12 share the current envelope shape.
        // v5 adds .image geometry; v6 adds per-annotation transform (rotation/flip);
        // v7 adds .cut (transparent hole) geometry; v8 adds resizedSize; v9 adds
        // backgroundFill; v10 adds .penArrow geometry; v11 adds contentClip; v12
        // adds Style.textLayoutWidth (all new fields/Geometry cases decode via
        // synthesized/custom Codable — optional keys absent on older files).
        // Annotations lacking a "transform" key decode to identity via custom init(from:).
        let envelope = try decoder.decode(AnnotationsEnvelope.self, from: data)
        return (envelope.annotations, envelope.croppedRect, envelope.focusRect,
                envelope.resizedSize, envelope.showingCutout ?? false,
                envelope.backgroundFill, envelope.contentClip)
    case 2:
        let v2 = try decoder.decode(V2Envelope.self, from: data)
        return (v2.annotations.map(migrateV2), v2.croppedRect, nil, nil, false, nil, nil)
    case 1:
        let legacy = try decoder.decode(LegacyEnvelope.self, from: data)
        return (legacy.annotations.map(migrate), legacy.croppedRect, nil, nil, false, nil, nil)

    default:
        throw AnnotationCodecError.unsupportedVersion(probe.version)
    }
}

/// Errors from decoding an annotations envelope. `unsupportedVersion` means the
/// package was written by a NEWER build than this one (forward-incompatible) —
/// the caller surfaces that distinctly from a corrupt/unreadable file.
enum AnnotationCodecError: Error, LocalizedError {
    case unsupportedVersion(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let v):
            return "Unsupported annotation envelope version \(v)"
        }
    }
}
