import SwiftUI

/// Code-entry sheet for restoring the Locked Archive (the reversal of the
/// guided lockout reset). One shared form for both entry points — the
/// Library banner's Restore… button (hosted by `EditorWindowController` as an
/// AppKit sheet) and the Settings → Privacy & Security row (native SwiftUI
/// `.sheet`). The engine (`LockedArchiveRestore`) tries the code against
/// every archived keystore, so the user never has to know which reset cycle
/// their code belongs to.
struct LockedArchiveRestoreView: View {
    private enum Phase {
        case entry
        case working
        case done(LockedArchiveRestore.Summary)
    }

    @State private var phase: Phase = .entry
    @State private var code = ""
    @State private var errorMessage: String?

    private let saveFolder: URL
    /// Called exactly once on dismissal: with the summary after a completed
    /// restore, or nil when the user cancelled without restoring anything.
    private let onDone: (LockedArchiveRestore.Summary?) -> Void

    init(saveFolder: URL, onDone: @escaping (LockedArchiveRestore.Summary?) -> Void) {
        self.saveFolder = saveFolder
        self.onDone = onDone
    }

    private var isWorking: Bool {
        if case .working = phase { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Restore Locked Archive").font(.title2.bold())
            switch phase {
            case .entry, .working:
                entryBody
            case .done(let summary):
                doneBody(summary)
            }
        }
        .padding(24).frame(width: 460)
    }

    @ViewBuilder
    private var entryBody: some View {
        Text("Enter the recovery code from before the reset. Items that code protected are moved back into your library.")
            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        TextField("XXXXX-XXXXX-XXXXX-XXXXX-XXXXX", text: $code)
            .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
            .disabled(isWorking)
        if let errorMessage {
            Text(errorMessage).foregroundStyle(.red).font(.callout)
        }
        HStack {
            Button("Cancel") { onDone(nil) }.disabled(isWorking)
            Spacer()
            if isWorking {
                ProgressView().controlSize(.small).padding(.trailing, 8)
            }
            Button("Restore") { Task { await restore() } }
                .keyboardShortcut(.defaultAction)
                .disabled(code.isEmpty || isWorking)
        }
    }

    @ViewBuilder
    private func doneBody(_ summary: LockedArchiveRestore.Summary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(resultLines(summary), id: \.self) { line in
                Text(line).fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(.secondary)
        HStack {
            Spacer()
            Button("Done") { onDone(summary) }.keyboardShortcut(.defaultAction)
        }
    }

    private func resultLines(_ summary: LockedArchiveRestore.Summary) -> [String] {
        var lines = ["Restored \(summary.restoredPackages) item\(summary.restoredPackages == 1 ? "" : "s")."]
        if summary.stillArchived > 0 {
            let n = summary.stillArchived
            lines.append("\(n) item\(n == 1 ? "" : "s") remain\(n == 1 ? "s" : "") in the archive — \(n == 1 ? "it belongs" : "they belong") to a different recovery code, or \(n == 1 ? "was" : "were") set aside when encryption was turned off.")
        }
        if !summary.failed.isEmpty {
            let n = summary.failed.count
            lines.append("\(n) item\(n == 1 ? "" : "s") couldn't be moved back and stay\(n == 1 ? "s" : "") in the archive — nothing was deleted.")
        }
        if summary.keystoreMoveFailed {
            lines.append("The recovery key is unlocked for this session, but couldn't be written back as the active key on disk — try Restore again.")
        }
        if !summary.capsuleFailures.isEmpty {
            lines.append("Some internal keys could not be restored — history/index data encrypted before the reset may be unavailable.")
        }
        if summary.displacedLiveCycle {
            lines.append("Items and data from your current setup are unavailable until you restore them with the current recovery code.")
        }
        return lines
    }

    @MainActor
    private func restore() async {
        phase = .working
        errorMessage = nil
        do {
            let summary = try await LockedArchiveRestore.restore(
                code: code, saveFolder: saveFolder,
                session: .shared, identityStore: KeychainIdentityStore())
            phase = .done(summary)
            // Typing a working recovery code here IS proof the user still has
            // it — stamp the same verification the periodic nudge checks, so
            // this counts toward the 90-day cadence (see RecoveryVerifyNudge).
            RecoveryVerifyNudgeController.stampVerifiedNow()
        } catch let error as LockedArchiveRestore.Error {
            phase = .entry
            switch error {
            case .codeDoesNotMatch:
                errorMessage = "That code doesn't match any archived backup. Check the code and try again."
            case .noArchivedKeystore:
                errorMessage = "No archived backup was found — there is nothing this code could restore."
            }
        } catch {
            phase = .entry
            errorMessage = "Restore failed: \(error.localizedDescription)"
        }
    }
}
