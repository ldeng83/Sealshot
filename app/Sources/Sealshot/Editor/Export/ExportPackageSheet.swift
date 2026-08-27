import AppKit
import SwiftUI

struct ExportPackageSheet: View {
    @Bindable var model: ExportPackageModel
    @State private var justCopied = false
    var onCancel: () -> Void
    var onExport: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export to Package")
                .font(.headline)

            itemsCard
            formatCard
            if model.encryptionEnabled { passphraseCard }
            optionsCard

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Export…", action: onExport)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canExport)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var itemsCard: some View {
        card("Items") {
            let images = model.sources.filter { !$0.isVideo }.count
            let videos = model.sources.filter { $0.isVideo }.count
            Text("\(model.sources.count) item\(model.sources.count == 1 ? "" : "s")"
                 + (videos > 0 ? "  ·  \(images) image\(images == 1 ? "" : "s"), \(videos) video\(videos == 1 ? "" : "s")" : ""))
                .foregroundStyle(.secondary)
            let rowHeight: CGFloat = 26
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.sources, id: \.url) { s in
                        HStack(spacing: 8) {
                            Image(systemName: s.isVideo ? "film" : "photo")
                                .foregroundStyle(.secondary)
                            Text(s.displayName).lineLimit(1)
                        }
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            // Size to content, but cap tall lists so the sheet never overflows the window.
            .frame(height: min(CGFloat(model.sources.count) * rowHeight, 200))
        }
    }

    private var formatCard: some View {
        card("Format") {
            Picker("Format", selection: $model.format) {
                Text(".sealshare (Sealshot)").tag(PackageFormat.sealshare)
                Text(".zip (any app)").tag(PackageFormat.zip)
            }
            Toggle("Encrypt with a passcode", isOn: $model.encryptionEnabled)
        }
    }

    private var passphraseCard: some View {
        card("Passcode") {
            Text(model.generatedPassphrase)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.generatedPassphrase, forType: .string)
                    model.markGeneratedCopied()
                    justCopied = true
                    Task {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        justCopied = false
                    }
                } label: {
                    if justCopied {
                        Label("Copied", systemImage: "checkmark").foregroundStyle(.green)
                    } else {
                        Text("Copy")
                    }
                }
                Button("Regenerate") { model.regenerate(); justCopied = false }
                Spacer()
            }
            // Directly under the buttons it names, not stranded below the
            // warning card: this is the instruction for the Copy button, and
            // the answer to "why is Export greyed out?".
            if !model.hasCopiedGenerated {
                Text("Export stays disabled until you copy the passcode.")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("This passcode is the only key — copy it and send it to the recipient separately. It can't be recovered if lost.")
                    .font(.callout).fontWeight(.medium)
                    .fixedSize(horizontal: false, vertical: true)   // wrap, don't truncate
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.orange.opacity(0.12))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.5), lineWidth: 1))
            )
            if model.format == .sealshare { TextField("Hint (optional)", text: $model.hint) }
        }
    }

    private var optionsCard: some View {
        card("Options") {
            if model.format == .sealshare {
                TextField("Note (optional)", text: $model.note)
                Toggle("Set an expiry date", isOn: $model.expiresEnabled)
                if model.expiresEnabled {
                    // Ranged from tomorrow: today and earlier grey out in the
                    // calendar, and the range also clamps the date field, which
                    // accepts typing on macOS. `resolvedExpiry` re-checks it
                    // anyway — a sheet left open past midnight outlives whatever
                    // floor was correct when it opened.
                    DatePicker("Expires", selection: $model.expiresAt,
                               in: model.minimumSelectableExpiry...,
                               displayedComponents: [.date])
                    Text("Expires at the end of that day. Advisory only — recipients are warned, but expiry isn't enforced.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle("Include original un-redacted capture", isOn: $model.includeOriginal)
            if model.includeOriginal {
                Text("Warning: the original, un-redacted image will be included in the package.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private func card<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.caption).foregroundStyle(.secondary)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: Theme.surfaceColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: Theme.surfaceBorderColor), lineWidth: 1))
    }
}
