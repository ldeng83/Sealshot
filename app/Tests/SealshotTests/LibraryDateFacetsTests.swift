import XCTest
@testable import Sealshot

final class LibraryDateFacetsTests: XCTestCase {
    // Fixed calendar so day boundaries are deterministic regardless of host TZ.
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()
    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }
    private func item(_ date: Date, name: String = "x") -> Sealshot.LibraryItem {
        Sealshot.LibraryItem(url: URL(fileURLWithPath: "/x/\(name)-\(date.timeIntervalSince1970).seal"),
                             modified: date, displayName: name)
    }

    func test_none_matchesEverything() {
        XCTAssertTrue(matchesDateFilter(item(date(2026, 6, 23)), .none, calendar: cal, now: date(2026, 6, 23)))
    }
    func test_today_matchesSameLocalDayOnly() {
        let now = date(2026, 6, 23, 9)
        XCTAssertTrue(matchesDateFilter(item(date(2026, 6, 23, 23)), .today, calendar: cal, now: now))
        XCTAssertFalse(matchesDateFilter(item(date(2026, 6, 22, 23)), .today, calendar: cal, now: now))
    }
    func test_last7Days_inclusiveOf6DaysAgoStartOfDay() {
        let now = date(2026, 6, 23, 9)
        XCTAssertTrue(matchesDateFilter(item(date(2026, 6, 17, 0)), .last7Days, calendar: cal, now: now))  // 6 days back
        XCTAssertFalse(matchesDateFilter(item(date(2026, 6, 16, 23)), .last7Days, calendar: cal, now: now)) // 7 days back
    }
    func test_year_month_day() {
        let i = item(date(2026, 5, 19, 14))
        let now = date(2026, 6, 23)
        XCTAssertTrue(matchesDateFilter(i, .year(2026), calendar: cal, now: now))
        XCTAssertFalse(matchesDateFilter(i, .year(2025), calendar: cal, now: now))
        XCTAssertTrue(matchesDateFilter(i, .month(year: 2026, month: 5), calendar: cal, now: now))
        XCTAssertFalse(matchesDateFilter(i, .month(year: 2026, month: 6), calendar: cal, now: now))
        XCTAssertTrue(matchesDateFilter(i, .day(year: 2026, month: 5, day: 19), calendar: cal, now: now))
        XCTAssertFalse(matchesDateFilter(i, .day(year: 2026, month: 5, day: 18), calendar: cal, now: now))
    }

    func test_facets_groupByYearMonthDay_newestFirst_withCounts() {
        let items = [
            item(date(2026, 6, 23)), item(date(2026, 6, 23)),   // 2026-06-23 x2
            item(date(2026, 5, 19)),                            // 2026-05-19 x1
            item(date(2025, 12, 1)),                            // 2025-12-01 x1
        ]
        let f = libraryDateFacets(items, calendar: cal, now: date(2026, 6, 23, 9))
        XCTAssertEqual(f.years.map(\.year), [2026, 2025])           // newest first
        XCTAssertEqual(f.years[0].count, 3)                        // 2026 total
        XCTAssertEqual(f.years[0].months.map(\.month), [6, 5])     // newest month first
        let june = f.years[0].months[0]
        XCTAssertEqual(june.count, 2)
        XCTAssertEqual(june.days.map(\.day), [23])                // only active days
        XCTAssertEqual(june.days[0].count, 2)
    }

    func test_facets_todayAndLast7Counts() {
        let now = date(2026, 6, 23, 9)
        let items = [item(date(2026, 6, 23)), item(date(2026, 6, 20)), item(date(2026, 6, 10))]
        let f = libraryDateFacets(items, calendar: cal, now: now)
        XCTAssertEqual(f.todayCount, 1)
        XCTAssertEqual(f.last7Count, 2)   // 23 and 20; 10 is outside
    }

    func test_facets_empty() {
        let f = libraryDateFacets([], calendar: cal, now: date(2026, 6, 23))
        XCTAssertTrue(f.isEmpty)
        XCTAssertEqual(f.todayCount, 0)
    }
}
