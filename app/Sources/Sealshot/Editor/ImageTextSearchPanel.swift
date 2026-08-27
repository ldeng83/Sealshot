import AppKit

enum ImageTextSearchEditingCommand: Equatable {
    case moveResult(Int)
    case exit
}

/// AppKit sends keystrokes for an actively edited NSSearchField to its shared
/// NSTextView field editor, so the search field's own `keyDown` override is not
/// the primary command path. Translate field-editor commands in the delegate.
func imageTextSearchEditingCommand(for selector: Selector,
                                   modifierFlags: NSEvent.ModifierFlags) -> ImageTextSearchEditingCommand? {
    if selector == #selector(NSResponder.insertNewline(_:))
        || selector == #selector(NSResponder.insertLineBreak(_:))
        || selector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) {
        return .moveResult(modifierFlags.contains(.shift) ? -1 : 1)
    }
    if selector == #selector(NSResponder.cancelOperation(_:)) { return .exit }
    return nil
}

/// Right-sidebar controls for Find in Image. The panel owns only controls;
/// OCR, matching, and highlight geometry stay in `EditorCanvasView`.
@MainActor
final class ImageTextSearchPanel: NSView, NSSearchFieldDelegate {

    var onQueryChanged: ((String) -> Void)?
    var onScopeChanged: ((ImageTextSearchScope) -> Void)?
    var onMoveResult: ((Int) -> Void)?
    var onExit: (() -> Void)?

    /// Typing waits for a pause before the canvas re-scans — see
    /// `ImageTextSearchQueryDebouncer`. Anything that acts on the results
    /// flushes it first, so Return never navigates a stale search.
    private let queryDebouncer = ImageTextSearchQueryDebouncer()

    private let queryField = ImageTextSearchField()
    private let scopePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let resultLabel = NSTextField(labelWithString: "")
    private let previousButton = ClosureButton(title: "Previous", onClick: {})
    private let nextButton = ClosureButton(title: "Next", onClick: {})

    init(query: String, scope: ImageTextSearchScope, focusAreaAvailable: Bool,
         status: ImageTextSearchStatus) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        stack.addArrangedSubview(fieldLabel("Search text"))
        queryField.stringValue = query
        queryField.placeholderString = "Enter a keyword"
        queryField.sendsSearchStringImmediately = true
        queryField.delegate = self
        queryDebouncer.onDeliver = { [weak self] query in self?.onQueryChanged?(query) }
        queryField.onMoveResult = { [weak self] delta in self?.moveResult(delta) }
        queryField.onExit = { [weak self] in self?.exitSearch() }
        queryField.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(queryField)
        queryField.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        stack.setCustomSpacing(18, after: queryField)
        stack.addArrangedSubview(fieldLabel("Scope"))
        scopePopup.addItems(withTitles: ["Whole image", "Focus Area only"])
        scopePopup.selectItem(at: scope == .focusArea && focusAreaAvailable ? 1 : 0)
        scopePopup.item(at: 1)?.isEnabled = focusAreaAvailable
        scopePopup.target = self
        scopePopup.action = #selector(scopeChanged)
        scopePopup.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(scopePopup)
        scopePopup.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        stack.setCustomSpacing(20, after: scopePopup)
        let resultsHeader = NSStackView()
        resultsHeader.orientation = .horizontal
        resultsHeader.alignment = .firstBaseline
        resultsHeader.translatesAutoresizingMaskIntoConstraints = false
        resultsHeader.addArrangedSubview(fieldLabel("Matches"))
        resultsHeader.addArrangedSubview(NSView())
        resultLabel.font = Theme.valueFont
        resultLabel.alignment = .right
        resultsHeader.addArrangedSubview(resultLabel)
        stack.addArrangedSubview(resultsHeader)
        resultsHeader.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        previousButton.image = NSImage(systemSymbolName: "chevron.up", accessibilityDescription: nil)
        previousButton.imagePosition = .imageLeading
        nextButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)
        nextButton.imagePosition = .imageTrailing
        previousButton.target = self
        previousButton.action = #selector(previousResult)
        nextButton.target = self
        nextButton.action = #selector(nextResult)
        let nav = NSStackView(views: [previousButton, nextButton])
        nav.orientation = .horizontal
        nav.distribution = .fillEqually
        nav.spacing = 8
        nav.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(nav)
        nav.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let hint = NSTextField(wrappingLabelWithString:
            "Return moves forward. Shift-Return moves backward.")
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        stack.addArrangedSubview(hint)
        hint.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        update(status: status)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not implemented") }

    func controlTextDidChange(_ obj: Notification) {
        queryDebouncer.submit(queryField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        switch imageTextSearchEditingCommand(for: commandSelector, modifierFlags: flags) {
        case .moveResult(let delta):
            moveResult(delta)
            return true
        case .exit:
            exitSearch()
            return true
        case nil:
            return false
        }
    }

    /// Step through results. Flushes first: Return is usually pressed straight
    /// after typing, and stepping through matches for a half-typed word — or
    /// for the previous query entirely — is worse than the delay it saves.
    private func moveResult(_ delta: Int) {
        queryDebouncer.flush()
        onMoveResult?(delta)
    }

    /// Leave the panel. Drops the pending query rather than flushing it — the
    /// search is being abandoned, so landing one last result set on the way out
    /// is not wanted.
    private func exitSearch() {
        queryDebouncer.cancel()
        onExit?()
    }

    func focusQueryField() {
        window?.makeFirstResponder(queryField)
        queryField.currentEditor()?.selectAll(nil)
    }

    func update(status: ImageTextSearchStatus) {
        switch status {
        case .idle:
            resultLabel.stringValue = "—"
            setNavigationEnabled(false)
        case .recognizing:
            resultLabel.stringValue = "Recognizing…"
            setNavigationEnabled(false)
        case .noText:
            resultLabel.stringValue = "No text found"
            setNavigationEnabled(false)
        case .noMatches:
            resultLabel.stringValue = "No matches"
            setNavigationEnabled(false)
        case .matches(let current, let total):
            resultLabel.stringValue = "\(current + 1) of \(total)"
            setNavigationEnabled(true)
        }
    }

    private func setNavigationEnabled(_ enabled: Bool) {
        previousButton.isEnabled = enabled
        nextButton.isEnabled = enabled
    }

    private func fieldLabel(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = Theme.labelFont
        field.textColor = .secondaryLabelColor
        return field
    }

    @objc private func scopeChanged() {
        // Narrowing to the focus area re-runs the search, so it should run for
        // what is typed now rather than for the last completed query.
        queryDebouncer.flush()
        onScopeChanged?(scopePopup.indexOfSelectedItem == 1 ? .focusArea : .wholeImage)
    }

    @objc private func previousResult() { moveResult(-1) }
    @objc private func nextResult() { moveResult(1) }
}

/// Fallback for commands delivered directly to the control. Normal editing
/// uses the field-editor delegate path in `ImageTextSearchPanel` above.
@MainActor
private final class ImageTextSearchField: NSSearchField {
    var onMoveResult: ((Int) -> Void)?
    var onExit: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            onMoveResult?(event.modifierFlags.contains(.shift) ? -1 : 1)
            return
        }
        if event.keyCode == 53 {
            onExit?()
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) { onExit?() }
}

/// Where Find in Image joins the Live Text pipeline when it is opened from an
/// already-running Live Text session. nil = leave the stage as it is.
///
/// Opening the panel parks the stage at `.waitingForEnhancementDecision`, and
/// the tool-change observer that normally resolves it cannot fire, because the
/// tool is already `.textSelect` — there is no transition to observe. Anything
/// left unresolved here hangs the panel on "waiting for image scan" for good:
/// `imageTextSearchScanCanFinish` reads that stage as "not ready", and nothing
/// else will revisit it.
///
/// That is what happened to a capture Live Text had already read successfully.
/// Only the no-text case was handled, so FINDING text — the ordinary outcome —
/// fell through every branch and left the decision pending after it had
/// already been made. Waiting is now the exception (an enhancement genuinely
/// in flight, whose result will replace what is on screen) rather than the
/// default.
func imageTextSearchScanStageOnEnteringSearch(
    showingEnhanced: Bool,
    hasEnhancedImage: Bool,
    enhanceSessionActive: Bool,
    enhanceRunning: Bool,
    liveTextHasText: Bool?
) -> ImageTextSearchScanStage? {
    if showingEnhanced, hasEnhancedImage { return .recognizingCurrentBase }
    guard enhanceSessionActive else { return nil }
    // An enhanced base on its way in will replace these pixels, so scanning
    // them now would produce boxes for an image about to be discarded.
    if enhanceRunning { return .waitingForEnhancedOCR }
    // Everything else — text found, no text, or a read still in flight — scans
    // what is on screen. A read in flight is not a reason to wait here; the
    // scan reports "recognizing" until the layout lands and resolves itself.
    return .recognizingCurrentBase
}
