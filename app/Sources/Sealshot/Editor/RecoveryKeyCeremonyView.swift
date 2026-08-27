import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers

/// One-time recovery-code display. The code is shown exactly once; closing
/// requires confirming it was saved. Closing calls `onDone` (which acks the
/// model). There is intentionally no way to re-show it later.
struct RecoveryKeyCeremonyView: View {
    let code: String
    /// Context paragraph above the code. Defaults to the setup/regenerate
    /// wording; the keystore auto-repair passes its own explanation.
    var message = "Save this code somewhere safe. It's the only way to recover "
        + "your encrypted captures if you lose access to this Mac. We can't show "
        + "it again, and we can't recover it for you."
    let onDone: () -> Void
    @State private var saved = false
    /// Resolved once per ceremony (not `Date()` at each call site) so Save
    /// and Print produce the exact same PDF content — and so the printed
    /// copy is provably the same bytes-in-substance as what Save would
    /// write, not a second, potentially-different render.
    @State private var generatedAt = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Your Recovery Key").font(.title2.bold())
            Text(message)
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(code).font(.system(.title3, design: .monospaced))
                    .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                    .textSelection(.enabled).padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .textBackgroundColor),
                                in: RoundedRectangle(cornerRadius: 8))
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                .help("Copy to clipboard")
                Button {
                    saveKit()
                } label: { Image(systemName: "square.and.arrow.down") }
                .help("Save Kit…")
                Button {
                    printKit()
                } label: { Image(systemName: "printer") }
                .help("Print…")
            }
            Toggle("I've saved my recovery key somewhere safe", isOn: $saved)
            HStack {
                Spacer()
                Button("Done") {
                    // Acknowledging a freshly generated/rotated code is itself
                    // proof of current possession — seeds the same
                    // verification stamp the periodic nudge checks, so a
                    // brand-new code doesn't immediately read as "unverified".
                    RecoveryVerifyNudgeController.stampVerifiedNow()
                    onDone()
                }.keyboardShortcut(.defaultAction).disabled(!saved)
            }
        }
        // Wide enough that the 29-char code and its three action buttons fit
        // on ONE line — a wrapped recovery code invites mis-transcription.
        .padding(24).frame(width: 560)
        // The code is shown exactly once and cannot be re-displayed — block
        // Escape / click-away dismissal so it can only close via "Done"
        // (gated on the "I saved it" checkbox).
        .interactiveDismissDisabled(true)
    }

    /// "Licensed to Name (email)" line, or nil when there is no license —
    /// resolved here (the call site) so `RecoveryKitPDF.make` stays a pure,
    /// testable builder.
    private var licenseeLine: String? {
        switch EntitlementStore.shared.state {
        case .licensed(let payload), .buildNotCovered(let payload):
            return "Licensed to \(payload.name) (\(payload.email))"
        case .unlicensed:
            return nil
        }
    }

    private var macName: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    private func makePDFData() -> Data {
        RecoveryKitPDF.make(code: code, generatedAt: generatedAt, macName: macName,
                           licenseeLine: licenseeLine)
    }

    /// NSSavePanel via `runModal()` (not a sheet) — this view is hosted from
    /// three different places (Settings sheet, toggle phases, an
    /// AppDelegate auto-repair window), so there's no single parent window
    /// to reliably attach a sheet to.
    private func saveKit() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = RecoveryKitPDF.defaultFilename
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try makePDFData().write(to: url, options: .atomic)
            // Deliberately does NOT tick the "I've saved it" checkbox — that
            // confirmation stays a manual, conscious act.
        } catch {
            presentSaveFailureAlert()
        }
    }

    private func presentSaveFailureAlert() {
        presentAlert(title: "Couldn't Save Recovery Kit",
                    message: "The recovery kit PDF couldn't be saved to that location. "
                        + "Try again and choose a different location.")
    }

    private func presentPrintFailureAlert() {
        presentAlert(title: "Couldn't Print Recovery Kit",
                    message: "The recovery kit PDF couldn't be prepared for printing. "
                        + "Try again, or use Save Kit… instead.")
    }

    private func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// Prints the same, already-self-verified PDF data `saveKit()` writes to
    /// disk — never a second, independent render. A bare `NSHostingView`
    /// handed straight to `NSPrintOperation(view:)` is the exact
    /// unparented-view configuration `RecoveryKitPDF.make` has to work
    /// around internally (offscreen window + forced layout) to avoid
    /// producing a structurally valid but visually blank PDF; reusing that
    /// self-checked data via PDFKit's own print operation sidesteps the
    /// problem entirely instead of re-creating it at a second call site.
    private func printKit() {
        let data = makePDFData()
        guard let document = PDFDocument(data: data) else {
            presentPrintFailureAlert()
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let printInfo = NSPrintInfo.shared
        guard let operation = document.printOperation(for: printInfo,
                                                       scalingMode: .pageScaleNone,
                                                       autoRotate: true) else {
            presentPrintFailureAlert()
            return
        }
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        // As with saveKit: printing never auto-ticks the confirmation.
        operation.run()
    }
}
