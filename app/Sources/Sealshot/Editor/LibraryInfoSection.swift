import SwiftUI

// MARK: - FlowLayout

/// A Layout-conforming container that wraps its children to new rows when they
/// overflow the available width, like word-wrapping. Requires macOS 13+
/// (Layout protocol), which is below the app's macOS 14.0 floor.
struct FlowLayout: Layout {
    var spacing: CGFloat = 5

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.maxX
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > bounds.minX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
    }
}

// MARK: - LibraryTagChips

/// Read-only wrapping chip row for a capture's tags.
struct LibraryTagChips: View {
    let tags: [String]
    var body: some View {
        FlowLayout(spacing: 5) {
            ForEach(tags, id: \.self) { t in
                Text(t).font(.system(size: 12))
                    .padding(.horizontal, 9).padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.18), in: Capsule())
            }
        }
    }
}

// MARK: - LibraryEditableTagChips

/// Editable chip row: each chip shows an ✕ remove button, and a TextField
/// below lets the user add a new tag (submitted with Return).
struct LibraryEditableTagChips: View {
    @Bindable var viewModel: LibraryViewModel
    let url: URL
    let tags: [String]
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool
    /// Set on submit so focus is re-asserted after the ~180 ms metadata reload
    /// re-renders this row with the new tag (that re-render drops focus).
    @State private var refocusAfterAdd = false

    var body: some View {
        FlowLayout(spacing: 5) {
            ForEach(tags, id: \.self) { t in
                HStack(spacing: 4) {
                    Text(t).font(.system(size: 12))
                    Button {
                        viewModel.removeTag(t, from: url)
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 8))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(Color.secondary.opacity(0.18), in: Capsule())
            }
        }
        TextField("Add tag…", text: $draft)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12))
            .focused($fieldFocused)
            .onSubmit {
                viewModel.addTag(draft, to: url)
                draft = ""
                // Keep focus so the user can type another tag right away (Return
                // resigns the field; the reload below re-renders and drops it too).
                fieldFocused = true
                refocusAfterAdd = true
            }
            // The metadata reload swaps in the new tag list ~180 ms later, which
            // re-renders this row and steals focus — re-assert it once that lands.
            .onChange(of: tags) {
                if refocusAfterAdd {
                    refocusAfterAdd = false
                    fieldFocused = true
                }
            }
            // The rounded bezel draws slightly outside its frame; inset it a
            // hair so the left/right edges aren't clipped by the ScrollView.
            .padding(.horizontal, 2)
    }
}

// MARK: - LibraryInfoSection

/// Context-aware sidebar info section with three states:
/// 1. **Single selection** — per-file Info: name, summary, tags, detail rows.
/// 2. **Multi-selection** — aggregate: count, images/videos, total size, range.
/// 3. **No selection** — library/results aggregate with the same shape.
///
/// Read-only in Task 4; tag/favorite editing is added in Task 5.
struct LibraryInfoSection: View {
    @Bindable var viewModel: LibraryViewModel

    /// True when any active filter narrows the visible set below the section total.
    private var isNarrowed: Bool {
        !viewModel.searchText.isEmpty
            || viewModel.dateFilter != .none
            || viewModel.fileTypeFilter != .all
            || viewModel.collectionSelection != .none   // `.none` is the neutral/all case
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().padding(.vertical, 4)
            if viewModel.selection.count == 1,
               let info = viewModel.selectedInfo,
               let url = viewModel.selection.first {
                itemView(info, url: url)
            } else if viewModel.selection.count == 1 {
                // Info is being loaded (debounced). Show a lightweight placeholder
                // so switching items never flashes the library-aggregate view.
                ProgressView().padding(.top, 4)
            } else if viewModel.selection.count >= 2 {
                aggregateView(
                    LibraryInfoAggregate.make(
                        visible: viewModel.selection.compactMap { viewModel.item(for: $0) },
                        sectionTotal: viewModel.sectionTotalCount,
                        isNarrowed: false
                    ),
                    selecting: true
                )
            } else {
                aggregateView(
                    LibraryInfoAggregate.make(
                        visible: viewModel.items,
                        sectionTotal: viewModel.sectionTotalCount,
                        isNarrowed: isNarrowed
                    ),
                    selecting: false
                )
            }
        }
        .padding(.horizontal, 4)   // a little more breathing room on both sides
    }

    // MARK: Private helpers

    @ViewBuilder private func header(_ t: String) -> some View {
        // Match the editor Info panel's section headers (Theme.sectionHeaderFont
        // 10pt medium + kern 1.2, uppercased, secondary).
        Text(t.uppercased())
            .font(.system(size: 10, weight: .medium))
            .tracking(1.2)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
    }

    /// Editable for .seal packages. Deliberately NOT gated on
    /// `SealPackageCrypter.isLocked` — that only means "encrypted at rest"
    /// and is true for every package while encryption is on; with the session
    /// unlocked, writes work. A genuinely locked session makes the write throw
    /// and be skipped (the addTag/favorite convention).
    private func isEditable(_ url: URL) -> Bool {
        url.pathExtension == "seal"
    }

    @ViewBuilder private func itemView(_ info: LibraryItemInfo, url: URL) -> some View {
        header("Name")
        HStack(alignment: .top) {
            if isEditable(url) {
                // The editor Info panel's in-place rename view (caret lands
                // where clicked, ↩ commits, Esc cancels) — one shared
                // implementation for both panels.
                LibraryInlineNameEditor(url: url, displayName: info.name) { name in
                    viewModel.setUserTitle(url, to: name)
                }
            } else {
                Text(info.name)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button {
                viewModel.toggleFavorite(url)
            } label: {
                Image(systemName: info.isFavorite ? "star.fill" : "star")
                    .foregroundStyle(info.isFavorite ? .yellow : .secondary)
            }
            .buttonStyle(.plain)
        }
        Divider().padding(.vertical, 4)
        // Editable items always get the Summary section (with the editor's
        // "click to write one" placeholder); locked ones keep the old
        // only-when-present behavior.
        if isEditable(url) || (info.summary?.isEmpty == false) || !info.smartKeywords.isEmpty {
            header("Summary")
            summaryBody(info, url: url)
            if !info.smartKeywords.isEmpty {
                Text("Keywords: " + info.smartKeywords.joined(separator: ", "))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineSpacing(4)
            }
            Divider().padding(.vertical, 4)
        }
        header("Tags")
        LibraryEditableTagChips(viewModel: viewModel, url: url, tags: info.tags)
        Divider().padding(.vertical, 4)
        header("Details")
        // "Content type" is dropped to match the editor Info panel (which omits it).
        ForEach(info.detailRows.filter { $0.label != "Content type" }, id: \.label) { r in
            HStack {
                Text(r.label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                Spacer()
                Text(r.value)
                    .font(.system(size: 12, weight: .medium))
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    /// The summary text: for editable items, the editor Info panel's in-place
    /// click-to-edit view (⌘↩/click-away commits, Esc cancels, context-menu
    /// revert; it persists the userSummary override itself and notifies —
    /// the view model refreshes via .captureMetadataDidChange). Locked items
    /// keep the plain read-only text.
    @ViewBuilder private func summaryBody(_ info: LibraryItemInfo, url: URL) -> some View {
        if isEditable(url) {
            LibraryInlineSummaryEditor(url: url,
                                       generated: info.generatedSummary,
                                       userSummary: info.userSummary,
                                       tags: info.tags)
        } else if let s = info.summary, !s.isEmpty {
            // Match the editor summary's 1.30 line-height (SummaryLayout).
            Text(s).font(.system(size: 12)).foregroundStyle(.secondary)
                .lineSpacing(4)
        }
    }

    @ViewBuilder private func aggregateView(
        _ a: LibraryInfoAggregate, selecting: Bool
    ) -> some View {
        if selecting {
            Text("\(a.visibleCount) selected").font(.callout).fontWeight(.semibold)
        } else if a.isNarrowed {
            Text("\(a.visibleCount) of \(a.sectionTotal)").font(.callout).fontWeight(.semibold)
        } else {
            Text("\(a.sectionTotal) items").font(.callout).fontWeight(.semibold)
        }
        row("Images", "\(a.imageCount)")
        row("Videos", "\(a.videoCount)")
        row("Total size", ByteCountFormatter.string(fromByteCount: a.totalSize, countStyle: .file))
        if !selecting, let o = a.oldest, let n = a.newest {
            row("Range",
                "\(o.formatted(.dateTime.month().day())) – \(n.formatted(.dateTime.month().day()))")
        }
    }

    @ViewBuilder private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
            Spacer()
            Text(v)
                .font(.system(size: 12, weight: .medium))
        }
    }
}
