import SwiftUI

struct ImportPackageSheet: View {
    @Bindable var model: ImportPackageModel
    var onCancel: () -> Void
    var onAddToLibrary: () -> Void
    var onSaveToFolder: () -> Void

    private static let dateStyle: Date.FormatStyle = .dateTime.year().month().day()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Open Encrypted Package").font(.headline)
            Text("Enter the passcode the sender shared with you.")
                .font(.callout).foregroundStyle(.secondary)

            if let hint = model.hint, !hint.isEmpty {
                Text("Hint: \(hint)").font(.callout)
            }
            Text("Created \(model.createdAt.formatted(Self.dateStyle))"
                 + (model.expiresAt.map { " · expires \($0.formatted(Self.dateStyle))" } ?? ""))
                .font(.caption).foregroundStyle(.secondary)

            SecureField("Passcode", text: $model.passphrase)
                .onSubmit { if model.canSubmit { onAddToLibrary() } }

            if let error = model.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            if model.isWorking {
                ProgressView().controlSize(.small)
            }

            HStack {
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save to Folder…", action: onSaveToFolder)
                    .disabled(!model.canSubmit)
                Button("Add to Library", action: onAddToLibrary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canSubmit)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

/// Compact notice card for import outcomes ("Import Complete", failures,
/// expiry). macOS 26's system NSAlert pins its icon to the top-LEFT
/// (leading-aligned layout — verified empirically; title/informative split
/// doesn't change it), and design wants the icon centered, so this custom
/// card centers icon, title, and message with a full-width OK.
struct ImportNoticeView: View {
    let title: String
    let message: String
    var onOK: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 56, height: 56)
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onOK) {
                Text("OK").frame(maxWidth: .infinity)
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 6)
        }
        .padding(20)
        .frame(width: 280)
    }
}
