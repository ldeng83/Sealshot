import XCTest
@testable import Sealshot

@MainActor
final class ExportMenuStateTests: XCTestCase {
    private func src(_ name: String, isVideo: Bool = false) -> SharePackageSource {
        SharePackageSource(url: URL(fileURLWithPath: "/tmp/\(name).seal"), displayName: name, isVideo: isVideo)
    }

    func testUpdateSetsFlagsAndOwnerAndResolvesLazily() {
        let state = ExportMenuState()
        XCTAssertTrue(state.isEmpty)
        var resolved = 0
        state.update(isEmpty: false, hasVideo: true, owner: .library,
                     provider: { resolved += 1; return [self.src("a", isVideo: true)] })
        XCTAssertFalse(state.isEmpty)
        XCTAssertTrue(state.hasVideo)
        XCTAssertEqual(state.owner, .library)
        XCTAssertEqual(resolved, 0, "provider must not run until a command fires")
        XCTAssertEqual(state.resolveSources().count, 1)
        XCTAssertEqual(resolved, 1)
    }

    func testClearOnlyWhenOwnerMatches() {
        let state = ExportMenuState()
        state.update(isEmpty: false, hasVideo: false, owner: .library,
                     provider: { [self.src("a")] })
        state.clear(owner: .editorStrip)        // different owner → no-op
        XCTAssertFalse(state.isEmpty)
        XCTAssertEqual(state.resolveSources().count, 1)
        state.clear(owner: .library)            // owner matches → cleared
        XCTAssertTrue(state.isEmpty)
        XCTAssertFalse(state.hasVideo)
        XCTAssertTrue(state.resolveSources().isEmpty)
        XCTAssertNil(state.owner)
    }

    func testNewOwnerReplacesPreviousSelection() {
        let state = ExportMenuState()
        state.update(isEmpty: false, hasVideo: false, owner: .library,
                     provider: { [self.src("a")] })
        state.update(isEmpty: false, hasVideo: false, owner: .editorStrip,
                     provider: { [self.src("b"), self.src("c")] })
        XCTAssertEqual(state.owner, .editorStrip)
        XCTAssertEqual(state.resolveSources().count, 2)
    }
}
