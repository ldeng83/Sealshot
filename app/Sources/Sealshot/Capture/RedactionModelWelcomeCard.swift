import SwiftUI
import AppKit

/// Welcome-tour card offering the enhanced on-device redaction model.
struct RedactionModelWelcomeCard: View {
    @ObservedObject private var manager = RedactionModelManager.shared

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 18))
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text("Enhanced model (~400 MB)").font(.callout.weight(.semibold))
                Text("On-device AI that improves Smart Redaction and Structured Data Extraction — fully local.")
                    .font(.caption).foregroundStyle(.secondary)
                control
            }
            Spacer(minLength: 8)
        }
        .cardRow()
        .onAppear { manager.refreshState() }
    }

    @ViewBuilder private var control: some View {
        if !RedactionEngineLoader.isAppleSilicon {
            Text("Requires a Mac with Apple silicon.")
                .font(.caption).foregroundStyle(.secondary)
        } else {
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
                ProgressView().controlSize(.small)
            case .ready:
                Label("Downloaded", systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
