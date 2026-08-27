import XCTest
@testable import Sealshot

@MainActor
final class LibraryDateOrganizerStateTests: XCTestCase {
    private func makeViewModel() -> LibraryViewModel {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibDateOrg.\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = LibraryIndexStore(databaseURL: dir.appendingPathComponent("idx.sqlite"))
        return LibraryViewModel(config: CaptureConfig(), store: store,
                                onOpen: { _ in }, onCaptureNew: {})
    }

    func test_toggleYear_accordion() {
        let vm = makeViewModel()
        vm.toggleYear(2026); vm.toggleMonth(6)
        XCTAssertEqual(vm.expandedYear, 2026); XCTAssertEqual(vm.expandedMonth, 6)
        vm.toggleYear(2025)                                    // switch year
        XCTAssertEqual(vm.expandedYear, 2025); XCTAssertNil(vm.expandedMonth)  // month reset
        vm.toggleYear(2025)                                    // collapse
        XCTAssertNil(vm.expandedYear)
    }

    func test_toggleMonth_collapsesOnRepeat() {
        let vm = makeViewModel()
        vm.toggleYear(2026); vm.toggleMonth(5)
        XCTAssertEqual(vm.expandedMonth, 5)
        vm.toggleMonth(5)
        XCTAssertNil(vm.expandedMonth)
    }

    func test_selectDate_toggleClears() {
        let vm = makeViewModel()
        vm.selectDate(.year(2026)); XCTAssertEqual(vm.dateFilter, .year(2026))
        vm.selectDate(.year(2026)); XCTAssertEqual(vm.dateFilter, .none)   // re-click clears
        vm.selectDate(.month(year: 2026, month: 5))
        XCTAssertEqual(vm.dateFilter, .month(year: 2026, month: 5))
    }

    // The "All dates" row always clears the filter, from any state — so a filter
    // is never stranded when its date row is absent in the current section.
    func test_selectDate_noneAlwaysClears() {
        let vm = makeViewModel()
        vm.selectDate(.day(year: 2026, month: 6, day: 23))
        vm.selectDate(.none); XCTAssertEqual(vm.dateFilter, .none)
        vm.selectDate(.none); XCTAssertEqual(vm.dateFilter, .none)   // idempotent
    }
}
