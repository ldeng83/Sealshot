import AppKit

/// Builds the render path for a freehand `.pen` stroke. The stored geometry is
/// the raw drag points (a polyline); rendering turns them into a smooth curve so
/// fast strokes — whose OS drag samples are spaced far apart and carry hand
/// tremor — don't show angular kinks or wobble.
///
/// Four stages: **(1)** low-pass the input ("streamline") to take out jitter,
/// **(2)** resample to an even arc-length step so slow drawing doesn't leave
/// clusters, **(3)** fit least-squares cubics within a tolerance, and **(4)**
/// pin the end to where the user lifted.
///
/// Stage 3 APPROXIMATES rather than interpolates, and that is the point. An
/// interpolating curve (this used centripetal Catmull-Rom) must pass through
/// every sample, so hand tremor is reproduced exactly rather than removed — the
/// curve is obliged to visit each wobble. Fitting lets it miss by up to
/// `fitTolerance`, which is what turns a shaky track into a line that looks
/// intended.
///
/// Fitting happens in fixed-index CHUNKS. Least squares is global, so a single
/// span re-solves the whole stroke's control points on every new sample and the
/// part already on screen visibly squirms — "jelly". Chunk boundaries at fixed
/// multiples of `fitChunk` confine that to the chunk under the cursor.
///
/// Smoothing is **render-only**: the raw points stay the source of truth
/// (hit-testing, bounds, resize, persistence all use them), and the same curve
/// is produced for the live preview, the committed drawing, and the export
/// composite so they match.
enum PenPath {


    /// A smooth curve through `points`, in the coordinate space of `points`
    /// (callers convert to view/image space first). Attributes (line width /
    /// caps / joins) and stroking are the caller's job.
    ///
    /// - 0 points → empty path.
    /// - 1 point → a zero-length segment (a round cap renders it as a dot).
    /// - 2 points → a straight line.
    /// - 3+ points → streamlined, resampled, then fitted with cubics.
    /// The end is ALWAYS pinned, live strokes included. Skipping it while
    /// drawing was tried, on the theory that re-correcting a sliding tail was
    /// what made the stroke squirm — it is not; chunked fitting already holds
    /// the drawn prefix still (measured: zero movement per sample either way).
    /// What skipping it actually cost was 6+ units of lag between the ink and
    /// the pointer, and ink that trails then springs forward reads as far more
    /// rubbery than the thing it was meant to cure.
    /// Live and finished strokes want opposite things, so they get different
    /// settings rather than one compromise.
    ///
    /// WHILE DRAWING the constraint is stability: anything that smooths hard
    /// also lags the pointer or shifts the line already drawn, and both read as
    /// "jelly". So the pre-filter is off, the fit tracks closely, and fitting is
    /// chunked to stop new samples re-solving what is already on screen.
    ///
    /// AFTER RELEASE none of that applies — nothing more is arriving. The
    /// pre-filter comes back, the fit is allowed to stray further, and the
    /// stroke is fit as ONE span: chunking exists only to protect a growing
    /// stroke, and dropping it removes the seams too. The stroke visibly
    /// settles as it commits, which is the point.
    struct Profile {
        let streamline: CGFloat
        let tolerance: CGFloat
        /// Resampled points per independently-fitted chunk; 0 = fit as one span.
        let chunk: Int
        let spacing: CGFloat
    }

    static let liveProfile = Profile(streamline: 1.0, tolerance: 0.75,
                                     chunk: 12, spacing: 1.5)
    static let finishedProfile = Profile(streamline: 0.4, tolerance: 2.0,
                                         chunk: 0, spacing: 1.5)

    static func smoothedPath(_ rawPoints: [CGPoint], finished: Bool = true) -> NSBezierPath {
        let profile = finished ? finishedProfile : liveProfile
        let pts = dedup(streamlined(rawPoints, strength: profile.streamline))
        let path = NSBezierPath()
        guard let first = pts.first else { return path }
        path.move(to: first)

        guard pts.count > 2 else {
            for p in pts.dropFirst() { path.line(to: p) }
            if pts.count == 1 { path.line(to: first) }   // dot for a single tap
            return path
        }

        // FIT rather than interpolate.
        //
        // Catmull-Rom passed through every surviving sample, so hand tremor and
        // sensor jitter were reproduced exactly rather than attenuated — the
        // curve had to visit each wobble. Resampling to an even spacing first
        // removes the clusters that build up when the pointer moves slowly (the
        // dedup epsilon is 0.01, so nothing thinned them), and least-squares
        // fitting then approximates the track within a tolerance instead of
        // honouring each point. This is what Illustrator's pencil and Procreate
        // do, and it is the difference between "follows my hand exactly" and
        // "looks like I meant it".
        let fitPoints = resampled(pts, spacing: profile.spacing)
        for seg in fitCubics(fitPoints, tolerance: profile.tolerance, chunk: profile.chunk) {
            path.curve(to: seg.p3, controlPoint1: seg.c1, controlPoint2: seg.c2)
        }
        return path
    }

    /// Even arc-length resampling. Drawing slowly packs many samples into a
    /// pixel or two; fitting those directly wastes segments on noise, so the
    /// track is walked at a fixed step. First and last points are always kept
    /// (the end pin depends on the last one surviving).
    static func resampled(_ points: [CGPoint], spacing: CGFloat) -> [CGPoint] {
        guard points.count > 2, spacing > 0 else { return points }
        var out = [points[0]]
        var carry: CGFloat = 0
        for i in 1..<points.count {
            var prev = points[i - 1]
            let next = points[i]
            var segLen = hypot(next.x - prev.x, next.y - prev.y)
            while carry + segLen >= spacing {
                let need = spacing - carry
                let t = need / segLen
                let p = CGPoint(x: prev.x + (next.x - prev.x) * t,
                                y: prev.y + (next.y - prev.y) * t)
                out.append(p)
                prev = p
                segLen = hypot(next.x - prev.x, next.y - prev.y)
                carry = 0
            }
            carry += segLen
        }
        if let last = points.last, out.last.map({ hypot($0.x - last.x, $0.y - last.y) > 1e-6 }) ?? true {
            out.append(last)
        }
        return out.count >= 2 ? out : points
    }

    /// Outward tangents of the *rendered* curve at its endpoints — the exact
    /// direction the drawn stroke leaves the start (pointing back, away from the
    /// stroke) and the end (pointing forward). Read from the first/last cubic
    /// segment's control handles, so a free-arrow head aimed with these matches
    /// the visible curve on straights and curves alike. `nil` for a zero-length
    /// end. Coordinate space is that of `rawPoints`.
    /// Outward tangents at the two ends of the *rendered* stroke, each measured
    /// over `lookback` of arc length along the flattened smooth curve. Reading
    /// the flattened rendered curve (not the raw drag points) matches what is
    /// actually drawn; using a fixed arc-length span keeps both ends stable and
    /// symmetric — the raw start segment is tiny/jittery (dense drag sampling +
    /// direction-dependent streamlining), so a per-segment tangent mis-orients it.
    static func endpointTangents(_ rawPoints: [CGPoint], lookback: CGFloat)
        -> (start: CGVector?, end: CGVector?) {
        let pts = polyline(smoothedPath(rawPoints))
        guard pts.count >= 2 else { return (nil, nil) }
        return (start: outwardTangent(pts, atEnd: false, lookback: lookback),
                end: outwardTangent(pts, atEnd: true, lookback: lookback))
    }

    /// Flatten a path to its on-curve polyline points (the visible curve).
    private static func polyline(_ path: NSBezierPath) -> [CGPoint] {
        let flat = path.flattened
        var out: [CGPoint] = []
        var p = [NSPoint](repeating: .zero, count: 3)
        for i in 0..<flat.elementCount {
            switch flat.element(at: i, associatedPoints: &p) {
            case .moveTo, .lineTo: out.append(p[0])
            default: break
            }
        }
        return out
    }

    /// Outward direction at one end of `pts`: walk inward from the endpoint
    /// accumulating arc length until it passes `lookback`, then aim from there to
    /// the endpoint. Falls back to the whole-stroke direction for a short path.
    private static func outwardTangent(_ pts: [CGPoint], atEnd: Bool, lookback: CGFloat) -> CGVector? {
        let seq = atEnd ? Array(pts.reversed()) : pts   // seq[0] = the endpoint
        let tip = seq[0]
        var acc: CGFloat = 0
        var prev = tip
        for i in 1..<seq.count {
            let q = seq[i]
            acc += hypot(q.x - prev.x, q.y - prev.y)
            prev = q
            if acc >= lookback {
                let v = CGVector(dx: tip.x - q.x, dy: tip.y - q.y)
                if hypot(v.dx, v.dy) > 1e-4 { return v }
            }
        }
        let far = seq[seq.count - 1]
        let v = CGVector(dx: tip.x - far.x, dy: tip.y - far.y)
        return hypot(v.dx, v.dy) > 1e-4 ? v : nil
    }

    /// Low-pass ("streamline"): pull each point toward the raw sample from the
    /// previous smoothed point, removing hand tremor / sampling jitter. The
    /// final point is pinned to the true endpoint so the stroke ends where the
    /// user lifted.
    /// Number of tail points the end-pin correction is spread across.
    private static let endPinRamp = 8




    struct CubicSegment { let c1: CGPoint; let c2: CGPoint; let p3: CGPoint }

    /// Internal rather than private so the end-pin behaviour can be asserted
    /// directly; not part of the type's intended API.
    static func streamlined(_ points: [CGPoint],
                            strength: CGFloat = 1.0) -> [CGPoint] {
        guard points.count > 2, strength < 1.0 else { return points }
        var out = [points[0]]
        var prev = points[0]
        for i in 1..<points.count {
            let raw = points[i]
            prev = CGPoint(x: prev.x + (raw.x - prev.x) * strength,
                           y: prev.y + (raw.y - prev.y) * strength)
            out.append(prev)
        }

        // Pin the end to the true cursor position WITHOUT a kink.
        //
        // The filter lags the input by design, so the last filtered point sits
        // short of where the pointer actually stopped. Overwriting just that
        // one point — which is what this did — closes the whole accumulated lag
        // in a single step, bending the final segment away from the curve and
        // leaving a small hook at the end of every stroke.
        //
        // Spreading the identical correction across the last few points with a
        // linear ramp lands the stroke on exactly the same endpoint, but
        // reaches it smoothly instead of turning a corner to get there.
        let target = points[points.count - 1]
        let dx = target.x - out[out.count - 1].x
        let dy = target.y - out[out.count - 1].y
        let ramp = min(out.count, endPinRamp)
        for k in 0..<ramp {
            let idx = out.count - ramp + k
            let t = CGFloat(k + 1) / CGFloat(ramp)      // 0 → 1 across the tail
            out[idx] = CGPoint(x: out[idx].x + dx * t, y: out[idx].y + dy * t)
        }
        return out
    }

    // MARK: - Curve fitting (least-squares cubics, after Schneider)

    /// Fit as few cubic Béziers as will stay within `tolerance` of `pts`.
    ///
    /// Fitted in fixed-index CHUNKS rather than as one span, and that is what
    /// keeps a live stroke from squirming. Least squares is global: solved over
    /// the whole stroke, every new sample re-solves the control points for all
    /// of it, so the part already on screen shifts on every mouse event.
    /// Chunk boundaries sit at fixed multiples of `fitChunk`, so appending can
    /// only alter the chunk currently under the cursor — everything behind it
    /// is bit-identical from one frame to the next.
    ///
    /// Boundary tangents are shared (each chunk starts along the previous
    /// chunk's outgoing direction) so the joins stay C1 and the seams are not
    /// visible.
    static func fitCubics(_ pts: [CGPoint], tolerance: CGFloat,
                          chunk: Int = 12) -> [CubicSegment] {
        guard pts.count > 1 else { return [] }
        // chunk <= 0: one span. Only safe when the stroke has stopped growing.
        let step = chunk > 0 ? chunk : pts.count
        var out: [CubicSegment] = []
        var start = 0
        // Windowed, for the same reason as the chunk joins below: `pts[1] -
        // pts[0]` is two adjacent samples, and on a tremulous stroke those sit
        // on opposite sides of a wobble — the very first handle then leans by
        // the tremor and the fit chases it.
        var leftT = endTangent(pts, fromStart: true)
        while start < pts.count - 1 {
            let end = min(start + step, pts.count - 1)
            let rightT: CGVector
            if end == pts.count - 1 {
                rightT = endTangent(pts, fromStart: false)
            } else {
                // Mid-stroke boundary: direction measured BACKWARD, using only
                // points inside this chunk.
                //
                // Looking across the join (at points after `end`) meant a
                // finished chunk kept changing for several more samples as
                // those arrived — the drawn line shifting behind the pointer,
                // which is what "a previous slice moved" describes. Depending
                // only on its own points makes a chunk final the moment it is
                // complete.
                //
                // Still a WINDOW rather than one neighbour: on a tremulous
                // stroke two adjacent samples sit on opposite sides of a wobble
                // and tilt the tangent by the tremor the fit exists to remove.
                rightT = backwardTangent(pts, from: start, to: end)
            }
            out += fitCubic(Array(pts[start...end]), leftT, rightT, tolerance, depth: 0)
            leftT = CGVector(dx: -rightT.dx, dy: -rightT.dy)
            start = end
        }
        return out
    }

    /// `depth` bounds the subdivision. A pathological stroke (a scribble that is
    /// mostly corners) would otherwise recurse per point; past the cap the
    /// remaining span is emitted as one chord-handle segment, which is what the
    /// old code effectively produced anyway.
    private static func fitCubic(_ pts: [CGPoint], _ leftT: CGVector, _ rightT: CGVector,
                                 _ tolerance: CGFloat, depth: Int) -> [CubicSegment] {
        let chordThird = { () -> [CubicSegment] in
            let d = hypot(pts[pts.count - 1].x - pts[0].x,
                          pts[pts.count - 1].y - pts[0].y) / 3
            return [CubicSegment(c1: add(pts[0], scale(leftT, d)),
                                 c2: add(pts[pts.count - 1], scale(rightT, d)),
                                 p3: pts[pts.count - 1])]
        }
        guard pts.count > 2, depth < 16 else { return chordThird() }

        var u = chordLengthParameterize(pts)
        var bez = generateBezier(pts, u, leftT, rightT)
        var (err, splitIdx) = maxError(pts, bez, u)
        if err < tolerance { return [bez] }

        // Near enough to be worth refining the parameterisation before
        // subdividing — this is what keeps the segment count (and so the
        // wobble) down instead of splitting at the first sign of error.
        if err < tolerance * 4 {
            for _ in 0..<4 {
                u = reparameterize(pts, u, bez)
                bez = generateBezier(pts, u, leftT, rightT)
                (err, splitIdx) = maxError(pts, bez, u)
                if err < tolerance { return [bez] }
            }
        }

        let split = min(max(splitIdx, 1), pts.count - 2)
        let centerT = normalized(CGVector(dx: pts[split - 1].x - pts[split + 1].x,
                                          dy: pts[split - 1].y - pts[split + 1].y))
        return fitCubic(Array(pts[0...split]), leftT, centerT, tolerance, depth: depth + 1)
             + fitCubic(Array(pts[split...]),
                        CGVector(dx: -centerT.dx, dy: -centerT.dy), rightT,
                        tolerance, depth: depth + 1)
    }

    /// Least-squares solve for the two interior control points, with the end
    /// tangents held fixed so neighbouring segments stay smooth at the joins.
    private static func generateBezier(_ pts: [CGPoint], _ u: [CGFloat],
                                       _ leftT: CGVector, _ rightT: CGVector) -> CubicSegment {
        let first = pts[0], last = pts[pts.count - 1]
        var c00: CGFloat = 0, c01: CGFloat = 0, c11: CGFloat = 0
        var x0: CGFloat = 0, x1: CGFloat = 0
        for i in 0..<pts.count {
            let t = u[i], mt = 1 - t
            let b0 = mt * mt * mt, b1 = 3 * t * mt * mt
            let b2 = 3 * t * t * mt, b3 = t * t * t
            let a0 = scale(leftT, b1), a1 = scale(rightT, b2)
            c00 += a0.dx * a0.dx + a0.dy * a0.dy
            c01 += a0.dx * a1.dx + a0.dy * a1.dy
            c11 += a1.dx * a1.dx + a1.dy * a1.dy
            let rx = pts[i].x - (first.x * (b0 + b1) + last.x * (b2 + b3))
            let ry = pts[i].y - (first.y * (b0 + b1) + last.y * (b2 + b3))
            x0 += a0.dx * rx + a0.dy * ry
            x1 += a1.dx * rx + a1.dy * ry
        }
        let det = c00 * c11 - c01 * c01
        let chord = hypot(last.x - first.x, last.y - first.y)
        guard abs(det) > 1e-12 else {
            let d = chord / 3
            return CubicSegment(c1: add(first, scale(leftT, d)),
                                c2: add(last, scale(rightT, d)), p3: last)
        }
        let alphaL = (c11 * x0 - c01 * x1) / det
        let alphaR = (c00 * x1 - c01 * x0) / det
        // A non-positive handle turns the curve inside out; fall back rather
        // than emit a cusp.
        guard alphaL > 1e-6 * chord, alphaR > 1e-6 * chord else {
            let d = chord / 3
            return CubicSegment(c1: add(first, scale(leftT, d)),
                                c2: add(last, scale(rightT, d)), p3: last)
        }
        return CubicSegment(c1: add(first, scale(leftT, alphaL)),
                            c2: add(last, scale(rightT, alphaR)), p3: last)
    }

    /// Direction at the stroke's start (pointing forward into it) or end
    /// (pointing back into it), measured over a window for the same reason as
    /// `backwardTangent`.
    private static func endTangent(_ pts: [CGPoint], fromStart: Bool,
                                   window: Int = 3) -> CGVector {
        let n = pts.count
        if fromStart {
            let j = min(window, n - 1)
            let v = normalized(sub(pts[j], pts[0]))
            return (abs(v.dx) > 1e-9 || abs(v.dy) > 1e-9) ? v : normalized(sub(pts[1], pts[0]))
        }
        let j = max(0, n - 1 - window)
        let v = normalized(sub(pts[j], pts[n - 1]))
        return (abs(v.dx) > 1e-9 || abs(v.dy) > 1e-9) ? v : normalized(sub(pts[n - 2], pts[n - 1]))
    }

    /// Direction at a chunk's end, measured backward over a window that stays
    /// INSIDE the chunk (`from`...`to`). Causal by construction: it cannot
    /// change once the chunk is complete, however many samples arrive later.
    /// Points "backwards" along the stroke, matching the right-tangent
    /// convention.
    private static func backwardTangent(_ pts: [CGPoint], from start: Int, to end: Int,
                                        window: Int = 3) -> CGVector {
        let lo = max(start, end - window)
        let v = normalized(CGVector(dx: pts[lo].x - pts[end].x, dy: pts[lo].y - pts[end].y))
        if abs(v.dx) < 1e-9 && abs(v.dy) < 1e-9 {
            let prev = max(start, end - 1)
            return normalized(CGVector(dx: pts[prev].x - pts[end].x,
                                       dy: pts[prev].y - pts[end].y))
        }
        return v
    }

    private static func bezierPoint(_ p0: CGPoint, _ b: CubicSegment, _ t: CGFloat) -> CGPoint {
        let mt = 1 - t
        let b0 = mt * mt * mt, b1 = 3 * t * mt * mt
        let b2 = 3 * t * t * mt, b3 = t * t * t
        return CGPoint(x: p0.x * b0 + b.c1.x * b1 + b.c2.x * b2 + b.p3.x * b3,
                       y: p0.y * b0 + b.c1.y * b1 + b.c2.y * b2 + b.p3.y * b3)
    }

    /// Worst distance from the samples to the fitted curve, and where it occurs.
    private static func maxError(_ pts: [CGPoint], _ b: CubicSegment,
                                 _ u: [CGFloat]) -> (CGFloat, Int) {
        var worst: CGFloat = 0
        var idx = pts.count / 2
        for i in 1..<(pts.count - 1) {
            let q = bezierPoint(pts[0], b, u[i])
            let d = hypot(q.x - pts[i].x, q.y - pts[i].y)
            if d > worst { worst = d; idx = i }
        }
        return (worst, idx)
    }

    /// One Newton-Raphson step per sample toward the nearest point on the curve.
    private static func reparameterize(_ pts: [CGPoint], _ u: [CGFloat],
                                       _ b: CubicSegment) -> [CGFloat] {
        var out = u
        for i in 0..<pts.count {
            let t = u[i], mt = 1 - t
            let q = bezierPoint(pts[0], b, t)
            let d1 = CGPoint(
                x: 3 * mt * mt * (b.c1.x - pts[0].x) + 6 * mt * t * (b.c2.x - b.c1.x)
                    + 3 * t * t * (b.p3.x - b.c2.x),
                y: 3 * mt * mt * (b.c1.y - pts[0].y) + 6 * mt * t * (b.c2.y - b.c1.y)
                    + 3 * t * t * (b.p3.y - b.c2.y))
            let d2 = CGPoint(
                x: 6 * mt * (b.c2.x - 2 * b.c1.x + pts[0].x) + 6 * t * (b.p3.x - 2 * b.c2.x + b.c1.x),
                y: 6 * mt * (b.c2.y - 2 * b.c1.y + pts[0].y) + 6 * t * (b.p3.y - 2 * b.c2.y + b.c1.y))
            let num = (q.x - pts[i].x) * d1.x + (q.y - pts[i].y) * d1.y
            let den = d1.x * d1.x + d1.y * d1.y
                    + (q.x - pts[i].x) * d2.x + (q.y - pts[i].y) * d2.y
            if abs(den) > 1e-12 { out[i] = min(max(t - num / den, 0), 1) }
        }
        return out
    }

    private static func chordLengthParameterize(_ pts: [CGPoint]) -> [CGFloat] {
        var u = [CGFloat](repeating: 0, count: pts.count)
        for i in 1..<pts.count {
            u[i] = u[i - 1] + hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y)
        }
        let total = u[pts.count - 1]
        guard total > 1e-12 else {
            for i in 0..<pts.count { u[i] = CGFloat(i) / CGFloat(pts.count - 1) }
            return u
        }
        for i in 0..<pts.count { u[i] /= total }
        return u
    }

    private static func sub(_ a: CGPoint, _ b: CGPoint) -> CGVector {
        CGVector(dx: a.x - b.x, dy: a.y - b.y)
    }
    private static func add(_ p: CGPoint, _ v: CGVector) -> CGPoint {
        CGPoint(x: p.x + v.dx, y: p.y + v.dy)
    }
    private static func scale(_ v: CGVector, _ s: CGFloat) -> CGVector {
        CGVector(dx: v.dx * s, dy: v.dy * s)
    }
    private static func normalized(_ v: CGVector) -> CGVector {
        let m = hypot(v.dx, v.dy)
        return m > 1e-12 ? CGVector(dx: v.dx / m, dy: v.dy / m) : CGVector(dx: 0, dy: 0)
    }

    /// Drop consecutive near-coincident points so the curve fit never divides by
    /// a zero-length chord.
    private static func dedup(_ points: [CGPoint], eps: CGFloat = 0.01) -> [CGPoint] {
        guard var prev = points.first else { return [] }
        var out = [prev]
        for p in points.dropFirst() where hypot(p.x - prev.x, p.y - prev.y) > eps {
            out.append(p); prev = p
        }
        return out
    }
}
