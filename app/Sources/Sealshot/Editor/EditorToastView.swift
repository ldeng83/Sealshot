import AppKit

/// A small transient capsule shown near the top of the canvas to give a
/// momentary hint (e.g. "Undo: Add Arrow"). Fades itself out and removes
/// itself; only one is shown at a time.
final class EditorToastView: NSView {
    private static let holdSeconds: TimeInterval = 2.2
    private static let fadeSeconds: TimeInterval = 0.4

    init(message: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
        layer?.cornerRadius = 8

        let label = NSTextField(labelWithString: message)
        label.textColor = .white
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not implemented") }

    /// Show `message` near the top-center of `host`, replacing any prior toast,
    /// then fade out and remove.
    static func show(_ message: String, in host: NSView) {
        host.subviews.compactMap { $0 as? EditorToastView }.forEach { $0.removeFromSuperview() }
        let toast = EditorToastView(message: message)
        // Above ALL siblings — and pinned there by layer z-position: undo
        // hints can trigger an image swap that adds fresh canvas views AFTER
        // the toast, which would otherwise cover it (sibling order alone is
        // a race the toast loses).
        host.addSubview(toast, positioned: .above, relativeTo: nil)
        toast.layer?.zPosition = 10_000
        NSLayoutConstraint.activate([
            toast.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            toast.topAnchor.constraint(equalTo: host.topAnchor, constant: 18),
        ])
        toast.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            toast.animator().alphaValue = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + holdSeconds) { [weak toast] in
            guard let toast else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = fadeSeconds
                toast.animator().alphaValue = 0
            }, completionHandler: { [weak toast] in
                toast?.removeFromSuperview()
            })
        }
    }
}
