import AppKit
import ApplicationServices

/// Scrolls by SETTING the scroll position through the Accessibility API —
/// no wheel events, no pointer involvement. Immune to scroll-snap sections,
/// scroll-hijacking JS, and wheel-swallowing inner widgets, because nothing
/// ever enters the wheel pipeline: the scroll bar's AXValue (0…1) is written
/// directly. (Video evidence: Shottr parks its cursor on the window resize
/// corner and advances the page in big smooth position-set strides — this
/// mechanism.) Also yields exact end-of-content: value ≥ ~1.
///
/// Requires the Accessibility grant — the same one that gates auto-scroll,
/// so no new permission. Direct build only in practice (the sandbox guard
/// upstream already returns manual for MAS).
final class AXScrollDriver: ScrollInjecting, ScrollPositionReporting {
    private let scrollArea: AXUIElement
    private let scrollBar: AXUIElement
    private var lastSetValue: Double?
    /// True once a position write came back kAXErrorAPIDisabled — the
    /// Accessibility grant was pulled after this driver resolved. The
    /// controller reads it to surface a lost-permission prompt instead of
    /// silently stalling. (Backstop for a revocation that lands mid-session,
    /// after the event tap was already created.)
    private(set) var writeDeauthorized = false

    private init(scrollArea: AXUIElement, scrollBar: AXUIElement) {
        self.scrollArea = scrollArea
        self.scrollBar = scrollBar
    }

    /// Resolve the scroll area under `appKitPoint` (global bottom-left
    /// coords): element at position, then climb to the nearest ancestor
    /// AXScrollArea that has a vertical scroll bar. ONE immediate attempt —
    /// native apps expose their tree synchronously and resolve on the first
    /// try; Chromium never resolves at all (no standard AXScrollArea for web
    /// content), and the wake-the-lazy-tree poll this used to run only added
    /// a fixed ~1.6s pause before EVERY browser auto-scroll for a
    /// predetermined fallback. Nil → caller uses wheel injection.
    static func make(atGlobal appKitPoint: CGPoint) async -> AXScrollDriver? {
        if let driver = resolve(atGlobal: appKitPoint) { return driver }
        ScrollDiag.note("ax-scroll: unresolved — falling back to wheel")
        return nil
    }

    private static func resolve(atGlobal appKitPoint: CGPoint) -> AXScrollDriver? {
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        let cg = CGPoint(x: appKitPoint.x, y: primaryH - appKitPoint.y)
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
                AXUIElementCreateSystemWide(), Float(cg.x), Float(cg.y), &element) == .success,
              var current = element else { return nil }
        for _ in 0..<25 {
            if roleOf(current) == kAXScrollAreaRole,
               let bar: AXUIElement = attr(current, kAXVerticalScrollBarAttribute) {
                let driver = AXScrollDriver(scrollArea: current, scrollBar: bar)
                guard driver.currentValue() != nil, driver.scrollableRangePoints() != nil else {
                    return nil
                }
                return driver
            }
            guard let parent: AXUIElement = attr(current, kAXParentAttribute) else { break }
            current = parent
        }
        return nil
    }

    // No pointer involvement — the cursor stays wherever it is.
    func parkPointer(atGlobal point: CGPoint) {}

    func scrollContentDown(points: Int) async {
        guard let range = scrollableRangePoints(), range > 1 else { return }
        let v0 = currentValue() ?? lastSetValue ?? 0
        let v1 = min(1.0, v0 + Double(points) / range)
        let err = AXUIElementSetAttributeValue(scrollBar, kAXValueAttribute as CFString, v1 as CFTypeRef)
        // kAXErrorAPIDisabled is the one unambiguous "not trusted" verdict;
        // other failures (busy app, transient) must NOT be read as revocation.
        if err == .apiDisabled { writeDeauthorized = true }
        lastSetValue = v1
    }

    var isAtBottom: Bool {
        guard let v = currentValue() else { return false }
        // Remaining distance under ~2pt counts as bottom.
        if let range = scrollableRangePoints() { return (1 - v) * range < 2 }
        return v >= 0.999
    }

    // MARK: - AX plumbing

    private func currentValue() -> Double? {
        var out: CFTypeRef?
        guard AXUIElementCopyAttributeValue(scrollBar, kAXValueAttribute as CFString, &out) == .success
        else { return nil }
        return (out as? NSNumber)?.doubleValue
    }

    /// Scrollable distance in points: content child height − viewport height.
    /// Re-read every step — lazy-loading pages grow while we scroll.
    private func scrollableRangePoints() -> Double? {
        guard let areaSize = Self.sizeOf(scrollArea) else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyAttributeValue(scrollArea, kAXChildrenAttribute as CFString, &out) == .success,
              let children = out as? [AXUIElement] else { return nil }
        let contentH = children.compactMap { Self.sizeOf($0)?.height }.max() ?? 0
        let range = Double(contentH - areaSize.height)
        return range > 1 ? range : nil
    }

    private static func sizeOf(_ element: AXUIElement) -> CGSize? {
        var out: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &out) == .success,
              let value = out, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    private static func roleOf(_ element: AXUIElement) -> String? {
        var out: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &out) == .success
        else { return nil }
        return out as? String
    }

    private static func attr(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        var out: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &out) == .success,
              let value = out, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}
