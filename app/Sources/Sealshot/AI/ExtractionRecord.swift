import CoreGraphics

/// A `CGRect` flattened for `Codable` persistence in the manifest.
struct RectDTO: Codable, Equatable {
    var x, y, w, h: Double
    init(_ r: CGRect) {
        x = Double(r.origin.x); y = Double(r.origin.y)
        w = Double(r.size.width); h = Double(r.size.height)
    }
    var cgRect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
    /// Rounded compare so sub-pixel focus differences don't miss the cache.
    static func ~= (a: RectDTO, b: RectDTO) -> Bool {
        a.x.rounded() == b.x.rounded() && a.y.rounded() == b.y.rounded()
            && a.w.rounded() == b.w.rounded() && a.h.rounded() == b.h.rounded()
    }
}

/// The persisted result of "Extract Structured Data": the structured items, the
/// composed Markdown (stored verbatim — FM output is non-deterministic), and the
/// focus area it was computed from. Re-opening Extract loads this instantly when
/// the focus area still matches; a different focus area is a cache miss.
struct ExtractionRecord: Codable, Equatable {
    /// Bump to re-derive on pipeline/format changes.
    static let currentVersion = 1

    var items: StructuredItems
    var markdown: String
    var focusRect: RectDTO?      // nil = whole image
    var version: Int

    /// Cache hit when the version is current and the focus area matches.
    func matches(focusRect rect: RectDTO?) -> Bool {
        guard version == Self.currentVersion else { return false }
        switch (focusRect, rect) {
        case (nil, nil): return true
        case let (a?, b?): return a ~= b
        default: return false
        }
    }
}
