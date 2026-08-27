import Foundation

/// Enablement for the menu-bar Edit▸object items (Duplicate, Arrange, Flip).
///
/// SwiftUI `Commands` can't use AppKit's `validateMenuItem`, so these items
/// bind `.disabled(...)` to published flags that the editor pushes on every
/// selection change — the same arrangement as `ExportMenuState`.
@MainActor
final class ObjectMenuState: ObservableObject {
    static let shared = ObjectMenuState()

    /// Any annotation object is selected → Duplicate and Arrange enabled.
    @Published private(set) var hasSelection = false
    /// The selection contains something that can mirror → Flip enabled.
    /// `EditorState.isFlippable` excludes only `.badge`; text mirrors fine.
    @Published private(set) var hasFlippableSelection = false

    init() {}

    func update(hasSelection: Bool, hasFlippableSelection: Bool) {
        // Republishing an equal value still notifies observers — skip.
        if self.hasSelection != hasSelection { self.hasSelection = hasSelection }
        if self.hasFlippableSelection != hasFlippableSelection {
            self.hasFlippableSelection = hasFlippableSelection
        }
    }
}
