import SwiftUI
import AppKit

/// Hosts the editor Info panel's click-to-edit AppKit views (EditableNameView /
/// EditableSummaryView) inside the SwiftUI Library sidebar, so both Info panels
/// share one inline-editing implementation and feel: click puts the caret where
/// clicked (no field swap, no select-all), ↩ / ⌘↩ commits, Esc cancels, and the
/// summary's context menu offers "Revert to Generated Summary".
///
/// Height = the wrapped text's height for the proposed width, re-measured on
/// every text change (`editTick`) so the row grows while the user types.
private struct WrappingTextViewHost<V: WrappingTextView>: NSViewRepresentable {
    let make: () -> V
    @Binding var editTick: Int

    @MainActor final class Coordinator {
        var onTextChange: () -> Void = {}
        var observer: NSObjectProtocol?
        deinit { if let o = observer { NotificationCenter.default.removeObserver(o) } }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> V {
        let view = make()
        // SwiftUI sizes this view via sizeThatFits below; the layout()-time
        // constraint invalidation (needed in plain AppKit stacks) would dirty
        // the window's constraints mid display-flush here and crash.
        view.invalidatesIntrinsicSizeOnLayout = false
        let coordinator = context.coordinator
        coordinator.observer = NotificationCenter.default.addObserver(
            forName: NSText.didChangeNotification, object: view, queue: .main
        ) { _ in
            MainActor.assumeIsolated { coordinator.onTextChange() }
        }
        return view
    }

    func updateNSView(_ view: V, context: Context) {
        context.coordinator.onTextChange = { editTick += 1 }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: V, context: Context) -> CGSize? {
        _ = editTick   // ties measurement to text changes
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        return CGSize(width: width, height: nsView.wrappedHeight(forWidth: width))
    }
}

extension WrappingTextView {
    /// The height this view's current text needs at `width`, measured from the
    /// attributed string WITHOUT mutating the view. sizeThatFits runs during
    /// SwiftUI's layout pass — resizing the view there (to make TextKit
    /// re-wrap) marks it needing layout again and spirals into the recursive
    /// constraint-invalidation crash this file's host exists to avoid.
    /// boundingRect honors the storage's fonts and paragraph styles (the
    /// summary's 1.30 line height), and lineFragmentPadding/insets are zero.
    fileprivate func wrappedHeight(forWidth width: CGFloat) -> CGFloat {
        guard let storage = textStorage, storage.length > 0 else { return 16 }
        let rect = storage.boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        return max(16, ceil(rect.height))
    }
}

/// The Library Info panel's Name value: the editor's in-place rename view,
/// committing through the Library's userTitle rename path.
struct LibraryInlineNameEditor: View {
    let url: URL
    let displayName: String
    let onRename: (String) -> Void
    @State private var editTick = 0

    var body: some View {
        WrappingTextViewHost(
            make: {
                EditableNameView(currentName: { CaptureDisplayName.resolve(for: url) },
                                 onRename: onRename)
            },
            editTick: $editTick
        )
        // Recreate when the item (or an externally-changed name) moves on;
        // in-session commits render optimistically inside the view itself.
        .id("\(url.path)|\(displayName)")
    }
}

/// The Library Info panel's Summary value: the editor's in-place summary view.
/// It persists the `userSummary` override itself (same commit semantics as the
/// editor) and posts `.captureMetadataDidChange`, which the Library view model
/// already observes to refresh.
struct LibraryInlineSummaryEditor: View {
    let url: URL
    let generated: String?
    let userSummary: String?
    let tags: [String]
    @State private var editTick = 0

    var body: some View {
        WrappingTextViewHost(
            make: {
                EditableSummaryView(url: url, generated: generated,
                                    userSummary: userSummary, highlightTags: tags)
            },
            editTick: $editTick
        )
        // Distinguish nil (no override) from "" (suppressed) so the hosted
        // view recreates when the user clears or reverts a summary.
        .id("\(url.path)|\(generated ?? "")|\(userSummary.map { "u:\($0)" } ?? "nil")")
    }
}
