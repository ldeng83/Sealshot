import AppKit
import SwiftUI
import os.log

private let log = OSLog(subsystem: "com.seal-shot.sealshot", category: "feedback")

/// "Send Feedback…" flow: an opt-in dialog, then the best available compose
/// path — Mail compose with attachment, `mailto:` (revealing the diagnostics
/// file for manual attach), or copying the address+template to the clipboard
/// as the floor that cannot fail. See the feedback-channel design doc.
@MainActor
enum FeedbackComposer {

    /// Keeps the modeless fallback window alive; nil whenever no dialog is up.
    private static var fallbackWindow: NSWindow?

    static func present() {
        // Custom centered card instead of NSAlert: macOS 26 pins the alert icon
        // top-left and no NSAlert config centers it (same reason as the import
        // notices — ImportNoticeView).
        //
        // Presented as a SHEET, never via NSApp.runModal(for:). Both callers are
        // SwiftUI Buttons, and a nested modal loop started from inside SwiftUI's
        // action dispatch hangs the app: the loop blocks the main thread while
        // SwiftUI's update pass is still open, so this card's own hosting view
        // can never update. It does not render (its .onAppear never even fires),
        // so nothing can call stopModal(), and the app-modal session then eats
        // every event forever. A sheet runs no nested loop, so it cannot deadlock.
        //
        // Verified with a standalone repro: SwiftUI content in runModal(for:)
        // never appears and hangs; the identical window with AppKit content
        // works; the same card in a sheet renders and dismisses normally.
        var choice: Bool? = nil   // nil = cancelled
        var dismiss: () -> Void = {}
        let card = FeedbackNoticeView(
            onCancel: { choice = nil; dismiss() },
            onCompose: { diagnostics in choice = diagnostics; dismiss() })
        let window = NSWindow(contentViewController: NSHostingController(rootView: card))
        window.styleMask = [.titled]
        window.title = "Send Feedback"     // shown only on the modeless fallback
        // -close would RELEASE the window (isReleasedWhenClosed defaults to true),
        // so order it out instead and drop our own reference explicitly.
        window.isReleasedWhenClosed = false

        if let host = NSApp.keyWindow ?? NSApp.mainWindow {
            dismiss = { host.endSheet(window) }
            host.beginSheet(window) { _ in
                // Composing here rather than in `dismiss` so the sheet is fully
                // gone before any mail client or NSAlert comes up.
                window.orderOut(nil)
                guard let diagnostics = choice else { return }
                compose(includeDiagnostics: diagnostics)
            }
        } else {
            // Nothing to host a sheet (no open window, e.g. menu-bar-only state).
            // Modeless rather than modal — the point above applies to any nested
            // loop, not just this one call.
            dismiss = {
                window.orderOut(nil)
                fallbackWindow = nil
                guard let diagnostics = choice else { return }
                // Off the current run-loop turn, so the button's own action has
                // finished unwinding before the compose path runs.
                DispatchQueue.main.async { compose(includeDiagnostics: diagnostics) }
            }
            fallbackWindow = window
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private static func compose(includeDiagnostics: Bool) {
        var body = FeedbackBody.body()
        var logFile: URL?
        if includeDiagnostics {
            do {
                logFile = try DiagnosticsExporter.exportFile()
            } catch {
                os_log("diagnostics export failed: %{public}@",
                       log: log, type: .error, String(describing: error))
                body += "\n(diagnostics unavailable)"
            }
        }
        let subject = FeedbackBody.subject()

        // 1. Native Mail compose — supports a real attachment.
        var items: [Any] = [body]
        if let logFile { items.append(logFile) }
        if let service = NSSharingService(named: .composeEmail),
           service.canPerform(withItems: items) {
            service.recipients = [FeedbackBody.address]
            service.subject = subject
            service.perform(withItems: items)
            return
        }

        // 2. mailto: — no attachments, so reveal the log for manual attach.
        // Skipped when Mail itself is the handler: reaching this tier means
        // the compose service couldn't perform, i.e. Mail has no account, and
        // opening mailto: would dead-end in Mail's account-setup wizard with
        // our pre-filled draft lost. Third-party handlers compose fine.
        if let url = FeedbackBody.mailtoURL(subject: subject, body: body),
           let handler = NSWorkspace.shared.urlForApplication(toOpen: url),
           shouldUseMailto(handlerBundleID: Bundle(url: handler)?.bundleIdentifier) {
            if let logFile {
                NSWorkspace.shared.activateFileViewerSelecting([logFile])
                inform("Diagnostics file revealed in Finder",
                       "Drag \(logFile.lastPathComponent) into the email to attach it.")
            }
            NSWorkspace.shared.open(url)
            return
        }

        // 3. Floor: no usable mail client — clipboard.
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("\(FeedbackBody.address)\n\n\(body)", forType: .string)
        if let logFile {
            NSWorkspace.shared.activateFileViewerSelecting([logFile])
        }
        inform("No mail account set up",
               "\(FeedbackBody.address) and the feedback template were copied " +
               "to the clipboard — paste them into webmail or any email app.")
    }

    /// True when the `mailto:` handler is worth opening: any third-party
    /// client. Mail.app reaching tier 2 means it has no account (tier 1
    /// would have handled it otherwise), so its wizard is a dead end.
    static func shouldUseMailto(handlerBundleID: String?) -> Bool {
        guard let handlerBundleID else { return false }
        return handlerBundleID != "com.apple.mail"
    }

    private static func inform(_ message: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.runModal()
    }
}

/// Centered feedback card — icon, title, and message are centered (matching the
/// import notices) with the diagnostics checkbox and Cancel / Compose buttons.
private struct FeedbackNoticeView: View {
    var onCancel: () -> Void
    var onCompose: (_ includeDiagnostics: Bool) -> Void
    @State private var includeDiagnostics = false

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 56, height: 56)
            Text("Send feedback about Sealshot")
                .font(.headline)
                .multilineTextAlignment(.center)
            Text("This composes an email to \(FeedbackBody.address) pre-filled with your app version, edition, and macOS version.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Include recent diagnostics (this session's Sealshot logs)",
                   isOn: $includeDiagnostics)
                .toggleStyle(.checkbox)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
            HStack(spacing: 10) {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Compose") { onCompose(includeDiagnostics) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
            .padding(.top, 6)
        }
        .padding(20)
        .frame(width: 340)
    }
}
