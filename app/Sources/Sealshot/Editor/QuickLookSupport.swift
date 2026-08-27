import Foundation

/// Pure decision for the Library Quick Look toggle. Kept UI-free so the
/// open/close/select-first behavior is unit-testable without a view model.
enum QuickLookToggle {
    struct Result: Equatable {
        var open: Bool
        /// A URL the caller should select before opening (nil = leave selection as-is).
        var selectURL: URL?
    }

    static func resolve(currentlyOpen: Bool, selection: [URL], anchor: URL?, firstItem: URL?) -> Result {
        if currentlyOpen { return Result(open: false, selectURL: nil) }
        switch selection.count {
        case 0:
            guard let first = firstItem else { return Result(open: false, selectURL: nil) }
            return Result(open: true, selectURL: first)
        case 1:
            return Result(open: true, selectURL: nil)
        default:
            // Preview the anchor when present, else a deterministic (sorted-first) member.
            let target = anchor ?? selection.sorted(by: { $0.path < $1.path }).first
            return Result(open: true, selectURL: target)
        }
    }
}

