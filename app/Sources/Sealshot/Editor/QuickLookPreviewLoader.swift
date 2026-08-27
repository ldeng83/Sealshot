import SwiftUI
import AppKit
import AVKit

/// Loads a single Library item for the Quick Look overlay: shows the cached
/// thumbnail immediately, then swaps in the full-resolution image (capped to a
/// safe display size) or a playable AVPlayer. Everything is decrypted in memory;
/// no plaintext is written to disk. A monotonically increasing token makes the
/// latest `load` win, so fast arrow-navigation never shows a stale result.
@MainActor
@Observable
final class QuickLookPreviewLoader {
    enum Phase {
        case loading(NSImage?)   // associated thumbnail shown behind the spinner
        case image(NSImage)
        case video(AVPlayer)
        case locked
        case failed
    }

    private(set) var phase: Phase = .loading(nil)
    private var token = 0
    /// Retained so the encrypted-video decrypt stream stays alive while playing.
    private var sealedPlayer: SealedRecordingPlayer?
    /// Resource loader for a PLAINTEXT payload inside a container — held
    /// weakly by AVFoundation, so the preview owns it for the player's life.
    private var containerLoader: AnyObject?
    /// Fires when the previewed video plays to the end; we rewind to the start
    /// so the timeline resets and Space plays it again (Finder-preview behavior).
    private var endObserver: NSObjectProtocol?

    private static let maxDisplayPixel: CGFloat = 4096

    func load(url: URL, isVideo: Bool) async {
        token &+= 1
        let myToken = token
        teardownPlayer()

        // 1. Instant: cached thumbnail behind a spinner.
        let thumb = await ThumbnailStore.shared.thumbnail(for: url)
        guard myToken == token else { return }
        phase = .loading(thumb)

        // Locked-package guard: a visible thumbnail normally implies an unlocked
        // session, but be explicit.
        let crypto = SealPackageCryptoContext.current()
        if SealPackageCrypter.isLocked(url) && crypto.identity == nil {
            phase = .locked
            return
        }

        if isVideo {
            // A recording saved without the package wrapper is an ordinary
            // movie file — AVPlayer opens it directly. It must be handled
            // BEFORE VideoSealPackageIO.read, which has no package to read here
            // and would throw straight to .failed, leaving Quick Look unable to
            // preview a perfectly playable file.
            if plainMovieExtensions.contains(url.pathExtension.lowercased()) {
                let player = AVPlayer(playerItem: AVPlayerItem(url: url))
                guard myToken == token else { teardownPlayer(); return }
                observeEnd(of: player)
                phase = .video(player)
                return
            }
            do {
                let contents = try VideoSealPackageIO.read(at: url, crypto: crypto)
                let player: AVPlayer
                if let key = contents.key {
                    let wrapper = try SealedRecordingPlayer(payload: contents.payload, key: key)
                    sealedPlayer = wrapper
                    player = wrapper.player
                } else {
                    let built = contents.plaintextPlaybackAsset()
                    // The loader is held weakly; keep it alive with the player.
                    containerLoader = built.retain
                    player = AVPlayer(playerItem: AVPlayerItem(asset: built.asset))
                }
                guard myToken == token else { teardownPlayer(); return }
                observeEnd(of: player)
                phase = .video(player)
            } catch {
                guard myToken == token else { return }
                phase = SealPackageCrypter.isLocked(url) ? .locked : .failed
            }
            return
        }

        // 2. Image: decrypt + downsample off-main (never the @MainActor
        //    readSealPackage), then swap in on main.
        let maxPixel = Self.maxDisplayPixel
        let decoded: NSImage? = await Task.detached(priority: .userInitiated) {
            guard let image = previewCompositeImage(for: url, crypto: crypto, maxPixel: maxPixel)
            else { return nil }
            // Bake in the focus indicator when the capture focuses on a
            // sub-region (dim exterior + viewfinder bracket, like the editor).
            if let geo = previewFocusGeometry(for: url, crypto: crypto),
               let normalized = FocusPreviewIndicator.normalizedFocus(
                    focus: geo.focus, visibleSize: geo.visibleSize) {
                return FocusPreviewIndicator.imageWithFocusIndicator(image, normalized: normalized)
            }
            return image
        }.value
        guard myToken == token else { return }
        if let decoded {
            phase = .image(decoded)
        } else {
            phase = SealPackageCrypter.isLocked(url) ? .locked : .failed
        }
    }

    /// Space in the Library while previewing a VIDEO toggles playback instead
    /// of dismissing (Finder Quick Look behavior). Returns whether it handled
    /// the key — false for images/loading, where the caller keeps the
    /// open/close toggle.
    func togglePlayPause() -> Bool {
        guard case .video(let player) = phase else { return false }
        if player.timeControlStatus == .playing { player.pause() } else { player.play() }
        return true
    }

    /// Called when the overlay closes. Stops playback and drops the decrypt stream.
    func teardown() {
        token &+= 1
        teardownPlayer()
        phase = .loading(nil)
    }

    /// Rewind to the start when the video finishes, so the timeline is back at
    /// the beginning and pressing Space plays it again (rather than sitting dead
    /// at the last frame). Observer is per-item and cleared in `teardownPlayer`.
    private func observeEnd(of player: AVPlayer) {
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem, queue: .main) { [weak player] _ in
            player?.seek(to: .zero)
        }
    }

    private func teardownPlayer() {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        if case .video(let p) = phase { p.pause() }
        sealedPlayer = nil
        containerLoader = nil
    }
}
