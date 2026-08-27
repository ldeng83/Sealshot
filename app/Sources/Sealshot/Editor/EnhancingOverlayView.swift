import SwiftUI

/// Full-canvas "Enhancing…" overlay shown while the model runs. Non-blocking
/// (the enhance work is off-main); shows a determinate progress bar driven by
/// the `EnhanceProgress` observable model.
struct EnhancingOverlayView: View {
    var progress: EnhanceProgress
    /// Invoked when the user clicks Cancel (or presses Esc). Cancels the
    /// in-flight enhance; the overlay is torn down by the caller.
    var onCancel: () -> Void = {}
    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
            VStack(spacing: 12) {
                ProgressView(value: progress.fraction)
                    .progressViewStyle(.linear)
                    .frame(width: 200)
                Text("Enhancing… \(Int((progress.fraction * 100).rounded()))%")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(20)
            .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
            // Hard-coded dark card: controls must render their dark-appearance
            // variants regardless of app theme (the default bordered Cancel
            // disappears against the card in light mode).
            .environment(\.colorScheme, .dark)
        }
    }
}
