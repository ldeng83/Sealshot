import AppKit

/// Small floating panel shown while an import plan executes: determinate
/// bar, "Importing N of M — file" label, Cancel button. Cancellation is
/// cooperative — the executor checks between units, so the panel stays up
/// until the current unit finishes.
@MainActor
final class ImportProgressPanel {

    var onCancel: (() -> Void)?

    private let panel: NSPanel
    private let bar = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "Preparing import…")

    init(totalUnits: Int) {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 92),
            styleMask: [.titled, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.title = "Importing"
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true

        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = Double(totalUnits)
        bar.doubleValue = 0

        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle

        let cancel = NSButton(title: "Cancel", target: self,
                              action: #selector(cancelClicked))
        cancel.bezelStyle = .rounded

        let stack = NSStackView(views: [label, bar, cancel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = NSView()
        panel.contentView?.addSubview(stack)
        if let content = panel.contentView {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                stack.topAnchor.constraint(equalTo: content.topAnchor),
                stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                bar.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            ])
        }
        panel.center()
    }

    func show() { panel.orderFrontRegardless() }

    func update(done: Int, total: Int, filename: String) {
        bar.doubleValue = Double(done)
        label.stringValue = "Importing \(done) of \(total) — \(filename)"
    }

    func close() { panel.orderOut(nil) }

    @objc private func cancelClicked() {
        label.stringValue = "Cancelling…"
        onCancel?()
    }
}

/// Thread-safe cancellation flag shared between the main-actor Cancel
/// button and the background executor.
final class ImportCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func cancel() { lock.lock(); value = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
