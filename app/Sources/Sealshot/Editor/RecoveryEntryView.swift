import SwiftUI

/// Sheet for entering a recovery code on a Mac that has no stored identity
/// (e.g. a restored save folder). On success `onRecovered` is called; the
/// caller dismisses and the lock overlay tears down via the lock-state
/// notification.
struct RecoveryEntryView: View {
    @State private var model: RecoveryEntryModel
    @State private var code = ""
    let onRecovered: () -> Void
    let onCancel: () -> Void
    /// Guided-reset escape for users who don't have their code either —
    /// surfaced here (after they've been asked for the code) rather than on
    /// the lock screen, so the lossless paths get tried first.
    let onLockedOut: () -> Void

    init(saveFolder: URL, onRecovered: @escaping () -> Void, onCancel: @escaping () -> Void,
         onLockedOut: @escaping () -> Void = {}) {
        _model = State(initialValue: RecoveryEntryModel(saveFolder: saveFolder))
        self.onRecovered = onRecovered
        self.onCancel = onCancel
        self.onLockedOut = onLockedOut
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Enter Your Recovery Key").font(.title2.bold())
            Text("Enter the recovery key you saved when you turned on encryption. This restores access to your captures on this Mac.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("XXXXX-XXXXX-XXXXX-XXXXX-XXXXX", text: $code)
                .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                .disabled(model.isWorking)
            if let error = model.errorMessage {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            Button("I can't unlock…") { onLockedOut() }
                .buttonStyle(.link)
                .disabled(model.isWorking)
            HStack {
                Button("Cancel") { onCancel() }.disabled(model.isWorking)
                Spacer()
                Button("Recover") {
                    Task { if await model.recover(code: code) { onRecovered() } }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(code.isEmpty || model.isWorking)
            }
        }
        .padding(24).frame(width: 460)
    }
}
