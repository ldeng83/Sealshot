import AppKit

/// One alert, shown at launch when the previous session left a stale marker
/// AND a matching macOS crash report exists. Pure presentation: nothing is
/// collected or sent automatically — "Show Crash Report" only reveals the
/// `.ips` file in Finder so the tester can email it themselves.
@MainActor
enum CrashNoticePresenter {

    static func present(reportURL: URL) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Sealshot quit unexpectedly last time."
        alert.informativeText = """
            Would you mind sharing the crash report? Nothing is sent \
            automatically — the report stays on your Mac until you email it.

            Send to: \(FeedbackBody.address)
            """
        // Affirmative first (= default), unlike the delete alert which puts
        // Cancel first: revealing a file is non-destructive, so Enter may
        // safely trigger it.
        alert.addButton(withTitle: "Show Crash Report")
        alert.addButton(withTitle: "Not Now")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([reportURL])
        }
    }
}
