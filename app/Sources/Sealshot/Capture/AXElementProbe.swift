import AppKit
import ApplicationServices
import os.log

private let probeLog = OSLog(subsystem: "com.seal-shot.sealshot", category: "ax-probe")

/// Element frames under a point from the target app's ACCESSIBILITY tree —
/// the precision path for capture hover boundaries. This is how UIA-class
/// tools (Snagit on Windows, Snipaste) snap to buttons/cards/panels exactly:
/// ask the toolkit, don't guess from pixels. Image-based detection
/// (`BoundaryDetector`) remains the fallback for apps with poor AX trees and
/// for sessions without the Accessibility grant.
///
/// Pure & synchronous (AX calls are XPC to the target app, ~ms but can stall
/// on busy apps) — callers run it off the main thread and treat results as
/// advisory.
enum AXElementProbe {

    /// Smallest element worth offering as a hover candidate — users want
    /// decent-sized objects (cards, panels, images); tiny buttons are noise
    /// a quick drag covers better. Shared with the image-based detector's
    /// candidate filtering.
    static let minElementSize = CGSize(width: 120, height: 80)

    struct ProbeResult: Equatable {
        enum Mode: Equatable {
            /// Normal app: element/container frames, innermost first.
            case elements
            /// Browser, cursor in web content: rects = [the content area].
            case browserContent
            /// Browser, cursor in its chrome (tabs/address/bookmarks):
            /// no sub-rects — the whole window is the only candidate.
            case browserChrome
            /// No grant, no tree, or no hit — image detection carries.
            case none
        }
        let mode: Mode
        /// Global top-left/CG coordinates.
        let rects: [CGRect]
        static let none = ProbeResult(mode: .none, rects: [])
    }

    /// Browsers get exactly two hover targets: the page content area (cursor
    /// in the body) or the whole window (cursor in the chrome). Web content
    /// identifies itself by role, so the body rule is browser-agnostic; the
    /// chrome rule needs to know the app IS a browser.
    static func isBrowser(_ bundleID: String?) -> Bool {
        BrowserIdentifier.isBrowser(bundleID)
    }

    /// Chromium-family apps (Chrome, Edge, Brave, Electron) build their
    /// accessibility tree LAZILY — until an assistive client announces
    /// itself, hit-tests return only a stub and no AXWebArea ever appears.
    /// Setting AXManualAccessibility forces the tree on (Chromium honors
    /// it; other apps ignore the unknown attribute harmlessly). Once per
    /// pid; the tree takes a beat to build, so the caller retries once.
    private static let forcedPIDs = NSMutableSet()
    private static let forcedLock = NSLock()

    private static func forceTreeOnce(app: AXUIElement, pid: pid_t) -> Bool {
        forcedLock.lock()
        defer { forcedLock.unlock() }
        guard !forcedPIDs.contains(pid) else { return false }
        forcedPIDs.add(pid)
        let manual = AXUIElementSetAttributeValue(
            app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        // Newer Chromium builds ignore AXManualAccessibility; the AppKit-wide
        // AXEnhancedUserInterface announcement (what VoiceOver sets) still
        // flips the render tree on.
        let enhanced = AXUIElementSetAttributeValue(
            app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        os_log("forceTree pid=%d: AXManualAccessibility=%d AXEnhancedUserInterface=%d",
               log: probeLog, type: .default, pid, manual.rawValue, enhanced.rawValue)
        return true
    }

    /// Hit-test the app's accessibility tree under `point` (global top-left
    /// coordinates). Empty/.none without the Accessibility grant or when the
    /// app exposes no usable tree.
    static func probe(at point: CGPoint, pid: pid_t, bundleID: String?) -> ProbeResult {
        // The gate/nil/forceTree logs stay at .default (rare, one-line, and
        // exactly what's needed to diagnose the next silent degradation —
        // log show drops .debug/.info).
        let scrollOK = AccessibilityPermission.canAutoScroll
        let trusted = AXIsProcessTrusted()
        guard scrollOK || trusted else {
            os_log("probe GATE: not trusted (canAutoScroll=%d AXTrusted=%d) pid=%d %{public}@",
                   log: probeLog, type: .default, scrollOK ? 1 : 0, trusted ? 1 : 0,
                   pid, bundleID ?? "?")
            return .none
        }
        let app = AXUIElementCreateApplication(pid)
        guard var chain = ancestorChain(at: point, app: app) else {
            os_log("probe %{public}@: ancestorChain NIL at (%.0f,%.0f) pid=%d",
                   log: probeLog, type: .default, bundleID ?? "?", point.x, point.y, pid)
            return .none
        }

        // Inside web content → the content area is the one candidate, in any
        // browser (and any app embedding a web view).
        func webArea(
            in chain: [(role: String?, frame: CGRect?, windowFrame: CGRect?)]
        ) -> CGRect? {
            guard let frame = chain.first(where: { $0.role == "AXWebArea" })?.frame,
                  frame.width >= minElementSize.width,
                  frame.height >= minElementSize.height else { return nil }
            return frame
        }

        if webArea(in: chain) == nil, isBrowser(bundleID),
           forceTreeOnce(app: app, pid: pid) {
            // Lazy Chromium tree — force it on, then poll while it builds
            // (a heavy page can take several hundred ms). Only the probe
            // that performed the force pays this wait; later probes see the
            // built tree directly in ancestorChain.
            for _ in 0..<5 {
                usleep(200_000)
                if let rebuilt = ancestorChain(at: point, app: app) {
                    chain = rebuilt
                    if webArea(in: chain) != nil { break }
                }
            }
        }

        let roles = chain.map { $0.role ?? "?" }.joined(separator: " < ")
        if let contentArea = webArea(in: chain) {
            os_log("probe %{public}@: browserContent [%{public}@]",
                   log: probeLog, type: .debug, bundleID ?? "?", roles)
            return ProbeResult(mode: .browserContent, rects: [contentArea])
        }
        // Browser chrome (tabs / address / bookmarks) → whole window only.
        if isBrowser(bundleID) {
            os_log("probe %{public}@: browserChrome [%{public}@]",
                   log: probeLog, type: .debug, bundleID ?? "?", roles)
            return ProbeResult(mode: .browserChrome, rects: [])
        }

        // The hit element's window frame bounds the "too big to be useful"
        // filter: full-window groups/scroll areas duplicate the window
        // candidate and would clutter scroll-cycling.
        let windowFrame = chain.last?.windowFrame
        var rects: [CGRect] = []
        for entry in chain {
            guard let frame = entry.frame,
                  frame.width >= minElementSize.width,
                  frame.height >= minElementSize.height,
                  !isNearWindowSized(frame, windowFrame: windowFrame),
                  !rects.contains(where: { approximatelyEqual($0, frame) }) else { continue }
            rects.append(frame)
        }
        os_log("probe %{public}@: %d elements [%{public}@]",
               log: probeLog, type: .debug, bundleID ?? "?", rects.count, roles)
        return ProbeResult(mode: .elements, rects: rects)
    }

    /// One node of the ancestor walk: its role and frame.
    struct ChainEntry: Equatable {
        let role: String?
        let frame: CGRect?
    }

    /// Walk parents from `start`, innermost first, collecting (role, frame).
    /// Pure (no AX) so the stop rules are unit-testable. Stops when:
    ///  - `maxDepth` nodes have been collected (pathological-tree guard),
    ///  - there is no parent,
    ///  - the parent is a boundary (window / application), OR
    ///  - the current node is `AXWebArea` — web content nests arbitrarily deep
    ///    below it, and nothing above it changes our decision, so we stop there
    ///    to keep the walk bounded. (This is the fix for browsers highlighting
    ///    the whole window: a low cap used to truncate before AXWebArea was
    ///    reached on deeply-nested pages.)
    static func climb<E>(
        from start: E,
        maxDepth: Int,
        role: (E) -> String?,
        frame: (E) -> CGRect?,
        parent: (E) -> E?,
        isBoundary: (E) -> Bool
    ) -> [ChainEntry] {
        var out: [ChainEntry] = []
        var node = start
        for _ in 0..<maxDepth {
            let r = role(node)
            out.append(ChainEntry(role: r, frame: frame(node)))
            if r == "AXWebArea" { break }
            guard let p = parent(node), !isBoundary(p) else { break }
            node = p
        }
        return out
    }

    /// Deep enough to clear realistic web-content nesting (the old cap of 16
    /// truncated before AXWebArea on typical pages); the AXWebArea early-stop
    /// keeps the walk cheap in the common case, and native apps reach their
    /// window parent and stop long before this.
    private static let maxChainDepth = 60

    /// The element under `point` and its ancestors up to (excluding) the
    /// window: role + frame each, innermost first. The window frame rides
    /// along on the last entry.
    private static func ancestorChain(
        at point: CGPoint, app: AXUIElement
    ) -> [(role: String?, frame: CGRect?, windowFrame: CGRect?)]? {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success,
              let hitElement = hit else { return nil }
        let windowFrame = windowFrame(of: hitElement)
        let entries = climb(
            from: hitElement,
            maxDepth: maxChainDepth,
            role: { role(of: $0) },
            frame: { frame(of: $0) },
            parent: { copyParent(of: $0) },
            isBoundary: { role(of: $0) == kAXWindowRole as String
                || role(of: $0) == kAXApplicationRole as String }
        )
        return entries.map { (role: $0.role, frame: $0.frame, windowFrame: windowFrame) }
    }

    // MARK: - AX plumbing

    private static func copyParent(of element: AXUIElement) -> AXUIElement? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func role(of element: AXUIElement) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var posValue: AnyObject?
        var sizeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let posValue, CFGetTypeID(posValue) == AXValueGetTypeID(),
              let sizeValue, CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    private static func windowFrame(of element: AXUIElement) -> CGRect? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return frame(of: (value as! AXUIElement))
    }

    private static func isNearWindowSized(_ rect: CGRect, windowFrame: CGRect?) -> Bool {
        guard let windowFrame, windowFrame.width > 0, windowFrame.height > 0 else { return false }
        let coverage = (rect.width * rect.height) / (windowFrame.width * windowFrame.height)
        return coverage > 0.9
    }

    private static func approximatelyEqual(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 3 && abs(a.minY - b.minY) < 3
            && abs(a.maxX - b.maxX) < 3 && abs(a.maxY - b.maxY) < 3
    }
}
