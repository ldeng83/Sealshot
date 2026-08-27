import Foundation

/// Drives the determinate "Enhancing…" progress bar. Updated on the main actor
/// from ImageEnhancer's per-tile progress callback.
@MainActor
@Observable
final class EnhanceProgress {
    /// 0.0 ... 1.0
    var fraction: Double = 0
}
