import SwiftUI

/// First-use explainer for scrolling capture, shown once before the first
/// session. Mirrors `PermissionChecklistView`'s card style.
struct ScrollCaptureCoachView: View {
    /// Whether this build/session can drive the scrolling itself.
    let autoScrollAvailable: Bool
    let onStart: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "rectangle.expand.vertical")
                    .font(.system(size: 32))
                    .foregroundStyle(.tint)
                Text("Scrolling capture").font(.title3.bold())
            }

            Text(autoScrollAvailable
                 ? "Capture content taller than the screen — Sealshot scrolls it for you and stitches one tall image."
                 : "Capture content taller than the screen — scroll the content yourself and Sealshot stitches one tall image.")

            VStack(alignment: .leading, spacing: 6) {
                row("Drag to select the area you want captured.")
                row(autoScrollAvailable
                    ? "Sealshot scrolls and stitches automatically — hands off."
                    : "Scroll the content slowly; it stitches as you go.")
                if autoScrollAvailable {
                    row("Your own scrolling is paused while it captures.")
                }
                row("Press ⏎ to finish · Esc cancels.")
            }
            .padding(.vertical, 4)

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Start Capture", action: onStart)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.top, 8)
        }
        .padding(24)
        .frame(width: 420)
    }

    private func row(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(text).font(.callout).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }
}
