import Foundation

/// Pure formatting for the left Info pane: the annotation summary line and
/// human-readable capture dates. Kept free of AppKit so it's unit-tested.
enum CaptureInfoFormatting {

    /// A canonical, stable ordering of annotation kinds for the breakdown,
    /// each with its singular/plural display label.
    /// Canonical ordering of annotation kinds for the breakdown, with display
    /// labels matching the rest of the UI's vocabulary (`ObjectRowDescriptor`:
    /// a badge is a "Step", freehand is a "Pen"), lowercased for the summary.
    private enum Kind: Int, CaseIterable {
        case arrow, rectangle, ellipse, line, text, pen, penArrow, badge, blur, image, cut

        init(_ geometry: Geometry) {
            switch geometry {
            case .arrow:     self = .arrow
            case .rectangle: self = .rectangle
            case .ellipse:   self = .ellipse
            case .line:      self = .line
            case .text:      self = .text
            case .pen:       self = .pen
            case .penArrow:  self = .penArrow
            case .badge:     self = .badge
            case .blur:      self = .blur
            case .image:     self = .image
            case .cut:       self = .cut
            }
        }

        var labels: (one: String, many: String) {
            switch self {
            case .arrow:     return ("line arrow", "line arrows")
            case .rectangle: return ("rectangle", "rectangles")
            case .ellipse:   return ("ellipse", "ellipses")
            case .line:      return ("line", "lines")
            case .text:      return ("text", "texts")
            case .pen:       return ("pen", "pens")
            case .penArrow:  return ("free arrow", "free arrows")
            case .badge:     return ("step", "steps")
            case .blur:      return ("blur", "blurs")
            case .image:     return ("image", "images")
            case .cut:       return ("cut", "cuts")
            }
        }
    }

    /// "N objects — 2 arrows, 1 text" (canonical type order, pluralized), or
    /// nil when there are no annotations.
    static func objectSummary(_ annotations: [Annotation]) -> String? {
        guard !annotations.isEmpty else { return nil }
        var counts: [Kind: Int] = [:]
        for a in annotations { counts[Kind(a.geometry), default: 0] += 1 }

        let total = annotations.count
        let breakdown = Kind.allCases.compactMap { kind -> String? in
            guard let n = counts[kind] else { return nil }
            return "\(n) \(n == 1 ? kind.labels.one : kind.labels.many)"
        }.joined(separator: ", ")

        return "\(total) \(total == 1 ? "object" : "objects") — \(breakdown)"
    }

    private static let isoParser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let display: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    /// Format a manifest ISO-8601 string as a localized medium date + short
    /// time, or nil if it can't be parsed. `now` is accepted for deterministic
    /// tests (and future relative formatting); the current output is absolute.
    static func displayDate(iso: String, now: Date = Date()) -> String? {
        guard let date = isoParser.date(from: iso) else { return nil }
        return display.string(from: date)
    }

    /// Same format, for a date that came from the filesystem rather than a
    /// manifest — a recording saved as a plain movie has no ISO string to
    /// parse, and its dates must still read identically to every other capture.
    static func displayDate(date: Date) -> String {
        display.string(from: date)
    }
}
