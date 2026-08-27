import SwiftUI

/// Album browser shown when the Library is on the Collections section with no
/// specific collection selected (`section == .collections && collectionSelection
/// == .none`). Renders one tile per `viewModel.sidebarCollections` entry
/// (★ Favorites pinned first) — each with a representative thumbnail, name, and
/// member count — followed by a trailing "New Collection" ＋ tile.
///
/// The create / rename / delete prompts live as `@State` on `LibraryView` (they
/// drive a shared alert there). Rather than duplicate that state, the browser
/// takes closures the host wires to that state — the cleanest way to keep this a
/// standalone file while reusing the existing sidebar prompt/confirm.
struct LibraryCollectionBrowser: View {
    @Bindable var viewModel: LibraryViewModel
    /// Open the create prompt (host sets target=nil, draft="", shows the alert).
    let onNew: () -> Void
    /// Open the rename prompt for a manual collection.
    let onRename: (LibraryViewModel.SidebarCollection) -> Void
    /// Open the delete confirmation for a manual collection.
    let onDelete: (UUID) -> Void
    /// Export the collection as a shareable package.
    let onExport: (UUID) -> Void
    /// Export the Favorites facet as a shareable package.
    let onExportFavorites: () -> Void

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: viewModel.tileWidth), spacing: 16)], spacing: 16) {
                ForEach(viewModel.sidebarCollections) { row in
                    CollectionTile(row: row,
                                   representative: representative(for: row),
                                   thumbnailHeight: LibraryTileSize.height(forWidth: viewModel.tileWidth))
                        .onTapGesture { open(row) }
                        .contextMenu {
                            if row.isFavorites {
                                // Favorites can be exported but not renamed/deleted.
                                if row.count > 0 {
                                    Button("Export Favorites…") { onExportFavorites() }
                                }
                            } else if let id = row.collectionID {
                                // Export only when the collection has members
                                // (spec §5: disabled on an empty collection).
                                if row.count > 0 {
                                    Button("Export Collection…") { onExport(id) }
                                    Divider()
                                }
                                Button("Rename…") { onRename(row) }
                                Button("Delete…", role: .destructive) { onDelete(id) }
                            }
                        }
                }
                NewCollectionTile(thumbnailHeight: LibraryTileSize.height(forWidth: viewModel.tileWidth))
                    .onTapGesture { onNew() }
            }
            .padding(20)
        }
    }

    /// Newest member used for a tile's thumbnail: the newest favorite for the
    /// pinned Favorites tile, else the newest member of the manual collection.
    private func representative(for row: LibraryViewModel.SidebarCollection) -> LibraryItem? {
        if row.isFavorites { return favoriteRepresentative(viewModel.sectionItems) }
        guard let id = row.collectionID else { return nil }
        return representativeMember(viewModel.sectionItems, collectionID: id)
    }

    private func open(_ row: LibraryViewModel.SidebarCollection) {
        if row.isFavorites {
            viewModel.selectFavorites()
        } else if let id = row.collectionID {
            viewModel.selectCollection(id)
        }
    }
}

/// One album tile: representative thumbnail (or a folder/star placeholder when
/// the collection is empty or the thumbnail can't be produced — e.g. a video
/// representative, which `ThumbnailStore` doesn't render here), name, and count.
private struct CollectionTile: View {
    let row: LibraryViewModel.SidebarCollection
    let representative: LibraryItem?
    let thumbnailHeight: CGFloat
    @State private var thumb: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            thumbnail
            HStack(spacing: 4) {
                if row.isFavorites {
                    Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                }
                Text(row.name).font(.caption).lineLimit(1).truncationMode(.middle)
            }
            Text("\(row.count) item\(row.count == 1 ? "" : "s")")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(8)
        .contentShape(Rectangle())
        // Re-load when the representative changes (favorites/members shift),
        // when its file is re-saved (mtime in the key — see LibraryItem), or
        // when the session unlocks and a sealed thumbnail becomes readable.
        .task(id: ThumbnailGeneration.shared.taskID(representative?.thumbnailKey ?? "")) {
            thumb = nil
            guard let item = representative, !item.isVideo else { return }
            thumb = await ThumbnailStore.shared.thumbnail(for: item.url)
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        Group {
            if let thumb {
                Image(nsImage: thumb).resizable().scaledToFit().padding(6)
            } else {
                Image(systemName: row.isFavorites ? "star" : "folder")
                    .font(.largeTitle).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: thumbnailHeight)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: Theme.surfaceColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .stroke(Color(nsColor: Theme.surfaceBorderColor), lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 3, x: 0, y: 1)
    }
}

/// Trailing "New Collection" tile: a dashed placeholder with a plus glyph.
private struct NewCollectionTile: View {
    let thumbnailHeight: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Image(systemName: "plus").font(.largeTitle).foregroundStyle(.secondary)
            }
            .frame(height: thumbnailHeight)
            .frame(maxWidth: .infinity)
            .background(Color(nsColor: Theme.surfaceColor).opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color(nsColor: Theme.surfaceBorderColor),
                              style: StrokeStyle(lineWidth: 1, dash: [6, 4])))
            Text("New Collection").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(" ").font(.caption2)
        }
        .padding(8)
        .contentShape(Rectangle())
        .help("Create a new collection")
    }
}
