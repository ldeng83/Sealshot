import AppKit

/// A top-anchored vertical stack for use as an `NSScrollView` document view: a
/// non-flipped document sinks short content to the bottom of the clip view,
/// leaving a gap above the first row. Flipping anchors content to the top.
private final class TopAnchoredStackView: NSStackView {
    override var isFlipped: Bool { true }
}

/// Sidebar panel listing smart-redaction proposals: one toggleable row per
/// detection (category, truncated snippet, confidence), with Apply/Cancel at
/// the bottom. Mutates `EditorState` directly (toggle/apply/cancel); the
/// canvas and sidebar react through observation.
@MainActor
final class SmartRedactionReviewPanel: NSView {

    private let state: EditorState
    private var scrollObserver: NSObjectProtocol?
    /// Kept so Select all / Deselect all can update checkboxes in place —
    /// those actions no longer rebuild the panel (phase is unchanged).
    private var proposalRows: [RedactionProposalRow] = []

    init(state: EditorState) {
        self.state = state
        super.init(frame: .zero)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not implemented") }

    deinit {
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
    }

    private func build() {
        guard case .found(let proposals) = state.redactionScan else { return }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        // Fill distribution so the scroll view (low vertical hugging, below)
        // stretches to absorb the panel's height — the list grows toward the
        // strip instead of leaving a gap.
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        let count = proposals.count
        let summary = NSTextField(labelWithString:
            count == 1 ? "1 sensitive region found" : "\(count) sensitive regions found")
        summary.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        summary.textColor = .secondaryLabelColor
        stack.addArrangedSubview(summary)

        // Bulk keep/skip for long lists.
        let selectButtons = NSStackView()
        selectButtons.orientation = .horizontal
        selectButtons.spacing = 8
        let selectAll = NSButton(title: "Select all", target: self, action: #selector(selectAllTapped))
        let deselectAll = NSButton(title: "Deselect all", target: self, action: #selector(deselectAllTapped))
        for b in [selectAll, deselectAll] { b.bezelStyle = .inline; b.controlSize = .small }
        selectButtons.addArrangedSubview(selectAll)
        selectButtons.addArrangedSubview(deselectAll)
        stack.addArrangedSubview(selectButtons)

        // Rows scroll when there are many hits (a dense terminal screenshot
        // can produce dozens); the panel itself must not outgrow the sidebar.
        let rows = TopAnchoredStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 4
        for proposal in proposals {
            let row = makeRow(proposal)
            rows.addArrangedSubview(row)
            proposalRows.append(row)
            // Full stack width so the hover background reads as a row, not a
            // content-hugging blob.
            row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.documentView = rows
        rows.translatesAutoresizingMaskIntoConstraints = false
        // Pin the list to the clip view's TOP (and sides) so it stays top-aligned
        // and grows downward; a non-flipped scroll document otherwise sinks short
        // content to the bottom, leaving a gap above the first row.
        NSLayoutConstraint.activate([
            rows.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            rows.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
        ])
        // Expand to fill the available sidebar height (the panel is pinned to
        // the host's bottom), so the list reaches down toward the strip; rows
        // scroll within when they overflow. A floor keeps it usable on a short
        // window, and low vertical hugging makes this the view that stretches.
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        scroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        stack.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // Toggling a checkbox mutates `redactionScan`, which rebuilds this
        // whole panel — track the live offset and restore it on the fresh
        // scroll view so the list doesn't snap back to the top.
        scroll.contentView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView, queue: .main) { [weak state] note in
            guard let clip = note.object as? NSClipView else { return }
            MainActor.assumeIsolated { state?.redactionListScrollOffset = clip.bounds.origin.y }
        }
        let savedOffset = state.redactionListScrollOffset
        if savedOffset > 0 {
            DispatchQueue.main.async { [weak scroll] in
                guard let scroll else { return }
                scroll.layoutSubtreeIfNeeded()   // rows need real heights first
                scroll.contentView.scroll(to: NSPoint(x: 0, y: savedOffset))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let apply = NSButton(title: "Apply", target: self, action: #selector(applyTapped))
        apply.bezelStyle = .rounded
        apply.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancel.bezelStyle = .rounded
        buttons.addArrangedSubview(apply)
        buttons.addArrangedSubview(cancel)
        stack.addArrangedSubview(buttons)
    }

    private func makeRow(_ proposal: RedactionProposal) -> RedactionProposalRow {
        let row = RedactionProposalRow(proposal: proposal,
                                       onToggle: { [weak self] id in
                                           self?.state.toggleRedactionProposal(id)
                                       },
                                       onHover: { [weak self] id in
                                           self?.state.redactionFocusID = id
                                       })
        return row
    }

    @objc private func selectAllTapped() {
        state.setAllRedactionProposals(kept: true)
        proposalRows.forEach { $0.setChecked(true) }
    }

    @objc private func deselectAllTapped() {
        state.setAllRedactionProposals(kept: false)
        proposalRows.forEach { $0.setChecked(false) }
    }

    @objc private func applyTapped() {
        state.redactionFocusID = nil
        state.applyKeptRedactionProposals()
    }

    @objc private func cancelTapped() {
        state.redactionFocusID = nil
        state.cancelRedactionScan()
    }
}

/// One proposal row: checkbox (keep/skip) + the flagged text as the headline +
/// category and confidence as muted subtext. Hovering reports the proposal id
/// so the canvas can emphasize the matching rects.
@MainActor
private final class RedactionProposalRow: NSView {

    private let proposalID: UUID
    private let onToggle: (UUID) -> Void
    private let onHover: (UUID?) -> Void
    private var tracking: NSTrackingArea?
    private let check = NSButton(checkboxWithTitle: "", target: nil, action: nil)

    init(proposal: RedactionProposal,
         onToggle: @escaping (UUID) -> Void,
         onHover: @escaping (UUID?) -> Void) {
        self.proposalID = proposal.id
        self.onToggle = onToggle
        self.onHover = onHover
        super.init(frame: .zero)

        check.target = self
        check.action = #selector(toggled)
        check.state = proposal.isKept ? .on : .off
        check.translatesAutoresizingMaskIntoConstraints = false

        // The flagged text itself is the headline — it's what the user scans
        // to decide keep/skip.
        let title = NSTextField(labelWithString: proposal.detection.snippet)
        title.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        title.lineBreakMode = .byTruncatingMiddle
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.translatesAutoresizingMaskIntoConstraints = false

        // Category (FM finds carry a precise label) + confidence, muted below.
        let pct = Int((proposal.detection.confidence * 100).rounded())
        let detail = NSTextField(labelWithString:
            "\(proposal.detection.customLabel ?? proposal.detection.category.displayName)  ·  \(pct)%")
        detail.font = NSFont.systemFont(ofSize: 10)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.translatesAutoresizingMaskIntoConstraints = false

        addSubview(check)
        addSubview(title)
        addSubview(detail)
        // Small interior padding so the rounded hover background clears the
        // content on every side.
        NSLayoutConstraint.activate([
            check.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            check.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            title.leadingAnchor.constraint(equalTo: check.trailingAnchor, constant: 4),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            detail.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 38),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not implemented") }

    @objc private func toggled() { onToggle(proposalID) }

    /// Sync the checkbox from outside (Select all / Deselect all update rows
    /// in place — no panel rebuild happens for kept-flag changes).
    func setChecked(_ on: Bool) { check.state = on ? .on : .off }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        setHoverBackground(true)
        onHover(proposalID)
    }

    override func mouseExited(with event: NSEvent) {
        setHoverBackground(false)
        onHover(nil)
    }

    /// Accent-tinted rounded background + hairline border so the list echoes
    /// the canvas spotlight the moment the cursor lands on a row.
    private func setHoverBackground(_ on: Bool) {
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.backgroundColor = on
            ? NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor
            : nil
        layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.35).cgColor
        layer?.borderWidth = on ? 1 : 0
    }
}

extension SensitiveCategory {
    /// Human-readable name for review rows.
    var displayName: String {
        switch self {
        case .email: return "Email address"
        case .phone: return "Phone number"
        case .creditCard: return "Credit card"
        case .awsKey: return "AWS access key"
        case .stripeKey: return "Stripe key"
        case .githubToken: return "GitHub token"
        case .gitlabToken: return "GitLab token"
        case .googleApiKey: return "Google API key"
        case .slackToken: return "Slack token"
        case .openAIKey: return "OpenAI key"
        case .anthropicKey: return "Anthropic key"
        case .sendgridKey: return "SendGrid key"
        case .twilioKey: return "Twilio key"
        case .jwt: return "JWT"
        case .bearerToken: return "Bearer token"
        case .privateKeyBlock: return "Private key"
        case .credentialedURL: return "URL with credentials"
        case .iban: return "IBAN"
        case .routingNumber: return "Bank routing number"
        case .cryptoWallet: return "Crypto wallet address"
        case .vin: return "Vehicle identification number"
        case .ipAddress: return "IP address"
        case .macAddress: return "MAC address"
        case .ssn: return "Social Security number"
        case .secretAssignment: return "Secret value"
        case .machineReadableZone: return "Passport MRZ"
        case .personName: return "Name"
        case .organizationName: return "Organization"
        case .placeName: return "Location"
        case .postalAddress: return "Mailing address"
        case .labeledField: return "Sensitive field"
        case .highEntropy: return "Possible secret"
        case .contextual: return "Sensitive info"
        }
    }
}
