import SwiftUI
import AppKit

/// Settings row for the optional on-device enhanced-redaction model.
struct RedactionModelSettingsRow: View {
    @ObservedObject private var manager = RedactionModelManager.shared
    @State private var showRemoveConfirm = false

    var body: some View {
        if !RedactionEngineLoader.isAppleSilicon {
            SettingsRow("Enhanced on-device model", "Requires a Mac with Apple silicon.") { EmptyView() }
        } else {
            SettingsRow("Enhanced on-device model", subtitle) { control }
                .onAppear { manager.refreshState() }
                .confirmationDialog("Remove the enhanced on-device model?",
                                    isPresented: $showRemoveConfirm) {
                    Button("Remove", role: .destructive) { manager.remove() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This deletes the ~400 MB on-device model. Smart Redaction AND Structured Data Extraction fall back to basic detection until you download it again.")
                }
        }
    }

    private var subtitle: String {
        switch manager.state {
        case .notDownloaded: return "Download a ~400 MB on-device model that improves Smart Redaction and Structured Data Extraction — fully local."
        case .downloading, .verifying, .installing: return "Downloading enhanced model…"
        case .ready: return "Downloaded. Smart Redaction and Structured Data Extraction use the enhanced model."
        case .failed(let m): return "Last download failed: \(m). Tap Download to retry."
        }
    }

    @ViewBuilder private var control: some View {
        switch manager.state {
        case .notDownloaded, .failed:
            Button("Download") {
                if let window = NSApp.keyWindow {
                    RedactionModelDownloadSheet.run(on: window) { _ in }
                } else {
                    manager.start()
                }
            }
        case .downloading, .verifying, .installing:
            Button("Cancel") { manager.cancel() }
        case .ready:
            Button("Remove") { showRemoveConfirm = true }
        }
    }
}
