import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Grouped extracted-data results. Tables render as cards with Copy as TSV /
/// Save as CSV…; other groups render as monospaced text with Copy.
struct StructuredExtractionSheetView: View {
    let tables: [StructuredTable]
    let groups: [ExtractedGroup]
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Extracted Structured Data").font(.headline).padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(tables.enumerated()), id: \.offset) { idx, table in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Table \(idx + 1)").font(.subheadline.bold())
                                Spacer()
                                Button("Copy as TSV") { copy(TableExport.tsv(table)) }
                                    .controlSize(.small)
                                Button("Save as CSV…") { saveCSV(table, index: idx + 1) }
                                    .controlSize(.small)
                            }
                            Text(StructuredExtractionResult.markdownTable(table))
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(group.title).font(.subheadline.bold())
                                Spacer()
                                Button("Copy") { copy(group.body) }
                                    .controlSize(.small)
                            }
                            Text(group.body)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(16)
            }
            Divider()
            HStack {
                Button("Copy All") { copy(StructuredExtractionResult.copyAllText(groups)) }
                    .disabled(groups.isEmpty)
                Spacer()
                Button("Close", action: onClose).keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 480, height: 420)
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    private func saveCSV(_ table: StructuredTable, index: Int) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "table-\(index).csv"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try TableExport.csv(table).write(to: url, atomically: true, encoding: .utf8)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Save CSV"
                alert.informativeText = "Couldn't save the CSV file."
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }
}
