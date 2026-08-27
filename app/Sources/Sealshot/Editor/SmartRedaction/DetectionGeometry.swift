import CoreGraphics
import Foundation

/// Coordinate plumbing between OCR layouts (normalized [0,1], top-left
/// origin) and detection rects (1× image pixels, the `Annotation` space).
/// Pure geometry — no Vision, no AppKit.
enum DetectionGeometry {

    /// Union of the char boxes covering `range` in a recognized line
    /// (normalized space). The range is clamped to the available boxes; nil
    /// when nothing remains.
    static func normalizedBox(for range: Range<Int>, in line: RecognizedLine) -> CGRect? {
        let lo = max(0, min(range.lowerBound, line.charBoxes.count))
        let hi = max(lo, min(range.upperBound, line.charBoxes.count))
        guard lo < hi else { return nil }
        return line.charBoxes[lo..<hi].reduce(CGRect.null) { $0.union($1) }
    }

    /// Normalized top-left rect → 1× image pixels, expanded by `padding` on
    /// every side (so the redaction fully covers antialiased glyph edges) and
    /// clamped to the image bounds.
    static func imageRect(fromNormalized rect: CGRect, imageSize: CGSize,
                          padding: CGFloat = 4) -> CGRect {
        let scaled = CGRect(x: rect.minX * imageSize.width,
                            y: rect.minY * imageSize.height,
                            width: rect.width * imageSize.width,
                            height: rect.height * imageSize.height)
        return scaled.insetBy(dx: -padding, dy: -padding)
            .intersection(CGRect(origin: .zero, size: imageSize))
    }

    /// Merge rects transitively: any two that intersect collapse into their
    /// union, repeated until stable. Order of disjoint results is preserved.
    static func mergedRects(_ rects: [CGRect]) -> [CGRect] {
        var merged = rects
        var didMerge = true
        while didMerge {
            didMerge = false
            outer: for i in merged.indices {
                for j in merged.indices where j > i {
                    if merged[i].intersects(merged[j]) {
                        merged[i] = merged[i].union(merged[j])
                        merged.remove(at: j)
                        didMerge = true
                        break outer
                    }
                }
            }
        }
        return merged
    }

    /// Full-width vertical tiles covering an image, each at most
    /// `maxTileHeight` tall, consecutive tiles overlapping by at least
    /// `overlap` so no text line is cut at a seam. The last tile is anchored
    /// to the bottom edge (uniform tile size beats a short remainder tile —
    /// OCR quality is resolution-dependent).
    static func verticalTiles(for size: CGSize, maxTileHeight: CGFloat,
                              overlap: CGFloat) -> [CGRect] {
        guard size.height > maxTileHeight else {
            return [CGRect(origin: .zero, size: size)]
        }
        var tiles: [CGRect] = []
        let step = maxTileHeight - overlap
        var y: CGFloat = 0
        while true {
            if y + maxTileHeight >= size.height {
                tiles.append(CGRect(x: 0, y: size.height - maxTileHeight,
                                    width: size.width, height: maxTileHeight))
                break
            }
            tiles.append(CGRect(x: 0, y: y, width: size.width, height: maxTileHeight))
            y += step
        }
        return tiles
    }

    /// Drop detections that duplicate an earlier one — the same match seen by
    /// two adjacent tiles in their overlap band. Duplicate = same category +
    /// snippet with strongly overlapping bounds.
    static func dedup(_ detections: [Detection]) -> [Detection] {
        var kept: [Detection] = []
        for candidate in detections {
            let isDuplicate = kept.contains { existing in
                existing.category == candidate.category
                    && existing.snippet == candidate.snippet
                    && iou(bounds(of: existing), bounds(of: candidate)) > 0.5
            }
            if !isDuplicate { kept.append(candidate) }
        }
        return kept
    }

    // MARK: - Helpers

    private static func bounds(of detection: Detection) -> CGRect {
        detection.rects.reduce(CGRect.null) { $0.union($1) }
    }

    private static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        guard !inter.isNull, inter.width > 0, inter.height > 0 else { return 0 }
        let interArea = inter.width * inter.height
        let unionArea = a.width * a.height + b.width * b.height - interArea
        return unionArea > 0 ? interArea / unionArea : 0
    }
}
