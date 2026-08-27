import Foundation

/// Total bytes on disk of a `.seal` package (an `NSFileWrapper` directory
/// bundle of flat entries), or nil when the path can't be read. Used by the
/// Info pane's "Size" row.
func sealPackageSize(at url: URL) -> Int64? {
    let fm = FileManager.default
    guard let enumerator = fm.enumerator(
        at: url,
        includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
        options: [],
        errorHandler: nil)
    else { return nil }

    var total: Int64 = 0
    var sawFile = false
    for case let fileURL as URL in enumerator {
        guard let values = try? fileURL.resourceValues(
            forKeys: [.isRegularFileKey, .fileSizeKey]),
            values.isRegularFile == true, let size = values.fileSize
        else { continue }
        total += Int64(size)
        sawFile = true
    }
    return sawFile ? total : nil
}

/// Size in bytes of a capture on disk for the Library index: the `.seal`
/// package's total, or a plain file's own size (legacy `.png`). 0 when
/// unreadable. Non-zero for any real capture, so the index can use 0 as a
/// "size not yet computed" sentinel.
func captureFileSize(at url: URL) -> Int64 {
    if let packaged = sealPackageSize(at: url) { return packaged }
    let single = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? nil
    return Int64(single ?? 0)
}
