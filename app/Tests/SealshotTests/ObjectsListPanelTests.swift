import XCTest
import AppKit
import CoreGraphics
@testable import Sealshot

@MainActor
final class ObjectsListPanelTests: XCTestCase {

    private func makeImage(width: Int = 100, height: Int = 100) -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    private func arrow() -> Annotation {
        Annotation(geometry: .arrow(start: .zero, end: CGPoint(x: 10, y: 10)),
                   style: Style(strokeColor: SerializableColor(r: 1, g: 0, b: 0, a: 1), strokeWidth: 3))
    }

    // MARK: id-targeted style editing

    func test_updateStyle_byId_editsTargetNotPrimary() {
        let state = EditorState(sourceImage: makeImage(), sourceURL: nil)
        let a = arrow(), b = arrow()
        state.annotations = [a, b]
        state.selectedAnnotationID = a.id          // primary is `a`

        state.updateStyle(id: b.id) { $0.opacity = 0.4 }

        XCTAssertEqual(state.annotations[1].style.opacity, 0.4, accuracy: 0.0001)
        XCTAssertEqual(state.annotations[0].style.opacity, 1.0, accuracy: 0.0001)  // primary untouched
        XCTAssertTrue(state.isDirty)
    }

    func test_updateStyle_byId_unknownId_isNoOp() {
        let state = EditorState(sourceImage: makeImage(), sourceURL: nil)
        state.annotations = [arrow()]
        state.updateStyle(id: UUID()) { $0.opacity = 0.1 }  // must not crash
        XCTAssertEqual(state.annotations[0].style.opacity, 1.0, accuracy: 0.0001)
    }

    func test_updateSelectedStyle_stillEditsPrimary() {
        let state = EditorState(sourceImage: makeImage(), sourceURL: nil)
        let a = arrow()
        state.annotations = [a]
        state.selectedAnnotationID = a.id
        state.updateSelectedStyle { $0.strokeWidth = 8 }
        XCTAssertEqual(state.annotations[0].style.strokeWidth, 8)
    }

    func test_updateBadgeRadius_byId_setsTargetRadius() {
        let state = EditorState(sourceImage: makeImage(), sourceURL: nil)
        let badge = Annotation(geometry: .badge(center: CGPoint(x: 5, y: 5), radius: 16),
                               style: Style(strokeColor: SerializableColor(r: 1, g: 0, b: 0, a: 1), strokeWidth: 1))
        state.annotations = [badge]
        state.updateBadgeRadius(id: badge.id, 30)
        if case let .badge(_, r) = state.annotations[0].geometry {
            XCTAssertEqual(r, 30)
        } else { XCTFail("expected badge") }
    }

    func test_updateTextRuns_byId_mutatesRuns() {
        let state = EditorState(sourceImage: makeImage(), sourceURL: nil)
        let run = TextRun(text: "hi", color: SerializableColor(r: 0, g: 0, b: 0, a: 1), fontSize: 18, isBold: false)
        let text = Annotation(geometry: .text(rect: CGRect(x: 0, y: 0, width: 80, height: 24), runs: [run]),
                              style: Style(strokeColor: SerializableColor(r: 0, g: 0, b: 0, a: 1), strokeWidth: 1))
        state.annotations = [text]
        state.updateTextRuns(id: text.id) { runs in for i in runs.indices { runs[i].isBold = true } }
        if case let .text(_, runs) = state.annotations[0].geometry {
            XCTAssertTrue(runs[0].isBold)
        } else { XCTFail("expected text") }
    }

    // MARK: ordering

    func test_objectListOrder_isFrontMostFirst() {
        let back = arrow(), mid = arrow(), front = arrow()
        let ordered = objectListOrder([back, mid, front])   // annotations is back-to-front
        XCTAssertEqual(ordered.map { $0.id }, [front.id, mid.id, back.id])
    }

    // MARK: row titles

    func test_objectRowDescriptor_titlePerGeometry() {
        func title(_ g: Geometry) -> String {
            ObjectRowDescriptor.title(for: Annotation(geometry: g,
                style: Style(strokeColor: SerializableColor(r: 0, g: 0, b: 0, a: 1), strokeWidth: 1)))
        }
        XCTAssertEqual(title(.arrow(start: .zero, end: .zero)), "Line Arrow")   // renamed when Free Arrow shipped
        XCTAssertEqual(title(.rectangle(rect: .zero)), "Rectangle")
        XCTAssertEqual(title(.text(rect: .zero, runs: [])), "Text")
        XCTAssertEqual(title(.ellipse(rect: .zero)), "Ellipse")
        XCTAssertEqual(title(.line(start: .zero, end: .zero)), "Line")
        XCTAssertEqual(title(.badge(center: .zero, radius: 1)), "Step")
        XCTAssertEqual(title(.pen(points: [])), "Pen")
    }

    // MARK: focus (objects-list row click / expand → highlight)

    func test_focusObject_inMultiSelection_setsPrimaryKeepsSet() {
        let state = EditorState(sourceImage: makeImage(), sourceURL: nil)
        let a = arrow(), b = arrow()
        state.annotations = [a, b]
        state.setSelection([a.id, b.id], primary: a.id)
        state.focusObject(b.id)
        XCTAssertEqual(state.primarySelectionID, b.id)
        XCTAssertEqual(state.selectedAnnotationIDs, [a.id, b.id])  // set unchanged
    }

    func test_focusObject_notSelected_addsAndMakesPrimary() {
        let state = EditorState(sourceImage: makeImage(), sourceURL: nil)
        let a = arrow(), b = arrow(), c = arrow()
        state.annotations = [a, b, c]
        state.setSelection([a.id, b.id], primary: a.id)
        state.focusObject(c.id)
        XCTAssertTrue(state.selectedAnnotationIDs.contains(c.id))
        XCTAssertEqual(state.primarySelectionID, c.id)
    }

    // MARK: style-edit guard (keeps the live slider alive mid-drag)

    func test_styleEdit_beginEnd_togglesFlagAndBumpsRefreshToken() {
        let state = EditorState(sourceImage: makeImage(), sourceURL: nil)
        XCTAssertFalse(state.styleEditingInProgress)
        let token = state.sidebarRefreshToken
        state.beginStyleEdit()
        XCTAssertTrue(state.styleEditingInProgress)
        state.endStyleEdit()
        XCTAssertFalse(state.styleEditingInProgress)
        XCTAssertEqual(state.sidebarRefreshToken, token + 1)
    }

    // MARK: expansion state

    func test_toggleExpanded_addsThenRemoves() {
        let state = EditorState(sourceImage: makeImage(), sourceURL: nil)
        let id = UUID()
        state.toggleExpanded(id)
        XCTAssertTrue(state.expandedObjectIDs.contains(id))
        state.toggleExpanded(id)
        XCTAssertFalse(state.expandedObjectIDs.contains(id))
    }

    // MARK: Select-tool neutral panel (no annotations)

    private func textFieldStrings(in view: NSView) -> [String] {
        var out: [String] = []
        if let tf = view as? NSTextField { out.append(tf.stringValue) }
        for sub in view.subviews { out.append(contentsOf: textFieldStrings(in: sub)) }
        return out
    }

    private func contains<T: NSView>(_ type: T.Type, in view: NSView) -> Bool {
        if view is T { return true }
        return view.subviews.contains { contains(type, in: $0) }
    }

    func test_selectToolPanel_showsOnlyNoObjectSelected() {
        let state = EditorState(sourceImage: makeImage(), sourceURL: nil)
        let panel = EditorToolPropertiesViews.make(
            for: .select, state: state,
            onCommitCrop: {}, onCopySelectedText: {}, onCopyAllText: {}
        )

        let strings = textFieldStrings(in: panel)
        XCTAssertTrue(strings.contains("No object selected."))
        XCTAssertFalse(strings.contains("No options for this tool."))
        // The old placeholder controls (disabled "Snap to Object" switch and
        // "Background Fill" segmented control) must be gone.
        XCTAssertFalse(contains(NSSwitch.self, in: panel))
        XCTAssertFalse(contains(NSSegmentedControl.self, in: panel))
    }
}
