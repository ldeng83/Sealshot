import Foundation

/// Which date bucket the Library grid is narrowed to. `.none` = no narrowing.
enum LibraryDateFilter: Equatable {
    case none
    case today
    case last7Days
    case year(Int)
    case month(year: Int, month: Int)
    case day(year: Int, month: Int, day: Int)

    /// Short human label for the active-filter chip. Empty for `.none`.
    var chipLabel: String {
        func monthName(_ m: Int) -> String {
            let names = Calendar.current.shortMonthSymbols
            return (1...12).contains(m) ? names[m - 1] : "\(m)"
        }
        switch self {
        case .none:                       return ""
        case .today:                      return "Today"
        case .last7Days:                  return "Last 7 days"
        case .year(let y):                return "\(y)"
        case .month(let y, let m):        return "\(monthName(m)) \(y)"
        case .day(let y, let m, let d):   return "\(monthName(m)) \(d), \(y)"
        }
    }
}

/// Whether `item` (keyed by its capture date `modified`) passes `filter` in the
/// user's local `calendar`. Pure.
func matchesDateFilter(_ item: LibraryItem, _ filter: LibraryDateFilter,
                       calendar: Calendar, now: Date) -> Bool {
    let d = item.modified
    switch filter {
    case .none:
        return true
    case .today:
        return calendar.isDate(d, inSameDayAs: now)
    case .last7Days:
        guard let cutoff = calendar.date(byAdding: .day, value: -6,
                                         to: calendar.startOfDay(for: now)) else { return true }
        return d >= cutoff
    case .year(let y):
        return calendar.component(.year, from: d) == y
    case .month(let y, let m):
        let c = calendar.dateComponents([.year, .month], from: d)
        return c.year == y && c.month == m
    case .day(let y, let m, let day):
        let c = calendar.dateComponents([.year, .month, .day], from: d)
        return c.year == y && c.month == m && c.day == day
    }
}

/// Counts of items per year/month/day (newest-first), plus Today / Last-7-days
/// quick-bucket counts. Built from the section+search-filtered set BEFORE the
/// date filter, so counts show what navigation would reveal. Pure.
struct LibraryDateFacets: Equatable {
    struct Day: Equatable { let day: Int; let count: Int }
    struct Month: Equatable { let month: Int; let count: Int; let days: [Day] }
    struct Year: Equatable { let year: Int; let count: Int; let months: [Month] }
    let years: [Year]
    let todayCount: Int
    let last7Count: Int
    var isEmpty: Bool { years.isEmpty }
}

func libraryDateFacets(_ items: [LibraryItem], calendar: Calendar, now: Date) -> LibraryDateFacets {
    // [year: [month: [day: count]]]
    var tree: [Int: [Int: [Int: Int]]] = [:]
    var todayCount = 0
    var last7Count = 0
    let last7Cutoff = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now))
    for item in items {
        let c = calendar.dateComponents([.year, .month, .day], from: item.modified)
        guard let y = c.year, let m = c.month, let d = c.day else { continue }
        tree[y, default: [:]][m, default: [:]][d, default: 0] += 1
        if calendar.isDate(item.modified, inSameDayAs: now) { todayCount += 1 }
        if let cutoff = last7Cutoff, item.modified >= cutoff { last7Count += 1 }
    }
    let years = tree.keys.sorted(by: >).map { y -> LibraryDateFacets.Year in
        let months = tree[y]!.keys.sorted(by: >).map { m -> LibraryDateFacets.Month in
            let days = tree[y]![m]!.keys.sorted(by: >).map { d in
                LibraryDateFacets.Day(day: d, count: tree[y]![m]![d]!)
            }
            let monthCount = days.reduce(0) { $0 + $1.count }
            return LibraryDateFacets.Month(month: m, count: monthCount, days: days)
        }
        let yearCount = months.reduce(0) { $0 + $1.count }
        return LibraryDateFacets.Year(year: y, count: yearCount, months: months)
    }
    return LibraryDateFacets(years: years, todayCount: todayCount, last7Count: last7Count)
}
