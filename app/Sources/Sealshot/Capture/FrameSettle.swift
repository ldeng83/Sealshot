import CoreGraphics

/// Decides whether the scroll animation has settled between two consecutive
/// grabs of the same scroll position: downsample both to a coarse grayscale
/// grid and compare mean absolute difference. Pure and synchronous so the
/// auto-scroll loop can poll cheaply, and so it's unit-testable. This answers
/// "has the scroll *animation* stopped", which is distinct from the stitcher's
/// "did the page reach end-of-content".
enum FrameSettle {
    /// Side length of the coarse comparison grid.
    static let gridSize = 32
    /// Max mean-abs-difference (0–255 scale) for two frames to count as settled.
    static let defaultThreshold = 3.0

    static func isStable(_ a: CGImage, _ b: CGImage, threshold: Double = defaultThreshold) -> Bool {
        guard let ga = coarseGray(a), let gb = coarseGray(b), ga.count == gb.count, !ga.isEmpty
        else { return false }
        var sum = 0
        for i in 0..<ga.count { sum += abs(Int(ga[i]) - Int(gb[i])) }
        return Double(sum) / Double(ga.count) <= threshold
    }

    /// Render `img` into a `gridSize`×`gridSize` grayscale buffer (row-packed).
    private static func coarseGray(_ img: CGImage) -> [UInt8]? {
        let n = gridSize
        guard let ctx = CGContext(
            data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: n, height: n))
        guard let data = ctx.data else { return nil }
        let p = data.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * n)
        var out = [UInt8](); out.reserveCapacity(n * n)
        for y in 0..<n { for x in 0..<n { out.append(p[y * ctx.bytesPerRow + x]) } }
        return out
    }
}
