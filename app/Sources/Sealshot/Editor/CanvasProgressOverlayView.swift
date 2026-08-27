import SwiftUI

/// Full-canvas overlay with a determinate bar, phase label, and Cancel — shared
/// by long off-main canvas work (video summarize, redaction scan). Driven by a
/// `CanvasProgress` observable.
struct CanvasProgressOverlayView: View {
    var progress: CanvasProgress
    var onCancel: () -> Void = {}
    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
            VStack(spacing: 12) {
                if progress.isIndeterminate {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                } else {
                    ProgressView(value: progress.fraction)
                        .progressViewStyle(.linear)
                        .frame(width: 220)
                }
                Text(progress.label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                if !progress.note.isEmpty {
                    Text(progress.note)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.7))
                }
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(20)
            .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
            // The card is hard-coded dark, so its controls must render their
            // dark-appearance variants regardless of the app theme — the
            // default bordered Cancel disappears against the card when the
            // app is in light mode.
            .environment(\.colorScheme, .dark)
        }
    }
}
