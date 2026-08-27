import SwiftUI

/// Sheet for the lock screen's "I can't unlock…" escape hatch — the
/// last-resort path when neither Touch ID nor a recovery code can open the
/// library. Explains the two-factor design, states plainly that nobody
/// (including Sealshot) can bypass it, then offers `LockoutReset` gated
/// behind a typed "RESET" confirmation so the destructive action can't be
/// triggered by an errant click. Hosted like `RecoveryEntryView` (see
/// `EditorWindowController.presentLockoutExplainerSheet`).
struct LockoutExplainerView: View {
    let saveFolder: URL
    let lockedCount: Int
    let onReset: (LockoutReset.Summary) -> Void
    let onCancel: () -> Void

    @State private var confirmationText = ""
    @State private var isWorking = false
    @State private var errorMessage: String?

    private static let confirmationPhrase = "RESET"

    private var canReset: Bool {
        confirmationText == Self.confirmationPhrase && !isWorking
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Can't Unlock Sealshot?").font(.title2.bold())

            VStack(alignment: .leading, spacing: 10) {
                Text("Your library is protected by two things: a key stored in this Mac's Keychain, and a recovery code you saved when you turned encryption on. By design, nobody — including Sealshot — can open your library without one of them.")
                Text("If both are truly unavailable, the only way forward is to start fresh.")
            }
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Move \(lockedCount) encrypted item\(lockedCount == 1 ? "" : "s") to a Locked Archive and start fresh. Nothing is deleted; if you find your recovery code later you can restore everything. This may take a moment for large libraries.")
                    .fixedSize(horizontal: false, vertical: true)
                Text("Type \(Self.confirmationPhrase) to confirm.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                TextField(Self.confirmationPhrase, text: $confirmationText)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isWorking)
            }

            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).font(.callout)
            }

            HStack {
                Button("Cancel") { onCancel() }.disabled(isWorking)
                Spacer()
                if isWorking {
                    ProgressView().controlSize(.small).padding(.trailing, 4)
                }
                Button("Reset…", role: .destructive) { performReset() }
                    .disabled(!canReset)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func performReset() {
        isWorking = true
        errorMessage = nil
        // `LockoutReset.perform` is synchronous, MainActor-isolated file I/O.
        // Hopping through a Task first lets the spinner above actually paint
        // a frame before the (typically fast, but potentially package-count-
        // proportional) sweep runs on the main thread.
        Task { @MainActor in
            do {
                let summary = try LockoutReset.perform(
                    saveFolder: saveFolder, session: .shared, identityStore: KeychainIdentityStore())
                isWorking = false
                onReset(summary)
            } catch {
                isWorking = false
                errorMessage = "Reset failed: \(error.localizedDescription)"
            }
        }
    }

    /// Cheap sweep counting locked `.seal` packages across every folder
    /// `LockoutReset` archives from (save-folder root, `Deleted/`,
    /// `Recordings/`). Mirrors `LockoutReset.packageFolderNames` — kept as a
    /// separate, additive copy rather than reaching into that (tested,
    /// frozen) engine's private implementation detail.
    static func countLockedPackages(in saveFolder: URL) -> Int {
        let fm = FileManager.default
        var count = 0
        for name in ["", "Deleted", "Recordings"] {
            let dir = name.isEmpty ? saveFolder : saveFolder.appendingPathComponent(name, isDirectory: true)
            let packages = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension.lowercased() == "seal" }
            count += packages.filter { SealPackageCrypter.isLocked($0) }.count
        }
        return count
    }
}
