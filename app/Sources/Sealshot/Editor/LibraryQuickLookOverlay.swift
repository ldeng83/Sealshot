import SwiftUI
import AppKit

/// The Quick Look preview content: a light dim + a centered card (media +
/// caption). Hosted inside the screen-sized `QuickLookFloatingPanel`, so it has
/// the modal-overlay feel (no window chrome) yet the card can grow larger than
/// the app window. ⌘+scroll scales the card about the center — always centered,
/// so it never drifts. Space/Esc/arrows are handled by the main window (the
/// panel is non-activating); the content reacts to `viewModel.selection`.
struct QuickLookOverlayContent: View {
    @Bindable var viewModel: LibraryViewModel
    /// Owned by the presenter's coordinator so it survives content rebuilds and
    /// can be torn down when the panel closes.
    let loader: QuickLookPreviewLoader
    /// Persisted: the preview remembers its last zoom across reopens and app
    /// restarts. Clamped to the scale bounds wherever it's read.
    @AppStorage("QuickLookCardScale") private var cardScale: Double = 1.0

    // Card = base fraction of the screen × cardScale, applied UNIFORMLY to both
    // sides. `maxScale` is the largest uniform scale that keeps BOTH dimensions
    // within their caps, so the card grows/stops proportionally — one side never
    // keeps extending after the other has maxed. (The screen terms cancel in the
    // ratios, so these are constants.)
    private static let baseWFrac: CGFloat = 0.42
    private static let baseHFrac: CGFloat = 0.52
    private static let maxWFrac: CGFloat = 0.94
    private static let maxHFrac: CGFloat = 0.88
    private static let minScale: CGFloat = 0.5
    private static let maxScale: CGFloat = min(maxWFrac / baseWFrac, maxHFrac / baseHFrac)

    private var currentItem: LibraryItem? {
        guard let url = viewModel.selection.first else { return nil }
        return viewModel.item(for: url)
    }

    /// ⌘+scroll → grow/shrink the card. Same exponential response/sensitivity as
    /// the editor canvas.
    private func adjustScale(deltaY: CGFloat, precise: Bool) {
        let sensitivity: CGFloat = precise ? 0.002 : 0.035
        let next = clampedScale * exp(deltaY * sensitivity)
        cardScale = Double(min(Self.maxScale, max(Self.minScale, next)))
    }

    /// One click of the −/+ buttons: a fixed exponential step of the same
    /// scale ⌘+scroll drives, so the two controls feel identical.
    private func stepScale(_ direction: CGFloat) {
        let next = clampedScale * exp(direction * 0.14)
        withAnimation(.easeOut(duration: 0.12)) {
            cardScale = Double(min(Self.maxScale, max(Self.minScale, next)))
        }
    }

    /// The stored value bounded to the legal range (a stale/hand-edited
    /// default must not produce a degenerate card).
    private var clampedScale: CGFloat {
        min(Self.maxScale, max(Self.minScale, CGFloat(cardScale)))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Transparent tap-catcher (the dim itself is the window's
                // background, so it never composites over the video surface).
                Color.clear
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { viewModel.closeQuickLook() }

                if let item = currentItem {
                    // Uniform scale on both sides; centered, so scaling never
                    // shifts position and both sides cap together.
                    let cardW = geo.size.width * Self.baseWFrac * clampedScale
                    let cardH = geo.size.height * Self.baseHFrac * clampedScale
                    VStack(spacing: 10) {
                        media(for: item)
                            .frame(width: cardW, height: cardH)
                            .background(Color.black.opacity(0.9))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .shadow(color: .black.opacity(0.5), radius: 26, y: 10)
                        caption(for: item)
                    }
                }
            }
        }
    }

    @ViewBuilder private func media(for item: LibraryItem) -> some View {
        Group {
            switch loader.phase {
            case .loading(let thumb):
                ZStack {
                    if let thumb { Image(nsImage: thumb).resizable().scaledToFit().opacity(0.5) }
                    ProgressView().controlSize(.large).tint(.white)
                }
            case .image(let img):
                QuickLookImageView(image: img, onCommandScroll: adjustScale)
            case .video(let player):
                QuickLookVideoView(player: player, onCommandScroll: adjustScale)
            case .locked:
                message("This item is locked")
            case .failed:
                message("Couldn't load preview")
            }
        }
        // Reload whenever the selected URL changes (arrow navigation).
        .task(id: item.url) {
            await loader.load(url: item.url, isVideo: item.isVideo)
        }
    }

    @ViewBuilder private func caption(for item: LibraryItem) -> some View {
        VStack(spacing: 5) {
            Text(item.displayName)
                .font(.system(size: 13, weight: .semibold))
            Text(captionMeta(for: item))
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.7))
            HStack(spacing: 8) {
                Button {
                    viewModel.activate(item)   // opens editor / plays; dismisses overlay
                } label: {
                    Label("Open in Editor", systemImage: "arrow.up.forward.app")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(.white.opacity(0.16), in: Capsule())
                }
                .buttonStyle(.plain)

                // Click-to-resize: the same card scale ⌘+scroll drives.
                HStack(spacing: 0) {
                    zoomButton("minus.magnifyingglass", "Smaller") { stepScale(-1) }
                        .disabled(clampedScale <= Self.minScale + 0.001)
                    Divider().frame(height: 14).overlay(.white.opacity(0.25))
                    zoomButton("plus.magnifyingglass", "Larger") { stepScale(1) }
                        .disabled(clampedScale >= Self.maxScale - 0.001)
                }
                .background(.white.opacity(0.16), in: Capsule())
            }
            .padding(.top, 2)
            Text("⌘-scroll to resize")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.5))
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.6), radius: 5)
    }

    /// Dimensions + size when the sidebar Info has loaded; else just the file size.
    private func captionMeta(for item: LibraryItem) -> String {
        if let info = viewModel.selectedInfo, info.width > 0 {
            return "\(info.width) × \(info.height) · \(info.sizeDisplay)"
        }
        return ByteCountFormatter.string(fromByteCount: item.fileSize, countStyle: .file)
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(.white.opacity(0.8))
    }

    private func zoomButton(_ symbol: String, _ help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
