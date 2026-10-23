import CoreGraphics
import Vision

/// One round glyph Vision read as `O` or `0`, measured from the pixels.
///
/// Vision reads a capital O beside digits as a zero — "O-1042" → "0-1042",
/// "OO7" → "007" — with or without language correction, because it decides
/// from context rather than shape. The shapes do differ: in proportional fonts
/// O is much wider than 0 (aspect ≈ 0.9 against ≈ 0.7), and monospaced fonts,
/// whose O and 0 share a width, mark the zero with a slash or dot that an O's
/// hollow centre never has.
struct RoundGlyph: Equatable {
    let read: Character
    /// Ink-bounding-box width / height.
    let aspect: CGFloat
    /// Ink fraction of the central 40% of the ink box: a slash or dot.
    let centerInk: CGFloat
    /// Ink height in pixels — below a dozen, one pixel of antialiasing swings
    /// the aspect too far to decide anything on width.
    let inkHeight: CGFloat

    private static let markedZeroInk: CGFloat = 0.2
    private static let hollowInk: CGFloat = 0.1
    private static let minHeightForWidth: CGFloat = 12
    private static let minHeightForMark: CGFloat = 8
    /// Wider than any common zero, narrower than common capital O's.
    private static let letterAspect: CGFloat = 0.84
    /// Width ratio between the line's wide and narrow round glyphs that counts
    /// as two different shapes rather than noise.
    private static let clusterRatio: CGFloat = 1.15

    /// What each glyph of ONE line really is. Evidence is pooled across the
    /// line (one font, usually): a marked zero anywhere says the font marks its
    /// zeros, so the hollow ones are letters; two clear width groups say the
    /// wide ones are letters. Without either, only a clearly O-wide glyph is
    /// changed — a glyph that could be either keeps Vision's read.
    static func resolve(_ glyphs: [RoundGlyph]) -> [Character] {
        let markable = glyphs.filter { $0.inkHeight >= minHeightForMark }
        if markable.contains(where: { $0.centerInk >= markedZeroInk }) {
            return glyphs.map { g in
                guard g.inkHeight >= minHeightForMark else { return g.read }
                if g.centerInk >= markedZeroInk { return "0" }
                return g.centerInk < hollowInk ? "O" : g.read
            }
        }
        let measurable = glyphs.filter { $0.inkHeight >= minHeightForWidth && $0.centerInk < hollowInk }
        if let lo = measurable.map(\.aspect).min(), let hi = measurable.map(\.aspect).max(),
           lo > 0, hi / lo >= clusterRatio {
            let split = (lo + hi) / 2
            return glyphs.map { g in
                guard g.inkHeight >= minHeightForWidth, g.centerInk < hollowInk else { return g.read }
                return g.aspect >= split ? "O" : "0"
            }
        }
        return glyphs.map { g in
            g.read == "0" && g.inkHeight >= minHeightForWidth && g.centerInk < hollowInk
                && g.aspect >= letterAspect ? "O" : g.read
        }
    }
}

/// Correct O/0 misreads in `display` (Vision's `candidate.string` after
/// `foldStrayFullwidth`, which keeps characters 1:1) by measuring each round
/// glyph in `image`. Vision's own per-character boxes are its token's box
/// repeated, so glyphs are located by splitting each token's box on blank
/// columns; a token whose split doesn't yield exactly one run per character
/// (touching glyphs) is left alone.
func disambiguateRoundGlyphs(_ display: String, candidate: VNRecognizedText,
                             image: CGImage) -> String {
    let source = candidate.string
    guard display.contains(where: { $0 == "0" || $0 == "O" }) else { return display }
    let chars = Array(source)
    guard chars.count == Array(display).count else { return display }

    var glyphs: [RoundGlyph] = []
    var offsets: [Int] = []
    var i = 0
    while i < chars.count {
        if chars[i].isWhitespace { i += 1; continue }
        var j = i
        while j < chars.count, !chars[j].isWhitespace { j += 1 }
        defer { i = j }
        guard chars[i..<j].contains(where: { $0 == "0" || $0 == "O" }) else { continue }
        let lo = source.index(source.startIndex, offsetBy: i)
        let hi = source.index(source.startIndex, offsetBy: j)
        guard let box = try? candidate.boundingBox(for: lo..<hi)?.boundingBox,
              let ink = InkCrop(image, normalizedBottomLeft: box) else { continue }
        let runs = ink.glyphRuns()
        guard runs.count == j - i else { continue }
        for k in 0..<(j - i) where chars[i + k] == "0" || chars[i + k] == "O" {
            guard let m = ink.measure(columns: runs[k]) else { continue }
            glyphs.append(RoundGlyph(read: chars[i + k], aspect: m.aspect,
                                     centerInk: m.centerInk, inkHeight: m.height))
            offsets.append(i + k)
        }
    }
    guard !glyphs.isEmpty else { return display }
    var out = Array(display)
    for (offset, resolved) in zip(offsets, RoundGlyph.resolve(glyphs)) { out[offset] = resolved }
    return String(out)
}

/// A token's pixels as a binary ink mask, polarity-agnostic: ink is whatever
/// differs from the crop's border (dark-mode text is light on dark).
private struct InkCrop {
    let w: Int, h: Int
    private let ink: [Bool]

    init?(_ image: CGImage, normalizedBottomLeft box: CGRect) {
        let W = CGFloat(image.width), H = CGFloat(image.height)
        let rect = CGRect(x: box.minX * W, y: (1 - box.maxY) * H,
                          width: box.width * W, height: box.height * H)
            .insetBy(dx: -2, dy: -2).integral
            .intersection(CGRect(x: 0, y: 0, width: W, height: H))
        guard rect.width >= 3, rect.height >= 3,
              let crop = image.cropping(to: rect) else { return nil }
        w = crop.width; h = crop.height
        var gray = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &gray, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let lo = gray.min(), let hi = gray.max(), Int(hi) - Int(lo) >= 64 else { return nil }
        let threshold = (Int(lo) + Int(hi)) / 2
        var border = 0, n = 0
        for x in 0..<w { border += Int(gray[x]) + Int(gray[(h - 1) * w + x]); n += 2 }
        for y in 0..<h { border += Int(gray[y * w]) + Int(gray[y * w + w - 1]); n += 2 }
        let darkInk = border / n >= threshold
        ink = gray.map { darkInk ? Int($0) < threshold : Int($0) >= threshold }
    }

    private func at(_ x: Int, _ y: Int) -> Bool { ink[y * w + x] }

    /// Column ranges separated by fully blank columns.
    func glyphRuns() -> [Range<Int>] {
        var runs: [Range<Int>] = []
        var start: Int?
        for x in 0...w {
            let hasInk = x < w && (0..<h).contains { at(x, $0) }
            if hasInk, start == nil { start = x }
            if !hasInk, let s = start { runs.append(s..<x); start = nil }
        }
        return runs
    }

    func measure(columns: Range<Int>) -> (aspect: CGFloat, centerInk: CGFloat, height: CGFloat)? {
        let rows = (0..<h).filter { y in columns.contains { at($0, y) } }
        guard let top = rows.first, let bottom = rows.last else { return nil }
        let bw = columns.count, bh = bottom - top + 1
        guard bh > 0 else { return nil }
        let cx = (columns.lowerBound + bw * 3 / 10)..<max(columns.lowerBound + bw * 3 / 10 + 1,
                                                          columns.lowerBound + bw * 7 / 10)
        let cy = (top + bh * 3 / 10)..<max(top + bh * 3 / 10 + 1, top + bh * 7 / 10)
        var hits = 0
        for y in cy { for x in cx where at(x, y) { hits += 1 } }
        return (CGFloat(bw) / CGFloat(bh), CGFloat(hits) / CGFloat(cx.count * cy.count),
                CGFloat(bh))
    }
}
