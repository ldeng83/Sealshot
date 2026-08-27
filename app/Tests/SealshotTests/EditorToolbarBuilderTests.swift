import XCTest
import AppKit
@testable import Sealshot

@MainActor
final class EditorToolbarBuilderTests: XCTestCase {

    /// Collect the tool pills in left-to-right order from a built bar.
    private func pills(in view: NSView) -> [ActiveToolPillView] {
        var out: [ActiveToolPillView] = []
        let children = (view as? NSStackView)?.arrangedSubviews ?? view.subviews
        for child in children {
            if let pill = child as? ActiveToolPillView {
                out.append(pill)
            } else {
                out.append(contentsOf: pills(in: child))
            }
        }
        return out
    }

    private func labels(in view: NSView) -> [String] {
        pills(in: view).map { $0.accessibilityLabel() ?? "" }
    }

    func testEmptyMode_showsFullBarWithCanvasToolsDisabled() {
        let builder = EditorToolbarBuilder()
        let view = builder.makeToolbarView(empty: true)
        let byLabel = Dictionary(
            pills(in: view).map { ($0.accessibilityLabel() ?? "", $0) },
            uniquingKeysWith: { first, _ in first })

        // The full toolbar is present (not just the capture trio).
        for label in ["Info", "Find in Image", "New", "Capture", "Delayed capture", "Scrolling capture",
                      "Undo", "Redo", "Select", "Enhance",
            "Remove Background", "Smart Redact", "Export", "Copy All"] {
            XCTAssertNotNil(byLabel[label], "expected \(label) pill in empty mode")
        }

        // Active without a canvas: the + menu and the capture trio.
        XCTAssertEqual(byLabel["New"]?.isEnabled, true)
        XCTAssertEqual(byLabel["Capture"]?.isEnabled, true)
        XCTAssertEqual(byLabel["Delayed capture"]?.isEnabled, true)
        XCTAssertEqual(byLabel["Scrolling capture"]?.isEnabled, true)

        // Disabled until there's an open capture.
        for label in ["Info", "Find in Image", "Undo", "Redo", "Select", "Enhance", "Smart Redact",
                      "Export", "Copy All"] {
            XCTAssertEqual(byLabel[label]?.isEnabled, false, "\(label) should be disabled when empty")
        }
    }

    func testLoadedMode_barContainsUndoRedoToolsAndExports() {
        let builder = EditorToolbarBuilder()
        let view = builder.makeToolbarView(empty: false)
        // Line and Arrow are each their own standalone pill. Rectangle+Ellipse
        // remain collapsed into one grouped pill that fronts the last-used
        // sub-tool — normalize it to its default label so the assertion is
        // independent of stored preference.
        let normalized = labels(in: view)
            .map { label -> String in
                switch label {
                case "Ellipse": return "Rectangle"
                default: return label
                }
            }
        XCTAssertEqual(normalized, [
            "New",           // plus pill — New Canvas / New from Clipboard / Import
            "Capture",       // unified capture
            "Full screen capture",
            "Delayed capture",
            "Scrolling capture",
            "Live capture",
            "Record full screen",
            "Record selected area",
            "Undo",
            "Redo",
            "Select",
            "Hand",
            "Crop",
            "Pen",
            "Line",          // standalone Line pill
            "Line Arrow",    // arrow group's default (Line Arrow / Free Arrow)
            "Rectangle",     // grouped Rectangle/Ellipse pill
            "Text",
            "Step",
            "Blur",
            "Live Text",     // trails the drawing tools, grouped with Redact/Extract/Enhance
            "Smart Redact",
            // "AI Summary" is filtered above (availability-gated on Apple Intelligence).
            "Extract Structured Data",
            "Enhance",       // moved to the right of Extract Structured Data
            "Remove Background",
            "Find in Image", // icon-only search mode, immediately left of Info
            "Info",          // trailing toggle, just left of Export (relocated from far-left)
            "Export",
            "Copy All",
        ])
    }

    func testFindInImage_sitsDirectlyBeforeInfo_withShortcutTooltip() {
        let builder = EditorToolbarBuilder()
        guard let bar = builder.makeToolbarView(empty: false) as? NSStackView else {
            return XCTFail("expected the bar to be a stack view")
        }
        guard let searchIndex = bar.arrangedSubviews.firstIndex(where: {
            ($0 as? ActiveToolPillView)?.accessibilityLabel() == "Find in Image"
        }) else { return XCTFail("missing Find in Image pill") }

        let search = bar.arrangedSubviews[searchIndex] as? ActiveToolPillView
        let next = bar.arrangedSubviews[searchIndex + 1] as? ActiveToolPillView
        XCTAssertEqual(next?.accessibilityLabel(), "Info")
        XCTAssertEqual(search?.tooltipText, "Find in Image (⌘F)")

        builder.setImageTextSearchActive(true)
        XCTAssertEqual(search?.isActive, true)
        builder.setImageTextSearchActive(false)
        XCTAssertEqual(search?.isActive, false)
    }

    func testShapesAndArrowAreMergedPills_lineStandalone() {
        let builder = EditorToolbarBuilder()
        let view = builder.makeToolbarView(empty: false)
        // Exact type only — the delayed-capture pill is a GroupedToolPillView
        // subclass (DelayedCapturePill) but isn't a drawing tool group.
        let grouped = pills(in: view).filter { type(of: $0) == GroupedToolPillView.self }
        // Two grouped pills: Rectangle/Ellipse (shapes) and Line Arrow/Free
        // Arrow (arrow — added with the Free Arrow tool).
        XCTAssertEqual(grouped.count, 2, "expected shapes + arrow grouped pills")
        let groupedLabels = Set(grouped.map { $0.accessibilityLabel() ?? "" })
        XCTAssertTrue(groupedLabels.isSubset(of: ["Rectangle", "Ellipse", "Line Arrow", "Free Arrow"]))
        // Line is present as its own (non-grouped) pill.
        let allLabels = Set(labels(in: view))
        XCTAssertTrue(allLabels.contains("Line"))
    }

    func testEnhancePill_sitsDirectlyAfterExtractStructuredData_withClarityTooltip() {
        let builder = EditorToolbarBuilder()
        guard let bar = builder.makeToolbarView(empty: false) as? NSStackView else {
            return XCTFail("expected the bar to be a stack view")
        }

        let ordered = bar.arrangedSubviews.compactMap { $0 as? ActiveToolPillView }
        guard let extractIdx = bar.arrangedSubviews.firstIndex(where: {
            ($0 as? ActiveToolPillView)?.accessibilityLabel() == "Extract Structured Data"
        }) else { return XCTFail("missing Extract Structured Data pill") }

        // Enhance now sits at the end of the Live Text / Smart Redact / Extract
        // group, directly after Extract Structured Data (no spacer between them).
        XCTAssertEqual(
            (bar.arrangedSubviews[extractIdx + 1] as? ActiveToolPillView)?.accessibilityLabel(),
            "Enhance"
        )

        let enhance = ordered.first { $0.accessibilityLabel() == "Enhance" }
        XCTAssertEqual(enhance?.tooltipText, "Enhance clarity for low resolution")
    }

    func testUndoRedoButtons_reflectEnabledState() {
        let builder = EditorToolbarBuilder()
        let view = builder.makeToolbarView(empty: false)

        let byLabel = Dictionary(
            uniqueKeysWithValues: pills(in: view).map { ($0.accessibilityLabel() ?? "", $0) }
        )
        let undo = byLabel["Undo"]
        let redo = byLabel["Redo"]

        // Default: both disabled (empty undo/redo stacks).
        XCTAssertEqual(undo?.isEnabled, false)
        XCTAssertEqual(redo?.isEnabled, false)

        builder.setUndoEnabled(true)
        builder.setRedoEnabled(false)
        XCTAssertEqual(undo?.isEnabled, true)
        XCTAssertEqual(redo?.isEnabled, false)

        builder.setRedoEnabled(true)
        XCTAssertEqual(redo?.isEnabled, true)
    }

    func testPlusMenu_mirrorsFileMenu() {
        let builder = EditorToolbarBuilder()
        let menu = builder.makePlusMenu(clipboardHasImage: true, hasCanvas: true)

        XCTAssertEqual(menu.items.map(\.title),
                       ["New Canvas", "New from Clipboard", "", "Import to Library…", "", "Insert Image on Canvas…"])
        XCTAssertTrue(menu.items[2].isSeparatorItem)
        XCTAssertTrue(menu.items[4].isSeparatorItem)

        // Display-only key equivalents mirror the File menu (⌘N / ⇧⌘N / ⌘O).
        XCTAssertEqual(menu.items[0].keyEquivalent, "n")
        XCTAssertEqual(menu.items[0].keyEquivalentModifierMask, [.command])
        XCTAssertEqual(menu.items[1].keyEquivalent, "n")
        XCTAssertEqual(menu.items[1].keyEquivalentModifierMask, [.command, .shift])
        XCTAssertEqual(menu.items[3].keyEquivalent, "o")
        XCTAssertEqual(menu.items[3].keyEquivalentModifierMask, [.command])

        XCTAssertTrue(menu.items[1].isEnabled)
    }

    func testPlusMenu_disablesClipboardItemWithoutImage() {
        let builder = EditorToolbarBuilder()
        let menu = builder.makePlusMenu(clipboardHasImage: false)

        XCTAssertFalse(menu.items[1].isEnabled, "New from Clipboard should grey out")
        XCTAssertTrue(menu.items[0].isEnabled)
        XCTAssertTrue(menu.items[3].isEnabled)
    }

    func testPlusMenu_insertImageDisabledWithoutCanvas() {
        let builder = EditorToolbarBuilder()
        let without = builder.makePlusMenu(clipboardHasImage: true, hasCanvas: false)
        XCTAssertFalse(without.items[5].isEnabled)
        let with = builder.makePlusMenu(clipboardHasImage: true, hasCanvas: true)
        XCTAssertTrue(with.items[5].isEnabled)
    }

    // MARK: Narrow-width folding

    /// Folding replaces a run of pills with ONE stand-in — the bar gets
    /// narrower, and the pills that went away are gone rather than clipped.
    func testFolding_replacesEachClusterWithASinglePill() {
        let builder = EditorToolbarBuilder()
        let folded = builder.makeToolbarView(empty: false,
                                             folded: [.record, .ai, .trailing])
        let present = Set(labels(in: folded))

        XCTAssertTrue(present.contains("Record"))
        XCTAssertTrue(present.contains("AI tools"))
        XCTAssertTrue(present.contains("More"))
        for gone in ["Record Screen", "Smart Redact", "Enhance", "Remove Background",
                     "Extract Structured Data", "Find in Image", "Copy All"] {
            XCTAssertFalse(present.contains(gone), "\(gone) should have folded away")
        }
        // Export stays out: it is the one action that gets work OUT of the app.
        XCTAssertTrue(present.contains("Export"))
    }

    /// Folded Capture keeps its click on Smart Capture — the primary action
    /// must never move — and the four modes ride its chevron menu.
    func testFoldedCapture_keepsSmartCaptureOnTheClick() {
        let builder = EditorToolbarBuilder()
        var unified = 0
        builder.onCaptureUnified = { unified += 1 }
        let view = builder.makeToolbarView(empty: false, folded: [.capture])
        let present = Set(labels(in: view))
        for gone in ["Scrolling capture", "Delayed capture", "Live Capture"] {
            XCTAssertFalse(present.contains(gone))
        }
        guard let capture = pills(in: view)
            .first(where: { $0.accessibilityLabel() == "Capture" }) as? GroupedToolPillView
        else { return XCTFail("folded Capture should be a grouped (chevron) pill") }
        capture.onActivateCurrent?()
        XCTAssertEqual(unified, 1)
    }

    /// A tool inside a folded group still selects, and the group pill it now
    /// lives in is what highlights. A static layout lookup would highlight the
    /// Arrow pill, which isn't on the bar at this width.
    func testFoldedDrawingTools_selectionHighlightsTheGroupOnScreen() {
        let builder = EditorToolbarBuilder()
        let view = builder.makeToolbarView(empty: false, folded: [.draw])
        builder.setSelectedTool(.ellipse)

        let active = pills(in: view).filter(\.isActive)
        XCTAssertEqual(active.count, 1, "exactly one pill highlights")
        XCTAssertEqual(active.first?.accessibilityLabel(), "Ellipse",
                       "the Draw pill fronts the selected sub-tool")
        XCTAssertTrue(active.first is GroupedToolPillView)
    }

    /// Every tool remains reachable at the narrowest width — folding hides
    /// pills, never capabilities.
    func testFullyFolded_stillHostsEveryDrawingTool() {
        let all = Set(EditorToolbarFit.ClusterID.allCases)
        let layout = EditorToolbarBuilder.makeToolLayout(folded: all)
        var reachable: Set<EditorTool> = []
        for slot in layout {
            switch slot {
            case let .single(tool, _, _): reachable.insert(tool)
            case let .group(group): reachable.formUnion(group.tools)
            }
        }
        let expanded = EditorToolbarBuilder.makeToolLayout(folded: [])
        for slot in expanded {
            switch slot {
            case let .single(tool, _, _):
                XCTAssertTrue(reachable.contains(tool), "\(tool) unreachable when folded")
            case let .group(group):
                for tool in group.tools {
                    XCTAssertTrue(reachable.contains(tool), "\(tool) unreachable when folded")
                }
            }
        }
    }
}
