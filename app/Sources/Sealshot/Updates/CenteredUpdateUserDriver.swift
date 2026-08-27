#if canImport(Sparkle)
import AppKit
import SwiftUI
import Sparkle

/// A Sparkle user driver that behaves like the stock `SPUStandardUserDriver`
/// for the whole update-available → download → install flow, but owns the
/// user-initiated *check* UI and the "no update found" / error popups so they
/// use our centered-icon cards. Rationale: on macOS 26 the system `NSAlert`
/// Sparkle uses pins the app icon to the top-LEFT, which reads as inconsistent
/// next to the centered-icon About panel.
///
/// We present our OWN "Checking for Updates…" card (rather than forwarding
/// `showUserInitiatedUpdateCheck` to the inner driver) because the stock driver
/// only dismisses its progress window as a side effect of showing its own
/// terminal alert — which we replace — so its window would otherwise linger
/// behind our result card. Everything else (download progress, permission
/// prompts, install, relaunch) forwards to the inner standard driver unchanged.
@MainActor
final class CenteredUpdateUserDriver: NSObject, SPUUserDriver {
    private let inner: SPUStandardUserDriver
    /// Set when the user cancels our "Checking…" card, so a follow-up
    /// `showUpdaterError` (Sparkle reporting the cancellation) is swallowed
    /// instead of surfacing an error card for a deliberate user action.
    private var didCancelCheck = false

    init(hostBundle: Bundle, delegate: SPUStandardUserDriverDelegate?) {
        inner = SPUStandardUserDriver(hostBundle: hostBundle, delegate: delegate)
    }

    // MARK: - Owned UI (our centered cards)

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        didCancelCheck = false
        UpdateNotice.showChecking(onCancel: { [weak self] in
            self?.didCancelCheck = true
            UpdateNotice.dismiss()
            cancellation()
        })
    }

    func showUpdateNotFoundWithError(_ error: any Error) async {
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Sealshot"
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            UpdateNotice.showResult(
                title: "You're up to date!",
                message: "\(name) \(short) is currently the newest version available.",
                onAcknowledge: { cont.resume() })
        }
    }

    func showUpdaterError(_ error: any Error) async {
        if didCancelCheck {
            didCancelCheck = false
            UpdateNotice.dismiss()
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            UpdateNotice.showResult(
                title: "Update Error",
                message: error.localizedDescription,
                onAcknowledge: { cont.resume() })
        }
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) {
        // Dismiss our "Checking…" card, then hand the update-available dialog
        // (and the rest of the download/install flow) to the standard driver.
        UpdateNotice.dismiss()
        inner.showUpdateFound(with: appcastItem, state: state, reply: reply)
    }

    // MARK: - Forwarded to the standard driver, unchanged

    func show(_ request: SPUUpdatePermissionRequest,
              reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        inner.show(request, reply: reply)
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        inner.showUpdateReleaseNotes(with: downloadData)
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
        inner.showUpdateReleaseNotesFailedToDownloadWithError(error)
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        inner.showDownloadInitiated(cancellation: cancellation)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        inner.showDownloadDidReceiveExpectedContentLength(expectedContentLength)
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        inner.showDownloadDidReceiveData(ofLength: length)
    }

    func showDownloadDidStartExtractingUpdate() {
        inner.showDownloadDidStartExtractingUpdate()
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        inner.showExtractionReceivedProgress(progress)
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        inner.showReady(toInstallAndRelaunch: reply)
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                              retryTerminatingApplication: @escaping () -> Void) {
        inner.showInstallingUpdate(withApplicationTerminated: applicationTerminated,
                                   retryTerminatingApplication: retryTerminatingApplication)
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool) async {
        await inner.showUpdateInstalledAndRelaunched(relaunched)
    }

    func showUpdateInFocus() {
        inner.showUpdateInFocus()
    }

    func dismissUpdateInstallation() {
        inner.dismissUpdateInstallation()
    }
}

/// Presents the update cards (checking / result) as a small centered titled
/// panel, one at a time. `present` closes any prior card first, so the
/// "Checking…" card is replaced in place by the result — never both on screen.
@MainActor
enum UpdateNotice {
    /// Strong ref so the shown window isn't deallocated while visible.
    private static var window: NSWindow?

    static func showChecking(onCancel: @escaping () -> Void) {
        present(UpdateCheckingView(onCancel: onCancel))
    }

    static func showResult(title: String, message: String, onAcknowledge: @escaping () -> Void) {
        present(ImportNoticeView(title: title, message: message) {
            dismiss()
            onAcknowledge()
        })
    }

    static func dismiss() {
        window?.close()
        window = nil
    }

    private static func present(_ view: some View) {
        dismiss()
        let win = NSWindow(contentViewController: NSHostingController(rootView: view))
        win.styleMask = [.titled]
        win.isReleasedWhenClosed = false
        win.level = .modalPanel
        window = win
        win.center()
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }
}

/// Centered "Checking for Updates…" card with an indeterminate bar and Cancel,
/// matching the result card's icon-on-top layout.
private struct UpdateCheckingView: View {
    var onCancel: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 56, height: 56)
            Text("Checking for Updates…")
                .font(.headline)
            ProgressView()
                .progressViewStyle(.linear)
                .frame(width: 200)
            Button("Cancel", action: onCancel)
                .controlSize(.large)
                .padding(.top, 2)
        }
        .padding(20)
        .frame(width: 280)
    }
}
#endif
