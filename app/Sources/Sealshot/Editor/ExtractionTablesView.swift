import SwiftUI

/// The "Table" view of the Extract result — detected tables as bordered grids.
struct ExtractionTablesView: View {
    let tables: [StructuredTable]

    var body: some View {
        if tables.isEmpty {
            Text("No tables found")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(Array(tables.enumerated()), id: \.offset) { _, t in
                        grid(t)
                    }
                }
                .padding()
            }
        }
    }

    @ViewBuilder private func grid(_ t: StructuredTable) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(Array(t.headers.enumerated()), id: \.offset) { _, h in cell(h, bold: true) }
            }
            ForEach(Array(t.rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, c in cell(c, bold: false) }
                }
            }
        }
        .border(Color.secondary.opacity(0.35))
    }

    private func cell(_ s: String, bold: Bool) -> some View {
        Text(s)
            .font(.system(size: 12, weight: bold ? .semibold : .regular))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(minWidth: 60, alignment: .leading)
            .border(Color.secondary.opacity(0.2))
    }
}
