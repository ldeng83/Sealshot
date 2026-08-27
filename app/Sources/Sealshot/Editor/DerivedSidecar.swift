import CoreGraphics
import Foundation

/// `derived.json` — everything about a capture that can always be computed
/// again, in one package entry.
///
/// **Only derived data belongs here.** Nothing whose loss is lost user work.
/// That rule is what makes this file safe to delete, rebuild, or drop outright
/// when a key rotation puts it out of reach. It also settles the one ambiguous
/// case: Smart Redaction's *detections* are derived and belong here, while the
/// redactions a user actually applied are editing and stay in
/// `annotations.json`. A cache eviction must never destroy someone's redaction.
///
/// Sections are held as OPAQUE blobs rather than decoded into known fields, for
/// two reasons. Reading one section then costs a decrypt plus a cheap envelope
/// parse instead of decoding every section — the Live Text layout runs to
/// hundreds of kilobytes, and the caller usually wants one thing. And a section
/// written by a newer build survives a round-trip through this one instead of
/// being silently dropped on the next save.
struct DerivedSidecar: Equatable {

    /// Bumped only for a change to the ENVELOPE. Sections carry their own
    /// versions, so a format change in one cannot invalidate the others.
    static let currentVersion = 1

    private(set) var version: Int
    private var sections: [String: Data]

    init() {
        version = Self.currentVersion
        sections = [:]
    }

    func section(_ name: String) -> Data? { sections[name] }

    mutating func setSection(_ name: String, data: Data) { sections[name] = data }

    mutating func removeSection(_ name: String) { sections.removeValue(forKey: name) }

    var sectionNames: [String] { Array(sections.keys) }

    // MARK: Coding

    private struct Wire: Codable {
        var version: Int
        var sections: [String: Data]
    }

    func encoded() -> Data {
        (try? JSONEncoder().encode(Wire(version: version, sections: sections))) ?? Data()
    }

    static func decode(_ data: Data) throws -> DerivedSidecar {
        let wire = try JSONDecoder().decode(Wire.self, from: data)
        var sidecar = DerivedSidecar()
        sidecar.version = wire.version
        sidecar.sections = wire.sections
        return sidecar
    }
}

/// What a derived section was computed from.
///
/// `modifiedISO8601` is the manifest's, NOT the package's file mtime: writing
/// this sidecar changes the package's mtime, so anchoring on that would make
/// every section invalidate itself the moment it was saved. Only a real save
/// touches the manifest, which is exactly when a section should go stale.
///
/// `sourceBytes` covers the gap that timestamp leaves — the manifest stamp has
/// second resolution, so two saves inside one second would otherwise look
/// identical.
struct DerivedAnchor: Codable, Equatable {
    let modifiedISO8601: String
    let sourceBytes: Int

    func matches(_ other: DerivedAnchor) -> Bool {
        modifiedISO8601 == other.modifiedISO8601 && sourceBytes == other.sourceBytes
    }
}

/// Which base image a layout describes. The enhanced and cutout bases are
/// genuinely different pixels, so their layouts are separate records rather
/// than overwrites of each other.
enum DerivedBase: String, Codable, Equatable {
    case source, enhanced, cutout
}

/// The Live Text layout for one base of one capture, as stored in `derived.json`.
///
/// Geometry is encoded as flat single-precision arrays rather than nested
/// objects of `Double`s. A text-heavy capture reaches ~8,000 character boxes;
/// the nested form runs to about a megabyte, the flat form to a tenth of that,
/// and normalized [0,1] coordinates have no use for double precision.
///
/// Only `.full`-policy layouts are ever stored. The background metadata pass
/// runs `.budgeted` — capped lines, no sharpened variant on Intel — and serving
/// one of those to Live Text would quietly degrade selection with nothing
/// looking wrong.
struct TextLayoutSection: Equatable {

    static let name = "textLayout"
    static let currentVersion = 1

    let anchor: DerivedAnchor
    let base: DerivedBase
    let crop: CGRect?
    let width: Int
    let height: Int
    let layout: RecognizedTextLayout

    /// Identity of this record within the section: which pixels it describes.
    var recordKey: String {
        let cropPart = crop.map { "\($0.origin.x),\($0.origin.y),\($0.width),\($0.height)" }
            ?? "full"
        return "\(base.rawValue)|\(width)x\(height)|\(cropPart)"
    }

    /// True when this record still describes the package as it stands.
    func isValid(for current: DerivedAnchor) -> Bool { anchor.matches(current) }

    // MARK: Coding

    private struct WireLine: Codable {
        var text: String
        /// x, y, w, h
        var box: [Float]
        /// 8 values (TL, TR, BR, BL) or absent for a quad-less line.
        var quad: [Float]?
        /// Flat, four per character.
        var chars: [Float]
    }

    private struct Wire: Codable {
        var version: Int
        var anchor: DerivedAnchor
        var base: DerivedBase
        var crop: [Float]?
        var width: Int
        var height: Int
        var lines: [WireLine]
    }

    func encoded() -> Data {
        let wire = Wire(
            version: Self.currentVersion, anchor: anchor, base: base,
            crop: crop.map { [Float($0.origin.x), Float($0.origin.y),
                              Float($0.width), Float($0.height)] },
            width: width, height: height,
            lines: layout.lines.map { line in
                WireLine(text: line.text,
                         box: Self.flatten(line.box),
                         quad: line.quad.map(Self.flatten),
                         chars: line.charBoxes.flatMap(Self.flatten))
            })
        return (try? JSONEncoder().encode(wire)) ?? Data()
    }

    static func decode(_ data: Data) throws -> TextLayoutSection {
        let wire = try JSONDecoder().decode(Wire.self, from: data)
        let lines = wire.lines.map { line in
            // `characters` is derived from `text` inside RecognizedLine's init —
            // encoding it would be a second copy free to disagree with the first.
            RecognizedLine(text: line.text,
                           box: unflattenRect(line.box),
                           charBoxes: stride(from: 0, to: line.chars.count - 3, by: 4)
                               .map { unflattenRect(Array(line.chars[$0..<($0 + 4)])) },
                           quad: line.quad.flatMap(unflattenQuad))
        }
        return TextLayoutSection(
            anchor: wire.anchor, base: wire.base,
            crop: wire.crop.map { unflattenRect($0) },
            width: wire.width, height: wire.height,
            layout: RecognizedTextLayout(lines: lines))
    }

    private static func flatten(_ r: CGRect) -> [Float] {
        [Float(r.origin.x), Float(r.origin.y), Float(r.width), Float(r.height)]
    }

    private static func flatten(_ q: TextQuad) -> [Float] {
        [Float(q.topLeft.x), Float(q.topLeft.y), Float(q.topRight.x), Float(q.topRight.y),
         Float(q.bottomRight.x), Float(q.bottomRight.y),
         Float(q.bottomLeft.x), Float(q.bottomLeft.y)]
    }
}

private func unflattenRect(_ v: [Float]) -> CGRect {
    guard v.count >= 4 else { return .zero }
    return CGRect(x: CGFloat(v[0]), y: CGFloat(v[1]),
                  width: CGFloat(v[2]), height: CGFloat(v[3]))
}

private func unflattenQuad(_ v: [Float]) -> TextQuad? {
    guard v.count >= 8 else { return nil }
    func point(_ i: Int) -> CGPoint { CGPoint(x: CGFloat(v[i]), y: CGFloat(v[i + 1])) }
    return TextQuad(topLeft: point(0), topRight: point(2),
                    bottomRight: point(4), bottomLeft: point(6))
}
