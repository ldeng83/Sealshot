import XCTest
@testable import Sealshot

/// The Library auto-scrolls only on an explicit reveal ("Show in Library") or
/// keyboard navigation — a plain mouse selection must NOT yank the grid around.
@MainActor
final class LibraryScrollTargetTests: XCTestCase {

    private func makeVM() -> LibraryViewModel {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibScroll.\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = LibraryIndexStore(databaseURL: dir.appendingPathComponent("idx.sqlite"))
        return LibraryViewModel(config: CaptureConfig(), store: store,
                                onOpen: { _ in }, onCaptureNew: {})
    }

    func test_selectOnly_doesNotRequestScroll() {
        let vm = makeVM()
        vm.selectOnly(URL(fileURLWithPath: "/tmp/a.png"))
        XCTAssertNil(vm.scrollTarget)
    }

    func test_toggle_doesNotRequestScroll() {
        let vm = makeVM()
        vm.toggle(URL(fileURLWithPath: "/tmp/a.png"))
        XCTAssertNil(vm.scrollTarget)
    }

    func test_reveal_requestsScroll() {
        let vm = makeVM()
        let url = URL(fileURLWithPath: "/tmp/a.png")
        vm.reveal(url)
        XCTAssertEqual(vm.scrollTarget, url)
    }
}
