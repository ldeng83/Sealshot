import AppKit

/// Placeholder view shown in the canvas slot when the editor has no
/// image. Centered SF Symbol + headline + hint, on top of the existing
/// hex backdrop. Accepts PNG and .seal drops; calls `onDrop` with the
/// resolved file URL.
@MainActor
final class EmptyCanvasView: NSView {

    var onDrop: ((URL) -> Void)?
    var onNewCanvas: (() -> Void)?
    var onImport: (() -> Void)?

    init() {
        super.init(frame: .zero)
        setupLayout()
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not implemented") }

    private func setupLayout() {
        let icon = NSImageView()
        let cfg = NSImage.SymbolConfiguration(pointSize: 48, weight: .regular)
        icon.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        icon.contentTintColor = .tertiaryLabelColor

        let headline = NSTextField(labelWithString: "No image open")
        headline.font = .systemFont(ofSize: 13, weight: .regular)
        headline.textColor = .secondaryLabelColor
        headline.alignment = .center

        let hint = NSTextField(labelWithString: "⌘⇧A to capture  ·  drag a file here")
        hint.font = .systemFont(ofSize: 11, weight: .regular)
        hint.textColor = .tertiaryLabelColor
        hint.alignment = .center

        // Discoverable counterparts of File → New Canvas / Import to Library….
        let newButton = NSButton(title: "New Canvas", target: self,
                                 action: #selector(newCanvasClicked))
        let importButton = NSButton(title: "Import…", target: self,
                                    action: #selector(importClicked))
        for button in [newButton, importButton] {
            button.bezelStyle = .rounded
            button.controlSize = .regular
        }
        let buttons = NSStackView(views: [newButton, importButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [icon, headline, hint, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.setCustomSpacing(14, after: hint)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @objc private func newCanvasClicked() { onNewCanvas?() }
    @objc private func importClicked() { onImport?() }

    // MARK: - Drag and drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        acceptedURL(from: sender) != nil ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = acceptedURL(from: sender) else { return false }
        onDrop?(url)
        return true
    }

    /// The importer's raster formats (which load through the same generic
    /// ImageIO path in EditorController — annotations/crop metadata silently
    /// absent, matching the "raw PNG without our XMP" fallback) plus Sealshot's
    /// own packages. PDF is excluded: the empty-canvas drop path has no
    /// rasterizer (PDF is import-only).
    private static let acceptedExtensions: Set<String> =
        ImageImporter.importableExtensions.subtracting(["pdf"]).union(["seal", "sealshare"])

    private func acceptedURL(from sender: NSDraggingInfo) -> URL? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
        return urls.first { Self.acceptedExtensions.contains($0.pathExtension.lowercased()) }
    }
}
