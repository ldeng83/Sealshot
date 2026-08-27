import Foundation

/// Builds a unique recording filename in the Recordings folder. Pure: the
/// caller supplies the timestamp string and an existence probe.
enum RecordingFilename {
    static func make(stamp: String, format: RecordingFormat,
                     exists: (String) -> Bool) -> String {
        let ext = format.fileExtension
        let base = stamp
        var candidate = "\(base).\(ext)"
        var n = 2
        while exists(candidate) { candidate = "\(base) \(n).\(ext)"; n += 1 }
        return candidate
    }
}
