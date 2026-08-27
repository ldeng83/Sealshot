import Foundation

/// Summary of a set of Library items for the sidebar's Info section.
struct LibraryInfoAggregate: Equatable {
    var visibleCount: Int
    var imageCount: Int
    var videoCount: Int
    var totalSize: Int64
    var oldest: Date?
    var newest: Date?
    var sectionTotal: Int
    var isNarrowed: Bool

    static func make(visible: [LibraryItem], sectionTotal: Int,
                     isNarrowed: Bool) -> LibraryInfoAggregate {
        let videos = visible.filter { $0.isVideo }.count
        let dates = visible.map { $0.modified }
        return LibraryInfoAggregate(
            visibleCount: visible.count,
            imageCount: visible.count - videos,
            videoCount: videos,
            totalSize: visible.reduce(0) { $0 + $1.fileSize },
            oldest: dates.min(), newest: dates.max(),
            sectionTotal: sectionTotal, isNarrowed: isNarrowed)
    }
}
