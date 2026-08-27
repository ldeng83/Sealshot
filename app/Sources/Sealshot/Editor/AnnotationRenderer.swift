import AppKit
import CoreGraphics

/// Compose a final NSImage from a source image, annotation list, and optional
/// crop rect. Used by `EditorCanvasView` for live drawing and by
/// `EditorSaveCoordinator` for the saved PNG.
///
/// The crop rect (if any) is in the *original* source image's coordinate
/// space. Annotations are in the *currently visible* image's coordinate
/// space (post-crop if a crop is active). `EditorState` translates
/// annotations on `commitCrop()` so this invariant holds.
///
/// `scale` lets the caller pass a higher-resolution base image (e.g. the 2×
/// enhanced bitmap) while keeping annotations/crop in 1× source coordinates.
/// At `scale == 1.0` (the default) behavior is identical to before.
internal func render(
    image: CGImage,
    annotations: [Annotation],
    crop: CGRect?,
    contentClip: CGRect? = nil,
    scale: CGFloat = 1.0,
    focus: CGRect? = nil,
    assets: [String: CGImage] = [:],
    backgroundFill: SerializableColor? = nil
) -> NSImage {
    // Annotations/crop are always in the 1× source coordinate space.
    // `image` may be a `scale`×-resolution base (e.g. the 2× enhanced bitmap).
    let annotationSpace: CGSize = crop?.size
        ?? CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
    let outputSize = CGSize(width: annotationSpace.width * scale,
                            height: annotationSpace.height * scale)
    let h = annotationSpace.height

    // Draw into an explicit 1× bitmap rep rather than `NSImage.lockFocus`.
    // lockFocus adopts the current screen's backing scale, so on a Retina
    // display it produced a 2× raster — blurring/bloating the export and making
    // the result non-deterministic (see RenderResolutionTests). An explicit rep
    // pins output to exactly `outputSize` pixels AND is thread-safe, so callers
    // can render off the main thread.
    let pixelsWide = max(1, Int(outputSize.width.rounded()))
    let pixelsHigh = max(1, Int(outputSize.height.rounded()))
    let composite = NSImage(size: outputSize)
    guard var rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { return composite }
    // Render in the SOURCE image's colorspace, not the device's. The capture
    // is raw framebuffer bytes tagged with the capture display's profile
    // (ScreenCaptureKit output — same policy as Apple's `screencapture`);
    // drawing it into a same-space context is byte-preserving and the
    // composite keeps that honest tag. A device destination color-converts
    // the base (visibly lightening dark text on non-sRGB monitors) and then
    // labels the shifted values with an unrelated profile. Retagging
    // reinterprets the destination without touching bytes; the sRGB fallback
    // for untagged/non-RGB sources keeps output deterministic.
    let sourceSpace = image.colorSpace.flatMap { cs -> NSColorSpace? in
        cs.model == .rgb ? NSColorSpace(cgColorSpace: cs) : nil
    } ?? .sRGB
    if let retagged = rep.retagging(with: sourceSpace) { rep = retagged }
    guard let nsctx = NSGraphicsContext(bitmapImageRep: rep) else { return composite }
    rep.size = outputSize
    composite.addRepresentation(rep)
    do {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsctx
        defer {
            nsctx.flushGraphics()
            NSGraphicsContext.restoreGraphicsState()
        }

        // 1. Base image into the full output rect. The crop is a VIEWPORT into
        //    the source that may overhang its edge (a grown canvas) — where it
        //    renders transparent (the background fill below paints it).
        if let crop = crop {
            let visible = CanvasExpander.viewportBase(
                from: image, crop: crop, contentClip: contentClip, baseScale: scale)
            NSBitmapImageRep(cgImage: visible).draw(in: CGRect(origin: .zero, size: outputSize))
        } else {
            NSBitmapImageRep(cgImage: image).draw(in: CGRect(origin: .zero, size: outputSize))
        }

        // 1.5 Background fill BEHIND the base. Painted AFTER the base with
        //    `.destinationOver` so it lands only where the base is transparent
        //    (Cut holes, a blank canvas) and leaves opaque base pixels alone.
        //    nil = no fill, so the exported PNG keeps its alpha.
        if let backgroundFill = backgroundFill {
            let cg = nsctx.cgContext
            cg.saveGState()
            cg.setBlendMode(.destinationOver)
            cg.setFillColor(backgroundFill.nsColor.cgColor)
            cg.fill(CGRect(origin: .zero, size: outputSize))
            cg.restoreGState()
        }

        // 2. Scale the context so 1×-space annotation coords land on the scaled output.
        if scale != 1.0 {
            let t = NSAffineTransform()
            t.scale(by: scale)
            t.concat()
        }

        // 3. Annotations, drawn in 1× space (flip uses the 1× height `h`).
        for annotation in annotations {
            let style = annotation.style
            let t = annotation.transform
            // Blur is the EXCEPTION: only its MASK rotates (sampled pixels stay
            // axis-aligned), so .blur transforms its clip path internally rather
            // than concatenating the context. Every other geometry wraps here.
            let ctx = NSGraphicsContext.current?.cgContext
            ctx?.saveGState()
            defer { ctx?.restoreGState() }
            // Screen-space shadow, set before any rotation so it never rotates
            // with the object. Export context is y-up → yDown:false; the context
            // is already scaled by `scale`, so pass scale:1.
            if geometryCastsShadow(annotation.geometry) {
                applyShadow(style.shadow, to: ctx, yDown: false, scale: 1)
            }
            if !t.isIdentity, !annotation.geometry.isBlur, let ctx {
                let b = geometryBounds(annotation.geometry)
                let c = flipY(CGPoint(x: b.midX, y: b.midY), height: h)
                ctx.concatenate(renderMatrix(for: t, center: c))
            }
            // Contrasting outline (casing): a wider stroke in `outlineColor` drawn
            // BENEATH the normal stroke so the mark stays legible on busy/same-color
            // backgrounds. nil = no outline. Total casing = strokeWidth + 2·width.
            let outlineNSColor = style.outlineColor.map { applyOpacity($0.nsColor, opacity: style.opacity) }
            let casingWidth = style.strokeWidth + 2 * style.outlineWidth
            switch annotation.geometry {
            case let .arrow(start, end):
                drawConnector(from: flipY(start, height: h), to: flipY(end, height: h),
                              width: style.strokeWidth,
                              color: applyOpacity(style.strokeColor.nsColor, opacity: style.opacity),
                              dash: style.dashStyle, startCap: style.startCap, endCap: style.endCap,
                              shaft: style.shaftStyle,
                              outlineColor: outlineNSColor, outlineWidth: style.outlineWidth)
            case let .rectangle(rect):
                if let oc = outlineNSColor {
                    drawRectangle(rect: flipRectY(rect, height: h), strokeColor: oc, fillColor: nil,
                                  strokeWidth: casingWidth,
                                  cornerRadius: clampedCornerRadius(style.cornerRadius, for: rect))
                }
                drawRectangle(rect: flipRectY(rect, height: h),
                              strokeColor: applyOpacity(style.strokeColor.nsColor, opacity: style.opacity),
                              fillColor: style.fillColor.map { applyOpacity($0.nsColor, opacity: style.opacity) },
                              strokeWidth: style.strokeWidth,
                              cornerRadius: clampedCornerRadius(style.cornerRadius, for: rect))
            case let .text(rect, runs):
                // Text mask model: layout happens at `layoutW` (the box's own
                // width, or a wider stored `textLayoutWidth` after a manual
                // shrink) but the box `rect` is a MASK — content is clipped to
                // it rather than re-wrapped to the narrower width. nil
                // `textLayoutWidth` (legacy files, never-shrunk boxes) makes
                // `layoutW == rect.width`, so the clip is a no-op and behavior
                // is identical to before.
                let flipped = flipRectY(rect, height: h)
                let layoutW = style.effectiveTextLayoutWidth(rect: rect)
                // Text occupies the box inset by `textBoxHPadding` on each side.
                let textW = max(1, layoutW - 2 * textBoxHPadding)
                let content = textBoxHeight(runs: runs, width: textW, lineSpacing: style.lineSpacing)
                let dr = verticalAlignedRect(flipped, contentHeight: content,
                                             vAlign: style.textVerticalAlignment, flipped: false)
                let layoutX = textLayoutOriginX(alignment: style.textAlignment,
                                                boxMinX: dr.minX + textBoxHPadding,
                                                boxMaxX: dr.maxX - textBoxHPadding, layoutWidth: textW)
                let layoutRect = CGRect(x: layoutX, y: dr.minY, width: textW, height: dr.height)
                ctx?.saveGState()
                ctx?.clip(to: flipped)
                if textRunsHaveOutline(runs) {
                    // Paint order: strokes first (expanding outward, round
                    // joins so fat outlines don't spike), fills on top.
                    ctx?.setLineJoin(.round)
                    ctx?.setLineCap(.round)
                    attributedString(for: runs, opacity: style.opacity,
                                     alignment: style.textAlignment, lineSpacing: style.lineSpacing,
                                     pass: .stroke)
                        .draw(in: layoutRect)
                    attributedString(for: runs, opacity: style.opacity,
                                     alignment: style.textAlignment, lineSpacing: style.lineSpacing,
                                     pass: .fill)
                        .draw(in: layoutRect)
                } else {
                    attributedString(for: runs, opacity: style.opacity,
                                     alignment: style.textAlignment, lineSpacing: style.lineSpacing)
                        .draw(in: layoutRect)
                }
                ctx?.restoreGState()
            case let .ellipse(rect):
                if let oc = outlineNSColor {
                    drawEllipse(rect: flipRectY(rect, height: h), strokeColor: oc, fillColor: nil,
                                strokeWidth: casingWidth)
                }
                drawEllipse(rect: flipRectY(rect, height: h),
                            strokeColor: applyOpacity(style.strokeColor.nsColor, opacity: style.opacity),
                            fillColor: style.fillColor.map { applyOpacity($0.nsColor, opacity: style.opacity) },
                            strokeWidth: style.strokeWidth)
            case let .line(start, end):
                drawConnector(from: flipY(start, height: h), to: flipY(end, height: h),
                              width: style.strokeWidth,
                              color: applyOpacity(style.strokeColor.nsColor, opacity: style.opacity),
                              dash: style.dashStyle, startCap: .none, endCap: .none,
                              outlineColor: outlineNSColor, outlineWidth: style.outlineWidth)
            case let .badge(center, radius):
                if let oc = outlineNSColor {
                    // A ring around the badge: a larger disc in the outline color.
                    let r = radius + style.outlineWidth
                    let c = flipY(center, height: h)
                    oc.setFill()
                    NSBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)).fill()
                }
                drawBadge(center: flipY(center, height: h), radius: radius,
                          number: badgeNumber(for: annotation.id, in: annotations) ?? 0,
                          fillColor: applyOpacity((style.fillColor ?? SerializableColor(.systemRed)).nsColor, opacity: style.opacity),
                          numberColor: applyOpacity(style.strokeColor.nsColor, opacity: style.opacity))
            case let .pen(points):
                if let oc = outlineNSColor {
                    drawPen(points: points.map { flipY($0, height: h) }, color: oc, strokeWidth: casingWidth)
                }
                drawPen(points: points.map { flipY($0, height: h) },
                        color: applyOpacity(style.strokeColor.nsColor, opacity: style.opacity),
                        strokeWidth: style.strokeWidth)
            case let .penArrow(points):
                drawPenArrow(points: points.map { flipY($0, height: h) },
                             color: applyOpacity(style.strokeColor.nsColor, opacity: style.opacity),
                             strokeWidth: style.strokeWidth,
                             startCap: style.startCap, endCap: style.endCap,
                             outlineColor: outlineNSColor, outlineWidth: style.outlineWidth)
            case let .blur(region):
                drawBlurRegion(region, style: style, source: image,
                               cropOrigin: crop?.origin ?? .zero, scale: scale, height: h,
                               transform: t)
            case let .image(rect, assetID):
                if let overlay = assets[assetID] {
                    NSGraphicsContext.current?.saveGraphicsState()
                    defer { NSGraphicsContext.current?.restoreGraphicsState() }
                    NSGraphicsContext.current?.imageInterpolation = .high
                    NSImage(cgImage: overlay,
                            size: NSSize(width: overlay.width, height: overlay.height))
                        .draw(in: flipRectY(rect, height: h),
                              from: .zero,
                              operation: .sourceOver,
                              fraction: style.opacity)
                }
                // Missing asset → skip silently (graceful degradation)
            case let .cut(rect):
                // Punch a true transparent hole: blend mode .clear sets pixels to alpha-0,
                // which survives PNG export. The bitmap rep is hasAlpha:true so clearing is
                // lossless. Map image-space rect to the rep's coordinate space the same way
                // the adjacent .rectangle case does — Y-flip via flipRectY(rect, height: h).
                if let ctx = NSGraphicsContext.current?.cgContext {
                    ctx.saveGState()
                    ctx.setBlendMode(.clear)
                    ctx.fill(flipRectY(rect, height: h))
                    ctx.restoreGState()
                }
            }
        }

        // 3.5 Re-apply the background fill so it ALSO shows through any regions
        //     the annotations left transparent — notably `.cut` holes, which
        //     punch alpha to 0 and thereby clear even the pre-annotation fill
        //     from step 1.5. `.destinationOver` touches only alpha-0 pixels, so
        //     opaque base/annotation pixels are untouched. The context is still
        //     scaled by `scale` here, so fill in 1× (`annotationSpace`) coords.
        if let backgroundFill = backgroundFill,
           let cg = NSGraphicsContext.current?.cgContext {
            cg.saveGState()
            cg.setBlendMode(.destinationOver)
            cg.setFillColor(backgroundFill.nsColor.cgColor)
            cg.fill(CGRect(origin: .zero, size: annotationSpace))
            cg.restoreGState()
        }
    }

    guard let focus = focus else { return composite }
    guard let cg = composite.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        return composite
    }
    // focus is 1×-visible coords; scale to output pixels like the crop above.
    let sf = CGRect(x: focus.minX * scale, y: focus.minY * scale,
                    width: focus.width * scale, height: focus.height * scale)
        .integral
        .intersection(CGRect(x: 0, y: 0, width: CGFloat(cg.width), height: CGFloat(cg.height)))
    guard !sf.isNull, sf.width > 0, sf.height > 0, let cropped = cg.cropping(to: sf) else {
        return composite
    }
    return NSImage(cgImage: cropped, size: CGSize(width: sf.width, height: sf.height))
}

/// Draw a blur region into the current (flipped, scaled-by-`scale`) renderer
/// context: filter the source pixels via `BlurRenderer`, clip to the region
/// shape, and composite. Blur ignores `Style.opacity` — a half-transparent
/// redaction would defeat the purpose.
private func drawBlurRegion(
    _ region: BlurRegion,
    style: Style,
    source: CGImage,
    cropOrigin: CGPoint,
    scale: CGFloat,
    height h: CGFloat,
    transform t: AnnotationTransform
) {
    guard let (cg, bbox) = BlurRenderer.filteredRegionImage(
        region: region, mode: style.blurMode, strength: style.blurStrength,
        solidColor: BlurRenderer.solidColor(for: style),
        source: source, cropOrigin: cropOrigin, scale: scale
    ) else { return }
    NSGraphicsContext.current?.saveGraphicsState()
    defer { NSGraphicsContext.current?.restoreGraphicsState() }
    let clip = BlurRenderer.clipPath(
        for: region,
        mapRect: { flipRectY($0, height: h) },
        mapPoint: { flipY($0, height: h) },
        mapLength: { $0 }
    )
    // Transform only the mask: build the matrix about the region's flipY'd
    // center (the renderer's y-up drawing space).
    let rb = region.boundingRect
    let center = flipY(CGPoint(x: rb.midX, y: rb.midY), height: h)
    BlurRenderer.transformedClipPath(clip, transform: t, center: center, yDown: false)
        .addClip()
    NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        .draw(in: flipRectY(bbox, height: h), from: .zero, operation: .sourceOver, fraction: 1.0)
}

/// Translate each annotation's coordinates so they are relative to the new
/// crop origin. Annotations that fall entirely outside the crop rect are
/// dropped. Preserves `id` and `style` — only geometry translates/clips.
internal func cropAndClipAnnotations(
    _ annotations: [Annotation],
    to cropRect: CGRect
) -> [Annotation] {
    let dx = cropRect.minX
    let dy = cropRect.minY
    let cropBounds = CGRect(origin: .zero, size: cropRect.size)

    return annotations.compactMap { annotation in
        let delta = CGVector(dx: -dx, dy: -dy)
        // Rotated/flipped objects keep their FULL geometry — per-case rect
        // clipping would axis-align a rotated shape. They survive iff their
        // transformed AABB still overlaps the crop rect; the canvas/raster
        // bounds clip them visually.
        if !annotation.transform.isIdentity {
            let moved = translatedGeometry(annotation.geometry, by: delta)
            let aabb = transformedAABB(bounds: geometryBounds(moved),
                                       transform: annotation.transform)
            guard aabb.intersects(cropBounds) else { return nil }
            return Annotation(id: annotation.id, geometry: moved,
                              style: annotation.style, transform: annotation.transform)
        }

        switch annotation.geometry {
        case let .arrow(start, end):
            let newStart = CGPoint(x: start.x - dx, y: start.y - dy)
            let newEnd   = CGPoint(x: end.x   - dx, y: end.y   - dy)
            return Annotation(
                id: annotation.id,
                geometry: .arrow(start: newStart, end: newEnd),
                style: annotation.style,
                transform: annotation.transform
            )

        case let .rectangle(rect):
            let translated = rect.offsetBy(dx: -dx, dy: -dy)
            let clipped = translated.intersection(cropBounds)
            guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else {
                return nil
            }
            return Annotation(
                id: annotation.id,
                geometry: .rectangle(rect: clipped),
                style: annotation.style,
                transform: annotation.transform
            )

        case let .text(rect, runs):
            let translated = rect.offsetBy(dx: -dx, dy: -dy)
            guard translated.intersects(cropBounds) else { return nil }
            return Annotation(
                id: annotation.id,
                geometry: .text(rect: translated, runs: runs),
                style: annotation.style,
                transform: annotation.transform
            )

        case let .ellipse(rect):
            let translated = rect.offsetBy(dx: -dx, dy: -dy)
            let clipped = translated.intersection(cropBounds)
            guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return nil }
            return Annotation(id: annotation.id, geometry: .ellipse(rect: clipped),
                              style: annotation.style, transform: annotation.transform)

        case let .line(start, end):
            return Annotation(
                id: annotation.id,
                geometry: .line(start: CGPoint(x: start.x - dx, y: start.y - dy),
                                end: CGPoint(x: end.x - dx, y: end.y - dy)),
                style: annotation.style,
                transform: annotation.transform)

        case let .badge(center, radius):
            let c = CGPoint(x: center.x - dx, y: center.y - dy)
            let bbox = CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2)
            guard bbox.intersects(cropBounds) else { return nil }
            return Annotation(id: annotation.id, geometry: .badge(center: c, radius: radius),
                              style: annotation.style, transform: annotation.transform)

        case let .pen(points):
            let moved = points.map { CGPoint(x: $0.x - dx, y: $0.y - dy) }
            guard geometryBounds(.pen(points: moved)).intersects(cropBounds) else { return nil }
            return Annotation(id: annotation.id, geometry: .pen(points: moved),
                              style: annotation.style, transform: annotation.transform)

        case let .penArrow(points):
            let moved = points.map { CGPoint(x: $0.x - dx, y: $0.y - dy) }
            guard geometryBounds(.penArrow(points: moved)).intersects(cropBounds) else { return nil }
            return Annotation(id: annotation.id, geometry: .penArrow(points: moved),
                              style: annotation.style, transform: annotation.transform)

        case let .blur(region):
            let moved = region.offsetBy(dx: -dx, dy: -dy)
            guard moved.boundingRect.intersects(cropBounds) else { return nil }
            return Annotation(id: annotation.id, geometry: .blur(region: moved),
                              style: annotation.style, transform: annotation.transform)

        case let .image(rect, assetID):
            let translated = rect.offsetBy(dx: -dx, dy: -dy)
            let clipped = translated.intersection(cropBounds)
            guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return nil }
            // Known v1 limitation: the draw arm squeezes the FULL bitmap into
            // the clipped rect, so an overlay cut by the crop edge distorts
            // rather than crops (vector shapes shrink cleanly). The fix is a
            // `from:` source sub-rect proportional to the clip.
            return Annotation(
                id: annotation.id,
                geometry: .image(rect: clipped, assetID: assetID),
                style: annotation.style,
                transform: annotation.transform
            )

        case let .cut(rect):
            // Mirror rectangle: translate and clip to crop bounds.
            let translated = rect.offsetBy(dx: -dx, dy: -dy)
            let clipped = translated.intersection(cropBounds)
            guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return nil }
            return Annotation(
                id: annotation.id,
                geometry: .cut(rect: clipped),
                style: annotation.style,
                transform: annotation.transform
            )
        }
    }
}

private func flipY(_ point: CGPoint, height: CGFloat) -> CGPoint {
    CGPoint(x: point.x, y: height - point.y)
}

private func flipRectY(_ rect: CGRect, height: CGFloat) -> CGRect {
    CGRect(
        x: rect.origin.x,
        y: height - rect.origin.y - rect.size.height,
        width: rect.size.width,
        height: rect.size.height
    )
}

/// Stroke a freehand path as a rounded polyline through `points`.
/// `finished: false` is the stroke still under the cursor — it uses PenPath's
/// live profile (light smoothing, chunked, no lag) instead of the committed
/// one, so the shaft matches what the pen tool draws.
func drawPen(points: [CGPoint], color: NSColor, strokeWidth: CGFloat,
             finished: Bool = true) {
    guard strokeWidth > 0, !points.isEmpty else { return }
    color.setStroke()
    // Smoothed curve through the raw points — matches the live/committed canvas
    // render (PenPath). A single point becomes a round-capped dot.
    let path = PenPath.smoothedPath(points, finished: finished)
    path.lineWidth = strokeWidth
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    path.stroke()
}

/// Freehand arrow: the smoothed pen stroke plus arrowhead caps at the ends, each
/// oriented along the path's local tangent. `points` are in the drawing context's
/// coordinate space (already y-flipped by the caller, like `drawPen`).
func drawPenArrow(points: [CGPoint], color: NSColor, strokeWidth: CGFloat,
                  startCap: ArrowCap, endCap: ArrowCap,
                  outlineColor: NSColor? = nil, outlineWidth: CGFloat = 0,
                  finished: Bool = true) {
    guard points.count >= 2, strokeWidth > 0 else {
        drawPen(points: points, color: color, strokeWidth: strokeWidth, finished: finished)
        return
    }
    // One shadow for the whole arrow. The shaft, the two heads and the casing
    // beneath them are separate drawing operations, and CGContext stamps the
    // shadow per operation — so without grouping the shaft's shadow falls on
    // the head and the head's falls back on the shaft, showing as a grey smudge
    // exactly where they meet. Same fix as `drawConnector` and
    // `drawShapeAsOneObject`.
    drawingAsOneObject(alpha: color.alphaComponent) {
        drawPenArrowBody(points: points, color: color, strokeWidth: strokeWidth,
                         startCap: startCap, endCap: endCap,
                         outlineColor: outlineColor, outlineWidth: outlineWidth,
                         finished: finished)
    }
}

private func drawPenArrowBody(points: [CGPoint], color: NSColor, strokeWidth: CGFloat,
                              startCap: ArrowCap, endCap: ArrowCap,
                              outlineColor: NSColor?, outlineWidth: CGFloat,
                              finished: Bool) {
    // Opaque inside the layer; the layer is composited once at the real alpha,
    // so overlapping pieces cannot stack alpha at the join either.
    let color = color.alphaComponent < 1 ? color.withAlphaComponent(1) : color
    let outlineColor = outlineColor.map { $0.alphaComponent < 1 ? $0.withAlphaComponent(1) : $0 }
    let casingWidth = strokeWidth + 2 * outlineWidth
    // Orient each head over the head's own footprint (~its length) along the
    // rendered curve (not the raw drag points), so start/end stay stable,
    // symmetric, and follow the smoothed stroke on curves.
    let headLen = max(14, strokeWidth * 2.6)
    let (startT, endT) = PenPath.endpointTangents(points, lookback: headLen)
    // Push the apex past the round line cap so the filled head is the clean
    // outermost element (no cap "bead" beyond it) and sits at the very tip.
    let tipOffset = strokeWidth

    // Contrasting casing beneath: wider pen stroke + uniform head outline.
    if let oc = outlineColor, outlineWidth > 0 {
        drawPen(points: points, color: oc, strokeWidth: casingWidth, finished: finished)
        if endCap != .none, let dir = endT, let last = points.last {
            let tip = offsetPoint(last, along: dir, by: tipOffset)
            if endCap == .filled {
                drawFilledHeadOutline(tip: tip, direction: dir, width: strokeWidth,
                                      color: oc, outlineWidth: outlineWidth)
            } else {
                drawArrowCap(endCap, at: tip, direction: dir, width: casingWidth, color: oc)
            }
        }
        if startCap != .none, let dir = startT, let first = points.first {
            let tip = offsetPoint(first, along: dir, by: tipOffset)
            if startCap == .filled {
                drawFilledHeadOutline(tip: tip, direction: dir, width: strokeWidth,
                                      color: oc, outlineWidth: outlineWidth)
            } else {
                drawArrowCap(startCap, at: tip, direction: dir, width: casingWidth, color: oc)
            }
        }
    }

    drawPen(points: points, color: color, strokeWidth: strokeWidth, finished: finished)
    if endCap != .none, let dir = endT, let last = points.last {
        drawArrowCap(endCap, at: offsetPoint(last, along: dir, by: tipOffset),
                     direction: dir, width: strokeWidth, color: color)
    }
    if startCap != .none, let dir = startT, let first = points.first {
        drawArrowCap(startCap, at: offsetPoint(first, along: dir, by: tipOffset),
                     direction: dir, width: strokeWidth, color: color)
    }
}

/// `p` moved `distance` along `v` (v need not be unit length).
private func offsetPoint(_ p: CGPoint, along v: CGVector, by distance: CGFloat) -> CGPoint {
    let len = max(hypot(v.dx, v.dy), 1e-4)
    return CGPoint(x: p.x + v.dx / len * distance, y: p.y + v.dy / len * distance)
}

/// Draw a fill + stroke shape so it casts a SINGLE shadow for the whole
/// object. When filled, compositing fill and stroke inside a transparency
/// layer first means the context's shadow (set by the caller) applies once to
/// the union silhouette — instead of the fill and the stroke each stamping
/// their own offset shadow, which stacks a wrong-looking "line shadow" over a
/// filled shape. Hollow shapes (fill == nil) are drawn directly and unchanged:
/// a lone stroke already casts just its outline shadow. Shared by the live
/// canvas and the export renderer so the two stay identical.
func drawShapeAsOneObject(
    _ path: NSBezierPath, fill: NSColor?, stroke: NSColor, strokeWidth: CGFloat
) {
    let ctx = NSGraphicsContext.current?.cgContext
    let unify = (fill != nil)
    if unify { ctx?.beginTransparencyLayer(auxiliaryInfo: nil) }
    if let fill {
        fill.setFill()
        path.fill()
    }
    if strokeWidth > 0 {
        path.lineWidth = strokeWidth
        stroke.setStroke()
        path.stroke()
    }
    if unify { ctx?.endTransparencyLayer() }
}

private func drawRectangle(
    rect: CGRect,
    strokeColor: NSColor,
    fillColor: NSColor?,
    strokeWidth: CGFloat,
    cornerRadius: CGFloat
) {
    let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
    drawShapeAsOneObject(path, fill: fillColor, stroke: strokeColor, strokeWidth: strokeWidth)
}

/// Draw `number` centered (both axes) within `rect`, flip-agnostic so the live
/// canvas and the export renderer match. `draw(in:)` lays text upright anchored
/// at the rect's top in any context, unlike `draw(at:)` whose origin convention
/// differs between flipped and non-flipped contexts.
func drawCenteredBadgeNumber(_ number: Int, in rect: CGRect, fontSize: CGFloat, color: NSColor) {
    let para = NSMutableParagraphStyle()
    para.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
        .foregroundColor: color,
        .paragraphStyle: para
    ]
    let s = "\(number)" as NSString
    let textH = s.size(withAttributes: attrs).height
    let textRect = CGRect(x: rect.minX, y: rect.midY - textH / 2, width: rect.width, height: textH)
    s.draw(in: textRect, withAttributes: attrs)
}

private func drawBadge(center: CGPoint, radius: CGFloat, number: Int, fillColor: NSColor, numberColor: NSColor) {
    let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    fillColor.setFill()
    NSBezierPath(ovalIn: rect).fill()
    drawCenteredBadgeNumber(number, in: rect, fontSize: radius, color: numberColor)
}

private func drawEllipse(rect: CGRect, strokeColor: NSColor, fillColor: NSColor?, strokeWidth: CGFloat) {
    let path = NSBezierPath(ovalIn: rect)
    drawShapeAsOneObject(path, fill: fillColor, stroke: strokeColor, strokeWidth: strokeWidth)
}
