import Foundation

/// Drives a determinate progress overlay over the canvas (video summarize,
/// redaction scan, …): a 0…1 fraction plus a phase label. Updated on the main
/// actor from the off-main work.
@MainActor
@Observable
final class CanvasProgress {
    /// 0.0 ... 1.0
    var fraction: Double = 0
    var label: String = ""
    /// Secondary line shown only when a phase is taking unusually long (so the
    /// user knows it's still working, not stuck). Empty = hidden.
    var note: String = ""
    /// Show a spinner instead of the 0…1 bar. Live Text recognition reports no
    /// fraction — a determinate bar frozen at 0% reads as stuck. Everything
    /// else (redaction scan, Extract Data, video summarize) stays determinate.
    var isIndeterminate: Bool = false
}
