import AppKit
import Observation

/// A counter that changes whenever thumbnails which previously failed to load
/// might now succeed — today, on every encryption lock-state change.
///
/// The Library loads each card's thumbnail once, from `.task(id:)` keyed on
/// path + mtime. Neither changes when the session unlocks, so a card that
/// rendered while the app was LOCKED — a sealed capture's thumbnail needs the
/// session identity to decrypt, and returns nil without it — kept its
/// placeholder for the rest of the run. Launching at login lands exactly
/// there: the grid draws before the user unlocks, and every card visible at
/// that moment stays a grey placeholder while cards scrolled into view later
/// load normally. (The editor strip escapes it by reloading on its own
/// signals — FSEvents, index changes, tab switches.)
///
/// Folding this into the task id gives those cards one more attempt at the
/// moment the material becomes readable. The same class of bug is already
/// handled for OCR backfill in `AppDelegate`, which re-runs on unlock for
/// packages skipped at launch.
@MainActor
@Observable
final class ThumbnailGeneration {

    static let shared = ThumbnailGeneration()

    private(set) var value = 0

    @ObservationIgnored private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: .encryptionLockStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.value &+= 1 }
        }
    }

    /// Composite key for a thumbnail-loading `.task(id:)`: the item's own
    /// identity plus this generation. Reading it inside a view's body is what
    /// subscribes that view to the bump.
    func taskID(_ itemKey: String) -> String { "\(itemKey)#\(value)" }

    /// Test hook: simulate a lock-state change.
    func bumpForTesting() { value &+= 1 }
}
