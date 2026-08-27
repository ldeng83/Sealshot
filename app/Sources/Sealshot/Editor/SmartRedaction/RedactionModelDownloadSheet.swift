import AppKit
import Combine

/// Window-modal sheet that drives a foreground model download with a progress
/// bar and Cancel button.  Blocks the host window until the download reaches a
/// terminal state (ready / failed / cancelled).
///
/// Usage:
///   RedactionModelDownloadSheet.run(on: window) { ok in
///       if ok { /* model ready — run scan */ } else { /* fallback */ }
///   }
@MainActor
enum RedactionModelDownloadSheet {

    /// Start the download and present the blocking sheet on `window`.
    /// `completion` is called on the main actor once the sheet is dismissed:
    ///   - `true`  — model is ready
    ///   - `false` — cancelled or failed
    static func run(on window: NSWindow, completion: @escaping @MainActor (Bool) -> Void) {
        let presenter = Presenter(host: window, completion: completion)
        presenter.start()
    }

    // MARK: – Internal presenter

    @MainActor
    private final class Presenter {
        private weak var host: NSWindow?
        private let completion: @MainActor (Bool) -> Void
        private var panel: NSPanel?
        private var bar: NSProgressIndicator?
        private var primaryLabel: NSTextField?
        private var actionButton: NSButton?
        private var cancellable: AnyCancellable?
        private var presented = false
        /// Retains `self` for the duration of the sheet so the caller need not
        /// hold a reference; cleared inside `dismissSheet` after `endSheet`.
        private var retained: Presenter?

        init(host: NSWindow, completion: @escaping @MainActor (Bool) -> Void) {
            self.host = host
            self.completion = completion
        }

        func start() {
            // Short-circuit: model already ready — skip the sheet entirely.
            if case .ready = RedactionModelManager.shared.state {
                completion(true)
                return
            }
            buildPanel()
            retained = self          // keep alive for the full sheet lifetime
            RedactionModelManager.shared.start()
            // Present BEFORE subscribing so a fast/synchronous terminal state
            // cannot call dismissSheet while presented == false.
            presentSheet()
            observeState()
        }

        // MARK: – Panel construction

        private func buildPanel() {
            let titleLabel = NSTextField(labelWithString: "Downloading Enhanced Redaction Model")
            titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
            titleLabel.translatesAutoresizingMaskIntoConstraints = false

            let subtitleLabel = NSTextField(labelWithString: "~400 MB · runs entirely on your Mac")
            subtitleLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            subtitleLabel.textColor = .secondaryLabelColor
            subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
            primaryLabel = subtitleLabel

            let bar = NSProgressIndicator()
            bar.style = .bar
            bar.isIndeterminate = false
            bar.minValue = 0
            bar.maxValue = 1
            bar.doubleValue = 0
            bar.translatesAutoresizingMaskIntoConstraints = false
            self.bar = bar

            let cancelBtn = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
            cancelBtn.bezelStyle = .rounded
            cancelBtn.translatesAutoresizingMaskIntoConstraints = false
            actionButton = cancelBtn

            let content = NSView()
            content.addSubview(titleLabel)
            content.addSubview(subtitleLabel)
            content.addSubview(bar)
            content.addSubview(cancelBtn)

            NSLayoutConstraint.activate([
                titleLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
                titleLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
                titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -24),

                subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
                subtitleLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
                subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -24),

                bar.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 12),
                bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
                bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),

                cancelBtn.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 14),
                cancelBtn.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
                cancelBtn.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            ])

            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 148),
                styleMask: [.titled], backing: .buffered, defer: false)
            panel.title = "Downloading enhanced on-device model"
            panel.contentView = content
            panel.isReleasedWhenClosed = false
            self.panel = panel
        }

        private func presentSheet() {
            guard let host, let panel else { return }
            presented = true
            host.beginSheet(panel) { [weak self] _ in
                // Sheet dismissed — fire completion based on final state.
                guard let self else { return }
                let ok: Bool
                if case .ready = RedactionModelManager.shared.state { ok = true } else { ok = false }
                self.completion(ok)
            }
        }

        // MARK: – State observation

        private func observeState() {
            cancellable = RedactionModelManager.shared.$state
                .receive(on: RunLoop.main)
                .sink { [weak self] state in
                    self?.applyState(state)
                }
        }

        private func applyState(_ state: RedactionModelManager.State) {
            switch state {
            case .notDownloaded:
                // Cancelled — dismiss.
                dismissSheet()

            case .downloading(let fraction):
                bar?.isIndeterminate = false
                bar?.doubleValue = fraction
                let pct = Int(fraction * 100)
                primaryLabel?.stringValue = "Downloading… \(pct)%"
                actionButton?.title = "Cancel"
                actionButton?.action = #selector(cancelTapped)
                actionButton?.target = self
                actionButton?.isEnabled = true

            case .verifying:
                bar?.isIndeterminate = true
                bar?.startAnimation(nil)
                primaryLabel?.stringValue = "Verifying…"
                actionButton?.isEnabled = false

            case .installing:
                bar?.isIndeterminate = true
                bar?.startAnimation(nil)
                primaryLabel?.stringValue = "Installing…"
                actionButton?.isEnabled = false

            case .ready:
                dismissSheet()

            case .failed(let message):
                bar?.isIndeterminate = false
                bar?.doubleValue = 0
                primaryLabel?.stringValue = message
                actionButton?.title = "Close"
                actionButton?.isEnabled = true
                actionButton?.action = #selector(closeTapped)
                actionButton?.target = self
            }
        }

        // MARK: – Actions

        @objc private func cancelTapped() {
            RedactionModelManager.shared.cancel()
            // State transitions to .notDownloaded which triggers dismissSheet.
        }

        @objc private func closeTapped() {
            dismissSheet()
        }

        private func dismissSheet() {
            cancellable = nil
            guard presented, let panel, let host else { return }
            presented = false
            host.endSheet(panel)
            panel.orderOut(nil)
            retained = nil   // release self last, after endSheet fires the completion handler
        }
    }
}
