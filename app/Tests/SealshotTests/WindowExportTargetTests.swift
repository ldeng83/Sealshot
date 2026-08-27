import XCTest
@testable import Sealshot

/// Which window "Export This Window…" writes when it is invoked from the
/// object context menu of a Live Capture scene.
final class WindowExportTargetTests: XCTestCase {

    private let red = SerializableColor(r: 1, g: 0, b: 0, a: 1)

    private func imageAnno(_ assetID: String) -> Annotation {
        Annotation(geometry: .image(rect: CGRect(x: 0, y: 0, width: 100, height: 80),
                                    assetID: assetID),
                   style: Style(strokeColor: red, strokeWidth: 1))
    }

    private func rectAnno() -> Annotation {
        Annotation(geometry: .rectangle(rect: CGRect(x: 0, y: 0, width: 10, height: 10)),
                   style: Style(strokeColor: red, strokeWidth: 1))
    }

    private func assets(_ ids: [String]) -> [String: Data] {
        Dictionary(uniqueKeysWithValues: ids.map { ($0, Data([0x89, 0x50])) })
    }

    func test_resolvesTheClickedWindowsAsset() {
        let a = imageAnno("win-a")
        XCTAssertEqual(
            EditorState.exportableWindowAssetID(hit: a.id, annotations: [a],
                                                imageAssets: assets(["win-a"]), isScene: true),
            "win-a")
    }

    func test_resolvesFromTheClickedObjectNotTheSelection() {
        // The whole reason this is a separate helper. `menu(for:)` retargets the
        // selection ONLY when the hit object isn't already selected, so
        // right-clicking a member of a multi-selection leaves
        // `selectedAnnotation` on the last-CLICKED window. Exporting via the
        // selection would then write a different window than the one under the
        // pointer.
        let a = imageAnno("win-a")   // imagine: the primary selection
        let b = imageAnno("win-b")   // imagine: the one actually right-clicked
        XCTAssertEqual(
            EditorState.exportableWindowAssetID(hit: b.id, annotations: [a, b],
                                                imageAssets: assets(["win-a", "win-b"]),
                                                isScene: true),
            "win-b")
    }

    func test_nilOutsideALiveCaptureScene() {
        let a = imageAnno("win-a")
        XCTAssertNil(
            EditorState.exportableWindowAssetID(hit: a.id, annotations: [a],
                                                imageAssets: assets(["win-a"]), isScene: false))
    }

    func test_nilForANonImageObject() {
        let r = rectAnno()
        XCTAssertNil(
            EditorState.exportableWindowAssetID(hit: r.id, annotations: [r],
                                                imageAssets: assets(["win-a"]), isScene: true))
    }

    func test_nilWhenTheAssetIsMissing() {
        // A layer whose PNG didn't survive — offering an export that silently
        // writes nothing is worse than not offering it.
        let a = imageAnno("win-a")
        XCTAssertNil(
            EditorState.exportableWindowAssetID(hit: a.id, annotations: [a],
                                                imageAssets: [:], isScene: true))
    }

    func test_nilWithNoHit() {
        let a = imageAnno("win-a")
        XCTAssertNil(
            EditorState.exportableWindowAssetID(hit: nil, annotations: [a],
                                                imageAssets: assets(["win-a"]), isScene: true))
    }
}
