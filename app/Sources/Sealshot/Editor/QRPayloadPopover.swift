import AppKit

/// A transient popover showing a detected QR/barcode payload: a titled header
/// with a content-type badge, the payload in a recessed monospace field, and
/// Open (for URLs) / Copy actions. Anchored to the code's rect in the canvas.
@MainActor
enum QRPayloadPopover {
    private static var current: NSPopover?
    /// Width of the recessed payload field; drives the whole popover width.
    private static let fieldWidth: CGFloat = 252
    private static let hInset: CGFloat = 20

    static func dismiss() { current?.close(); current = nil }

    static func present(for code: DetectedBarcode, from view: NSView, rect: NSRect) {
        dismiss()
        let kind = contentKind(for: code)

        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.distribution = .fill
        container.spacing = 10
        // Horizontal margin is applied via the host pin constants below, NOT
        // edgeInsets — a VERTICAL NSStackView ignores cross-axis (left/right)
        // edgeInsets, so those were silently doing nothing.
        container.edgeInsets = NSEdgeInsets(top: 13, left: 0, bottom: 12, right: 0)
        container.translatesAutoresizingMaskIntoConstraints = false

        // Header: symbology title on the left, content-type badge on the right.
        let title = NSTextField(labelWithString: code.symbologyLabel)
        title.font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        title.textColor = .labelColor
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)   // stretch → pushes badge right
        let header = NSStackView(views: [title, makeBadge(kind.badge)])
        header.orientation = .horizontal
        header.alignment = .firstBaseline
        header.distribution = .fill
        container.addArrangedSubview(header)

        // Recessed monospace payload field.
        let field = makePayloadField(code.payload)
        container.addArrangedSubview(field)

        // Actions: filled primary Open (URLs only) + ghost Copy. When there's no
        // Open, Copy becomes the primary (default) button.
        let copy = NSButton(title: "Copy", target: CopyHandler.shared, action: #selector(CopyHandler.copy(_:)))
        copy.bezelStyle = .rounded
        CopyHandler.shared.payload = code.payload

        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.distribution = .fill
        actions.spacing = 7
        if let url = code.openableURL {
            let open = NSButton(title: kind.openTitle, target: OpenHandler.shared, action: #selector(OpenHandler.open(_:)))
            open.bezelStyle = .rounded
            open.keyEquivalent = "\r"                      // default → filled accent, tracks system accent
            open.setContentHuggingPriority(.defaultLow, for: .horizontal)   // Open stretches wide
            OpenHandler.shared.url = url
            actions.addArrangedSubview(open)
            actions.addArrangedSubview(copy)
        } else {
            copy.keyEquivalent = "\r"                      // sole action → make it the filled primary
            copy.setContentHuggingPriority(.defaultLow, for: .horizontal)
            actions.addArrangedSubview(copy)
        }
        container.addArrangedSubview(actions)

        // Pin header, field, and actions to the container's content width so the
        // whole popover is exactly `fieldWidth` wide (the field's own width
        // constraint drives it; the others stretch to match).
        NSLayoutConstraint.activate([
            header.widthAnchor.constraint(equalTo: field.widthAnchor),
            actions.widthAnchor.constraint(equalTo: field.widthAnchor),
        ])

        let host = NSView()
        host.addSubview(container)
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: hInset),
            container.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -hInset),
            container.topAnchor.constraint(equalTo: host.topAnchor),
            container.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        let vc = NSViewController()
        vc.view = host

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = vc
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
        current = popover
    }

    // MARK: - Pieces

    /// The recessed field: a rounded, hairline-bordered box (matching the app's
    /// list-table surface) holding the selectable monospace payload.
    private static func makePayloadField(_ payload: String) -> NSView {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = Theme.listTableColor.cgColor
        box.layer?.cornerRadius = 8
        box.layer?.borderWidth = 1
        box.layer?.borderColor = Theme.surfaceBorderColor.cgColor

        let label = NSTextField(wrappingLabelWithString: payload)
        label.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        label.textColor = .labelColor
        label.isSelectable = true
        label.lineBreakMode = .byCharWrapping                 // URLs have no spaces → wrap on chars
        label.maximumNumberOfLines = 5
        label.preferredMaxLayoutWidth = fieldWidth - 18
        label.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(label)
        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalToConstant: fieldWidth),
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 9),
            label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -9),
            label.topAnchor.constraint(equalTo: box.topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -8),
        ])
        return box
    }

    /// A small uppercase content-type pill tinted with the app accent.
    private static func makeBadge(_ text: String) -> NSView {
        let pill = NSView()
        pill.wantsLayer = true
        pill.layer?.backgroundColor = Theme.accentColor.withAlphaComponent(0.15).cgColor
        pill.layer?.cornerRadius = 8
        pill.setContentHuggingPriority(.required, for: .horizontal)

        let label = NSTextField(labelWithString: text.uppercased())
        label.font = NSFont.systemFont(ofSize: 9.5, weight: .semibold)
        label.textColor = Theme.accentColor
        label.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -7),
            label.topAnchor.constraint(equalTo: pill.topAnchor, constant: 2.5),
            label.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -2.5),
        ])
        return pill
    }

    /// Badge label + Open-button title derived from the payload's scheme.
    private static func contentKind(for code: DetectedBarcode) -> (badge: String, openTitle: String) {
        let s = code.payload.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.uppercased().hasPrefix("WIFI:") { return ("Wi-Fi", "Open") }
        switch code.openableURL?.scheme?.lowercased() {
        case "mailto": return ("Email", "Compose")
        case "tel":    return ("Phone", "Call")
        case "http", "https": return ("Link", "Open Link")
        default:       return ("Text", "Open")
        }
    }

    /// Tiny target objects so the buttons act without a custom NSViewController.
    @MainActor private final class OpenHandler: NSObject {
        static let shared = OpenHandler(); var url: URL?
        @objc func open(_ sender: Any?) { if let url { NSWorkspace.shared.open(url) }; QRPayloadPopover.dismiss() }
    }
    @MainActor private final class CopyHandler: NSObject {
        static let shared = CopyHandler(); var payload: String = ""
        @objc func copy(_ sender: Any?) {
            let pb = NSPasteboard.general; pb.clearContents(); pb.setString(payload, forType: .string)
            QRPayloadPopover.dismiss()
        }
    }
}
