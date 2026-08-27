import CoreGraphics
import Foundation

/// Pure math for the editor's Resize popover: unit conversions (px / % / in /
/// cm at a DPI), aspect-ratio-locked field editing, and the size clamps. No
/// AppKit — fully unit-testable.
enum ResizeMath {

    enum Unit: String, CaseIterable {
        case pixels = "px"
        case percent = "%"
        case inches = "in"
        case centimeters = "cm"
    }

    /// Hard floors/ceilings for the resulting document, in pixels. The upscale
    /// factor cap guards the editor's large-canvas lineage (huge CA backings);
    /// the absolute side cap bounds pathological unit/DPI combinations.
    static let minSidePx: CGFloat = 8
    static let maxUpscaleFactor: CGFloat = 4
    static let maxSidePx: CGFloat = 16_384
    static let defaultDPI: CGFloat = 144

    /// Pixels → display value in `unit`. Percent is relative to `original`'s
    /// matching axis; physical units divide by `dpi`.
    static func displayValue(pixels: CGFloat, unit: Unit, originalAxis: CGFloat,
                             dpi: CGFloat) -> CGFloat {
        switch unit {
        case .pixels: return pixels.rounded()
        case .percent: return originalAxis > 0 ? pixels / originalAxis * 100 : 0
        case .inches: return dpi > 0 ? pixels / dpi : 0
        case .centimeters: return dpi > 0 ? pixels / dpi * 2.54 : 0
        }
    }

    /// Display value in `unit` → pixels (inverse of `displayValue`).
    static func pixels(fromDisplay value: CGFloat, unit: Unit, originalAxis: CGFloat,
                       dpi: CGFloat) -> CGFloat {
        switch unit {
        case .pixels: return value
        case .percent: return value / 100 * originalAxis
        case .inches: return value * dpi
        case .centimeters: return value / 2.54 * dpi
        }
    }

    /// One field was edited: produce the new target size, following the lock.
    /// `axisIsWidth` says which field changed; `enteredPx` is its new pixel
    /// value; `current` is the pre-edit target (its ratio drives the lock).
    static func applyingEdit(enteredPx: CGFloat, axisIsWidth: Bool, lockRatio: Bool,
                             current: CGSize) -> CGSize {
        guard enteredPx.isFinite, enteredPx > 0 else { return current }
        var out = current
        if axisIsWidth {
            out.width = enteredPx
            if lockRatio, current.width > 0 {
                out.height = enteredPx * current.height / current.width
            }
        } else {
            out.height = enteredPx
            if lockRatio, current.height > 0 {
                out.width = enteredPx * current.width / current.height
            }
        }
        return out
    }

    /// Bound a requested target to the legal range, preserving its aspect when
    /// a cap forces scaling down (so a locked edit never comes back distorted).
    static func clamped(_ requested: CGSize, original: CGSize) -> CGSize {
        var s = requested
        // Ceiling: 4× the original on each axis, and the absolute side cap.
        let maxW = min(original.width * maxUpscaleFactor, maxSidePx)
        let maxH = min(original.height * maxUpscaleFactor, maxSidePx)
        let over = max(s.width / maxW, s.height / maxH)
        if over > 1 { s = CGSize(width: s.width / over, height: s.height / over) }
        // Floor per-axis (a degenerate 8px strip is still legal).
        s.width = max(minSidePx, s.width.rounded())
        s.height = max(minSidePx, s.height.rounded())
        return s
    }

    /// One stepper click's increment, in the unit's own display value
    /// (⌥-click multiplies by 10 at the call site).
    static func unitStep(_ unit: Unit) -> CGFloat {
        switch unit {
        case .pixels: return 10
        case .percent: return 1
        case .inches: return 0.1
        case .centimeters: return 0.1
        }
    }

    /// The uniform scale factors a target implies for geometry transforms.
    static func scaleFactors(from original: CGSize, to target: CGSize) -> (x: CGFloat, y: CGFloat) {
        (original.width > 0 ? target.width / original.width : 1,
         original.height > 0 ? target.height / original.height : 1)
    }
}
