import AppKit
import XCTest
@testable import Sealshot

/// Every drag source must opt out of modifier-key filtering.
///
/// macOS reserves ⌃ during a drag to mean "make a link" and filters the
/// source's operation mask down to `.link` at the drop. The out-of-app masks
/// here are deliberately `.copy` only (offering `.link` made Finder resolve
/// dropped captures as broken ~1KB aliases), so `.copy ∩ .link = ∅`: a ⌃-drop
/// resolved to no operation at all and Finder bounced the drag back. ⌃ is
/// Sealshot's hide-the-window peek key, held through the drop by design — the
/// drag hint itself tells the user to press it.
@MainActor
final class DragModifierTests: XCTestCase {
    /// A stand-in NSDraggingSession: the real one cannot be constructed
    /// outside a live drag, and every source under test ignores the parameter.
    /// Punned through an opaque pointer because unsafeDowncast type-checks at
    /// runtime (traps) and the compiler rejects unsafeBitCast between the two
    /// class types outright. Held as a property so the punned object outlives
    /// every use.
    private let sessionStandIn = NSObject()
    private func session() -> NSDraggingSession {
        Unmanaged<NSDraggingSession>.fromOpaque(
            Unmanaged.passUnretained(sessionStandIn).toOpaque()
        ).takeUnretainedValue()
    }

    private func stripTile() -> RecentThumbnailView {
        RecentThumbnailView(fileURL: URL(fileURLWithPath: "/tmp/a.seal"),
                            image: NSImage(size: NSSize(width: 8, height: 8)),
                            displayName: "a", mode: .recent, thumbHeight: 64,
                            thumbAspect: 4 / 3,
                            frame: NSRect(x: 0, y: 0, width: 90, height: 80))
    }

    func testStripTile_ignoresModifierKeys() {
        XCTAssertTrue(stripTile().ignoreModifierKeys(for: session()))
    }

    func testLibraryDragSource_ignoresModifierKeys() {
        XCTAssertTrue(LibraryDragSource(window: nil).ignoreModifierKeys(for: session()))
    }

    func testFloatingTile_ignoresModifierKeys() {
        XCTAssertTrue(FloatingCaptureThumbnailView().ignoreModifierKeys(for: session()))
    }

    /// The masks the opt-out protects: out-of-app stays `.copy` only — that is
    /// the alias fix — and must never quietly grow `.link` as an alternative
    /// way to stop the bounce.
    func testOutOfAppMasks_stayCopyOnly() {
        let s = session()
        XCTAssertEqual(stripTile()
            .draggingSession(s, sourceOperationMaskFor: .outsideApplication), .copy)
        XCTAssertEqual(LibraryDragSource(window: nil)
            .draggingSession(s, sourceOperationMaskFor: .outsideApplication), .copy)
        XCTAssertEqual(FloatingCaptureThumbnailView()
            .draggingSession(s, sourceOperationMaskFor: .outsideApplication), .copy)
    }
}
