import AppKit

/// Determinate progress sheet for bulk file operations (delete / restore /
/// permanent delete) and export. Appears only when the operation is actually
/// slow: the sheet materializes after a short grace delay, so fast batches
/// finish without any flash of UI.
@MainActor
final class BulkProgressSheet {

    private var panel: NSPanel?
    private var bar: NSProgressIndicator?
    private var primaryLabel: NSTextField?
    private var detailLabel: NSTextField?
    private var cancelButton: NSButton?
    private weak var host: NSWindow?
    private var showTask: Task<Void, Never>?
    private var presented = false

    /// Grace period before the sheet shows; batches that finish sooner
    /// never display anything.
    private let graceDelay: UInt64 = 250_000_000   // 250 ms

    // MARK: – Begin (delete / restore – no Cancel, no ETA)

    func begin(total: Int, verb: String, in window: NSWindow) {
        beginInternal(total: total, verb: verb, in: window, onCancel: nil)
    }

    // MARK: – Begin (export – optional Cancel + ETA line)

    /// Like `begin(total:verb:in:)` but adds a Cancel button (when `onCancel`
    /// is non-nil) and an ETA detail line below the bar. Pass `immediate: true`
    /// for explicit user-initiated actions (e.g. Export) that should show the
    /// bar + Cancel right away rather than waiting out the grace delay.
    func begin(total: Int, verb: String, in window: NSWindow, onCancel: (() -> Void)?,
               immediate: Bool = false) {
        beginInternal(total: total, verb: verb, in: window, onCancel: onCancel, immediate: immediate)
    }

    // MARK: – Begin (indeterminate — barber-pole, optional Cancel)

    /// Indeterminate variant for operations of unknown duration (e.g. on-device
    /// extraction). Shows a spinning/barber-pole indicator instead of a bar.
    /// The sheet still respects the 250 ms grace delay, so fast operations never
    /// flash any UI.
    func beginIndeterminate(verb: String, in window: NSWindow, onCancel: (() -> Void)?) {
        end()   // defensive: never stack two sheets
        host = window

        let bar = NSProgressIndicator()
        bar.style = .spinning
        bar.isIndeterminate = true
        bar.controlSize = .regular
        bar.startAnimation(nil)
        bar.translatesAutoresizingMaskIntoConstraints = false

        let primaryLabel = NSTextField(labelWithString: "\(verb)…")
        primaryLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        primaryLabel.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(primaryLabel)
        content.addSubview(bar)

        var constraints: [NSLayoutConstraint] = [
            bar.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            bar.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            primaryLabel.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 10),
            primaryLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
        ]

        let panelHeight: CGFloat
        if let onCancel {
            let btn = NSButton(title: "Cancel", target: nil, action: nil)
            btn.bezelStyle = .rounded
            btn.translatesAutoresizingMaskIntoConstraints = false
            let handler = onCancel
            let blockTarget = NSBlockTarget { handler() }
            objc_setAssociatedObject(btn, &BulkProgressSheet.cancelTargetKey, blockTarget, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            btn.target = blockTarget
            btn.action = #selector(NSBlockTarget.invoke)
            content.addSubview(btn)
            self.cancelButton = btn
            constraints += [
                btn.topAnchor.constraint(equalTo: primaryLabel.bottomAnchor, constant: 12),
                btn.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
                btn.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            ]
            panelHeight = 148
        } else {
            constraints.append(
                primaryLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20)
            )
            panelHeight = 110
        }

        NSLayoutConstraint.activate(constraints)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: panelHeight),
            styleMask: [.titled], backing: .buffered, defer: false)
        panel.contentView = content
        panel.isReleasedWhenClosed = false

        self.panel = panel
        self.bar = bar
        self.primaryLabel = primaryLabel

        showTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: self?.graceDelay ?? 0)
            guard !Task.isCancelled, let self, let panel = self.panel,
                  let host = self.host, !self.presented else { return }
            self.presented = true
            host.beginSheet(panel, completionHandler: nil)
        }
    }

    private func beginInternal(total: Int, verb: String, in window: NSWindow, onCancel: (() -> Void)?,
                               immediate: Bool = false) {
        end()   // defensive: never stack two sheets
        host = window

        let bar = NSProgressIndicator()
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = Double(total)
        bar.doubleValue = 0
        bar.translatesAutoresizingMaskIntoConstraints = false

        let primaryLabel = NSTextField(labelWithString: "\(verb) 0 of \(total)…")
        primaryLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        primaryLabel.translatesAutoresizingMaskIntoConstraints = false

        let detailLabel = NSTextField(labelWithString: "")
        detailLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(primaryLabel)
        content.addSubview(bar)
        content.addSubview(detailLabel)

        var constraints: [NSLayoutConstraint] = [
            primaryLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            primaryLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            primaryLabel.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -24),
            bar.topAnchor.constraint(equalTo: primaryLabel.bottomAnchor, constant: 10),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            detailLabel.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 6),
            detailLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -24),
        ]

        let panelHeight: CGFloat
        if let onCancel {
            let btn = NSButton(title: "Cancel", target: nil, action: nil)
            btn.bezelStyle = .rounded
            btn.translatesAutoresizingMaskIntoConstraints = false
            let handler = onCancel
            let blockTarget = NSBlockTarget { handler() }
            // Retain the target via associated object (btn.target is weak).
            objc_setAssociatedObject(btn, &BulkProgressSheet.cancelTargetKey, blockTarget, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            btn.target = blockTarget
            btn.action = #selector(NSBlockTarget.invoke)
            content.addSubview(btn)
            self.cancelButton = btn
            constraints += [
                btn.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 12),
                btn.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
                btn.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            ]
            panelHeight = 162
        } else {
            constraints.append(
                detailLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20)
            )
            panelHeight = 120
        }

        NSLayoutConstraint.activate(constraints)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: panelHeight),
            styleMask: [.titled], backing: .buffered, defer: false)
        panel.contentView = content
        panel.isReleasedWhenClosed = false

        self.panel = panel
        self.bar = bar
        self.primaryLabel = primaryLabel
        self.detailLabel = detailLabel

        let delay: UInt64 = immediate ? 0 : graceDelay
        showTask = Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            guard !Task.isCancelled, let self, let panel = self.panel,
                  let host = self.host, !self.presented else { return }
            self.presented = true
            host.beginSheet(panel, completionHandler: nil)
        }
    }

    // MARK: – Update (delete / restore path — count-based)

    func update(done: Int, total: Int, verb: String) {
        bar?.doubleValue = Double(done)
        primaryLabel?.stringValue = "\(verb) \(done) of \(total)…"
    }

    // MARK: – Update (export path — fraction-based with optional ETA)

    /// Drive the bar with a 0…1 fraction (determinate). Called on the main actor
    /// by the export refresh loop. `detail` is typically an ETA string or nil.
    func setFraction(_ fraction: Double, label: String, detail: String?) {
        bar?.isIndeterminate = false
        bar?.minValue = 0
        bar?.maxValue = 1
        bar?.doubleValue = fraction
        primaryLabel?.stringValue = label
        detailLabel?.stringValue = detail ?? ""
    }

    // MARK: – End

    func end() {
        showTask?.cancel()
        showTask = nil
        if presented, let panel, let host {
            host.endSheet(panel)
            panel.orderOut(nil)
        }
        presented = false
        panel = nil
        bar = nil
        primaryLabel = nil
        detailLabel = nil
        cancelButton = nil
        host = nil
    }

    // MARK: – Private

    private static var cancelTargetKey: UInt8 = 0
}

// MARK: – Lightweight block-based NSButton target

/// Simple ObjC-compatible trampoline so we can attach a Swift closure to an
/// NSButton without reaching for any external framework.
private final class NSBlockTarget: NSObject {
    private let block: () -> Void
    init(_ block: @escaping () -> Void) { self.block = block }
    @objc func invoke() { block() }
}
