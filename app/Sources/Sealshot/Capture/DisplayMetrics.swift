import AppKit

/// Pure display-resolution helpers for the selection overlay's readout.
enum DisplayMetrics {
    /// Pixels-per-inch for a display, from its pixel width and physical
    /// width in millimetres. Returns 0 when the physical size is unknown.
    static func ppi(pixelWidth: Int, physicalWidthMM: Double) -> Double {
        guard physicalWidthMM > 0 else { return 0 }
        let widthInches = physicalWidthMM / 25.4
        return Double(pixelWidth) / widthInches
    }

    /// A capture is "low resolution" when the display is non-Retina
    /// (scale < 2) or its physical pixel density is below `lowPPIThreshold`.
    static let lowPPIThreshold: Double = 144

    static func isLowResolution(pointPixelScale: CGFloat, ppi: Double) -> Bool {
        pointPixelScale < 2 || (ppi > 0 && ppi < lowPPIThreshold)
    }

    /// Non-pure convenience: resolve a screen's PPI from its device
    /// description + physical size. Falls back to 0 when unavailable.
    static func ppi(of screen: NSScreen) -> Double {
        guard
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return 0 }
        let displayID = CGDirectDisplayID(number.uint32Value)
        let mm = CGDisplayScreenSize(displayID)            // physical size, millimetres
        let pixelWidth = Int((screen.frame.width * screen.backingScaleFactor).rounded())
        return ppi(pixelWidth: pixelWidth, physicalWidthMM: Double(mm.width))
    }
}
