import Foundation
import Combine

/// Drives the enabled state + target of the File-menu "Export Encrypted Package…"
/// command. The SwiftUI `.commands` builder observes `shared` (like
/// `RecordingMenuState.shared`); the Library view and the editor recent-strip
/// publish their current selection here so the menu reflects whatever is
/// selected in the active context.
///
/// Only cheap flags are published eagerly — the actual `SharePackageSource`
/// list is resolved lazily via `resolveSources()` when a command is invoked.
/// Selection changes fire on every marquee tick / ⌘-click, so building the
/// source list (display-name resolution reads manifests) per change made
/// large selections visibly slow.
@MainActor
final class ExportMenuState: ObservableObject {
    static let shared = ExportMenuState()

    /// Which view last set the selection. Used so an inactive view going away
    /// can't wipe the active view's selection.
    enum Owner: Equatable { case library, editorStrip }

    /// Nothing exportable is selected → commands disabled.
    @Published private(set) var isEmpty = true
    /// The selection contains at least one video → "Export to Video" enabled.
    @Published private(set) var hasVideo = false
    private var provider: () -> [SharePackageSource] = { [] }
    private(set) var owner: Owner?

    init() {}

    /// Record the current export selection for the context the user is acting
    /// in. `provider` is called only when a command actually fires.
    func update(isEmpty: Bool, hasVideo: Bool, owner: Owner,
                provider: @escaping () -> [SharePackageSource]) {
        self.owner = owner
        // Republishing an equal value still notifies observers — skip.
        if self.isEmpty != isEmpty { self.isEmpty = isEmpty }
        if self.hasVideo != hasVideo { self.hasVideo = hasVideo }
        self.provider = provider
    }

    /// Sources the export command acts on, resolved at invocation time.
    func resolveSources() -> [SharePackageSource] { provider() }

    /// Clear the selection, but only if `owner` currently owns it (so a
    /// background view disappearing can't clobber the active view's selection).
    func clear(owner: Owner) {
        guard self.owner == nil || self.owner == owner else { return }
        self.owner = nil
        if !isEmpty { isEmpty = true }
        if hasVideo { hasVideo = false }
        provider = { [] }
    }
}
