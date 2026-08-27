import AppKit
import QuartzCore

/// The capture crosshair's hairlines and loupe, as CALayers that MOVE rather
/// than redraw.
///
/// Why this exists: the overlay rendered at ~25fps while hovering because the
/// crosshair was drawn in `draw(_:)`, and its hairlines span the full width and
/// height of the screen. NSView collapses dirty rects into their bounding box,
/// so any invalidation for the crosshair damaged the entire surface — measured
/// at `damage rects: 1.0 per frame`, 100% coverage. On a scaled Retina display
/// the compositor then rescaled a 3360x2100 surface every frame. Scrolling,
/// which damages only small highlight rects, already reached 60fps — that is
/// the evidence this is worth doing.
///
/// Repositioning a layer costs no rasterization at all: CoreAnimation moves an
/// existing texture and damage-tracks each layer separately, so the
/// bounding-box problem does not apply. The hairlines become solid-colour
/// layers whose frames change; the loupe becomes a magnified image layer
/// sliding behind a circular clip.
@MainActor
final class CrosshairLayers {

    /// Everything lives under one root so it can be shown/hidden and ordered
    /// as a unit above the view's drawn content.
    let root = CALayer()

    // Hairlines: four segments, each a dark halo behind a bright core, exactly
    // as `CrosshairRender.drawHairlines` paints them.
    private let haloLayers = (0..<4).map { _ in CALayer() }
    private let coreLayers = (0..<4).map { _ in CALayer() }
    private let dotHalo = CALayer()
    private let dotCore = CALayer()

    // Loupe: a circular clip containing an oversized image layer. Moving the
    // magnified view means moving that inner layer — no pixels are re-rendered.
    private let loupeClip = CALayer()
    private let loupeImageLayer = CALayer()
    private let loupeGuideH = CALayer()
    private let loupeGuideV = CALayer()
    private let loupeTickDark = CALayer()
    private let loupeTickLight = CALayer()
    private let loupeOuterRing = CALayer()

    private var frozenImage: CGImage?

    init() {
        root.zPosition = 1              // above the view's own drawn content
        // Origin at the layer's own corner so sublayer frames are plain view
        // coordinates rather than offsets from a centred anchor.
        root.anchorPoint = .zero
        let halo = NSColor.black.withAlphaComponent(0.4).cgColor
        let core = NSColor.white.withAlphaComponent(0.95).cgColor
        for layer in haloLayers { layer.backgroundColor = halo; root.addSublayer(layer) }
        for layer in coreLayers { layer.backgroundColor = core; root.addSublayer(layer) }
        dotHalo.backgroundColor = halo
        dotCore.backgroundColor = NSColor.white.cgColor
        root.addSublayer(dotHalo)
        root.addSublayer(dotCore)

        loupeClip.masksToBounds = true
        loupeClip.cornerRadius = CrosshairRender.loupeDiameter / 2
        // White ring; CA draws borders inside the bounds, matching the inset
        // oval the drawn version strokes.
        loupeClip.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        loupeClip.borderWidth = 2
        // Nearest-neighbour so magnified pixels stay hard blocks, as the drawn
        // loupe did with `interpolationQuality = .none`.
        loupeImageLayer.magnificationFilter = .nearest
        loupeImageLayer.anchorPoint = .zero
        let guide = NSColor.white.withAlphaComponent(0.35).cgColor
        loupeGuideH.backgroundColor = guide
        loupeGuideV.backgroundColor = guide
        loupeTickDark.borderColor = NSColor.black.withAlphaComponent(0.6).cgColor
        loupeTickDark.borderWidth = 3
        loupeTickLight.borderColor = NSColor.white.cgColor
        loupeTickLight.borderWidth = 1
        loupeClip.addSublayer(loupeImageLayer)
        loupeClip.addSublayer(loupeGuideH)
        loupeClip.addSublayer(loupeGuideV)
        loupeClip.addSublayer(loupeTickDark)
        loupeClip.addSublayer(loupeTickLight)
        loupeOuterRing.cornerRadius = CrosshairRender.loupeDiameter / 2
        loupeOuterRing.borderColor = NSColor.black.withAlphaComponent(0.5).cgColor
        loupeOuterRing.borderWidth = 1
        root.addSublayer(loupeClip)
        root.addSublayer(loupeOuterRing)
    }

    /// The frozen screen image this display's loupe magnifies. Assigned once
    /// per overlay session; the texture uploads a single time.
    func setFrozenImage(_ image: CGImage?) {
        guard frozenImage !== image else { return }
        frozenImage = image
        withoutAnimation { loupeImageLayer.contents = image }
    }

    /// Retina correctness: without this every layer renders at 1x and the
    /// hairlines and ring look soft.
    func setContentsScale(_ scale: CGFloat) {
        guard scale > 0 else { return }
        for layer in allLayers where layer.contentsScale != scale {
            layer.contentsScale = scale
        }
    }

    private var allLayers: [CALayer] {
        [root, dotHalo, dotCore, loupeClip, loupeImageLayer, loupeGuideH,
         loupeGuideV, loupeTickDark, loupeTickLight, loupeOuterRing]
            + haloLayers + coreLayers
    }

    /// Place the crosshair at `point`. Hidden entirely when `point` is nil (the
    /// cursor is on another display) or the caller says not to show it.
    func update(point: CGPoint?, in bounds: CGRect, visible: Bool) {
        guard visible, let point, bounds.contains(point) else {
            withoutAnimation { root.isHidden = true }
            return
        }
        withoutAnimation {
            root.isHidden = false
            root.frame = bounds
            layoutHairlines(at: point, in: bounds)
            layoutLoupe(at: point, in: bounds)
        }
    }

    private func layoutHairlines(at point: CGPoint, in bounds: CGRect) {
        let lines = CrosshairGeometry.hairlines(
            at: point, in: bounds,
            gap: CrosshairRender.gap, thickness: CrosshairRender.thickness)
        for (i, rect) in [lines.above, lines.below, lines.left, lines.right].enumerated() {
            let empty = rect.width <= 0 || rect.height <= 0
            haloLayers[i].isHidden = empty
            coreLayers[i].isHidden = empty
            guard !empty else { continue }
            haloLayers[i].frame = rect.insetBy(dx: -0.5, dy: -0.5)
            coreLayers[i].frame = rect
        }
        let dot = CGRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2)
        dotHalo.frame = dot.insetBy(dx: -1, dy: -1)
        dotCore.frame = dot
    }

    /// The loupe shows `loupeSourceViewRect` magnified by `loupeZoom`. Rather
    /// than cropping and scaling pixels each move, the whole frozen frame sits
    /// in an oversized child layer (bounds x zoom) and is SLID so the wanted
    /// region lands in the circular clip — geometry only.
    ///
    /// Deliberately not `contentsRect`: its unit-coordinate origin convention
    /// is easy to get wrong, whereas plain layer geometry follows the view's
    /// own coordinate space, which the frozen backdrop already relies on.
    private func layoutLoupe(at point: CGPoint, in bounds: CGRect) {
        let diameter = CrosshairRender.loupeDiameter
        let zoom = CrosshairRender.loupeZoom
        let origin = CrosshairGeometry.loupeOrigin(
            near: point, diameter: diameter, in: bounds,
            offset: CrosshairRender.loupeOffset)
        let frame = CGRect(origin: origin, size: CGSize(width: diameter, height: diameter))
        loupeClip.frame = frame
        loupeOuterRing.frame = frame

        let source = CrosshairGeometry.loupeSourceViewRect(
            center: point, zoom: zoom, diameter: diameter, in: bounds)
        // Inside the clip, view point v sits at (v - source.origin) * zoom, so
        // the image layer's origin is -source.origin * zoom.
        loupeImageLayer.bounds = CGRect(origin: .zero,
                                        size: CGSize(width: bounds.width * zoom,
                                                     height: bounds.height * zoom))
        loupeImageLayer.position = CGPoint(x: -source.minX * zoom, y: -source.minY * zoom)

        // Guides and tick are fixed relative to the loupe, so they only need
        // laying out when the diameter changes — cheap enough to just set.
        loupeGuideH.frame = CGRect(x: 0, y: diameter / 2 - 0.5, width: diameter, height: 1)
        loupeGuideV.frame = CGRect(x: diameter / 2 - 0.5, y: 0, width: 1, height: diameter)
        let tick = CGRect(x: diameter / 2 - 2.5, y: diameter / 2 - 2.5, width: 5, height: 5)
        loupeTickDark.frame = tick.insetBy(dx: -1, dy: -1)
        loupeTickLight.frame = tick
    }

    /// CoreAnimation animates layer property changes by default, which would
    /// make the crosshair lag the cursor by the implicit 0.25s.
    private func withoutAnimation(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }
}
