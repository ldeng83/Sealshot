import AppKit
import SwiftUI

/// The unified "Extract Structured Data" result window: a large resizable window
/// that switches between Plain text · Markdown · Table · CSV · JSON, each with
/// Copy / Export, plus Re-extract. Built from a persisted `ExtractionRecord`.
/// Retains itself until closed.
@MainActor
final class ExtractionResultWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {

    private static var open: Set<ExtractionResultWindowController> = []

    private let record: ExtractionRecord
    private let onReExtract: () -> Void
    /// Default file name (no extension) for Export — the capture's display
    /// name, so the exported file is recognizable next to the image.
    private let exportBaseName: String

    /// Presentations other than the rendered preview are DISABLED for now —
    /// the plain-text/table/CSV/JSON output isn't good enough to expose yet.
    /// All their code is kept; flip this to bring back the tab bar, the
    /// Markdown source pane, and the per-format Copy/Export.
    private static let showAllPresentations = false

    private enum Tab: Int, CaseIterable {
        case plaintext, markdown, table, csv, json, source
        var label: String { ["Plain text", "Text", "Table", "CSV", "JSON", "Markdown"][rawValue] }
        var ext: String { ["txt", "md", "tsv", "csv", "json", "md"][rawValue] }
    }
    private var currentTab: Tab = .markdown

    /// What the segmented control offers. The default window pairs the rendered
    /// view ("Text") with its raw source ("Markdown"); the flag's full set keeps
    /// the source out because there the markdown pane lives inside the split.
    private var visibleTabs: [Tab] {
        Self.showAllPresentations ? [.plaintext, .markdown, .table, .csv, .json]
                                  : [.markdown, .source]
    }

    private let segmented = NSSegmentedControl()
    private let container = NSView()
    private let mdSplit = NSSplitView()
    private let mdSource = NSTextView()
    private let mdPreview = NSTextView()
    private let plaintextView = NSTextView()
    private let csvSplit = NSSplitView()

    private lazy var plaintextTabView: NSView = scroll(plaintextView, editable: false, monospaced: true)
    private lazy var markdownView: NSView = makeMarkdownView()
    private lazy var tableView: NSView = NSHostingView(rootView: ExtractionTablesView(tables: record.items.tables))
    private lazy var csvView: NSView = makeCsvView()
    private lazy var jsonView: NSView = makeReadOnly(ExtractionViews.json(record.items), empty: "")
    /// Raw Markdown source. Reuses `mdSource` — the view that already backs the
    /// rendered "Text" tab — so edits here re-render Text live, and Copy/Export
    /// stay per-tab: Text carries what you see, Markdown carries the source.
    private lazy var sourceTabView: NSView = {
        if mdSource.string.isEmpty { mdSource.string = record.markdown; mdSource.delegate = self }
        return scroll(mdSource, editable: true, monospaced: true)
    }()

    init(record: ExtractionRecord, exportBaseName: String = "extraction",
         onReExtract: @escaping () -> Void) {
        self.record = record
        // "/" is the one character macOS filenames can't carry (a user title
        // may contain it); the save panel handles the rest.
        self.exportBaseName = exportBaseName.replacingOccurrences(of: "/", with: "-")
        self.onReExtract = onReExtract
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Extract Structured Data"
        window.minSize = NSSize(width: 560, height: 360)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        // Remember the window size/position globally (across all images + sessions)
        // via a constant frame-autosave name. Restore a saved frame if there is one,
        // otherwise center the default size.
        window.center()
        window.setFrameUsingName(Self.frameAutosaveName)
        window.setFrameAutosaveName(Self.frameAutosaveName)
        buildUI()
    }

    /// Constant (not per-image) so the remembered size applies to every capture.
    private static let frameAutosaveName = NSWindow.FrameAutosaveName("ExtractStructuredDataResultWindow")

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not implemented") }

    func present() {
        Self.open.insert(self)
        window?.makeKeyAndOrderFront(nil)
        window?.layoutIfNeeded()
        if mdSplit.bounds.width > 0 { mdSplit.setPosition(mdSplit.bounds.width / 2, ofDividerAt: 0) }
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let tabs = visibleTabs
        segmented.segmentCount = tabs.count
        for (i, t) in tabs.enumerated() { segmented.setLabel(t.label, forSegment: i) }
        segmented.selectedSegment = tabs.firstIndex(of: .markdown) ?? 0
        segmented.segmentStyle = .texturedRounded
        segmented.target = self
        segmented.action = #selector(tabChanged)
        // Tab group top-CENTER: a plain header view with the control pinned to
        // its horizontal centre (a stack would lead-align it).
        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        segmented.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(segmented)
        NSLayoutConstraint.activate([
            segmented.centerXAnchor.constraint(equalTo: header.centerXAnchor),
            segmented.topAnchor.constraint(equalTo: header.topAnchor, constant: 8),
            header.bottomAnchor.constraint(equalTo: segmented.bottomAnchor, constant: 6),
        ])

        container.translatesAutoresizingMaskIntoConstraints = false

        let reextract = button("Re-extract", #selector(reExtractTapped))
        let copy = button("Copy", #selector(copyCurrent))
        let export = button("Export…", #selector(exportCurrent))
        let close = button("Close", #selector(closeWindow)); close.keyEquivalent = "\u{1b}"
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [reextract, spacer, copy, export, close])
        footer.orientation = .horizontal
        footer.spacing = 8
        footer.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 8, right: 12)
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.setHuggingPriority(.required, for: .vertical)

        content.addSubview(header); content.addSubview(container); content.addSubview(footer)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            container.topAnchor.constraint(equalTo: header.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        showTab(.markdown)
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        return b
    }

    @objc private func tabChanged() {
        let tabs = visibleTabs
        guard tabs.indices.contains(segmented.selectedSegment) else { return }
        showTab(tabs[segmented.selectedSegment])
    }

    private func showTab(_ tab: Tab) {
        currentTab = tab
        if tab == .plaintext { plaintextView.string = MarkdownPreviewRenderer.plainText(mdSource.string) }
        container.subviews.forEach { $0.removeFromSuperview() }
        let view: NSView
        switch tab {
        case .plaintext: view = plaintextTabView
        case .markdown:  view = markdownView
        case .table:     view = tableView
        case .csv:       view = csvView
        case .json:      view = jsonView
        case .source:    view = sourceTabView
        }
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        if tab == .markdown {
            window?.layoutIfNeeded()
            if mdSplit.bounds.width > 0 { mdSplit.setPosition(mdSplit.bounds.width / 2, ofDividerAt: 0) }
        } else if tab == .csv && !record.items.tables.isEmpty {
            window?.layoutIfNeeded()
            if csvSplit.bounds.width > 0 { csvSplit.setPosition(csvSplit.bounds.width / 2, ofDividerAt: 0) }
        }
    }

    // MARK: Markdown (source + live preview)

    private func makeMarkdownView() -> NSView {
        mdSource.string = record.markdown
        mdSource.delegate = self
        renderPreview()
        // Single-presentation mode: rendered preview only — the Markdown
        // source stays hidden (mdSource still backs the render).
        guard Self.showAllPresentations else {
            return scroll(mdPreview, editable: false, monospaced: false)
        }
        mdSplit.isVertical = true
        mdSplit.dividerStyle = .thin
        mdSplit.translatesAutoresizingMaskIntoConstraints = false
        mdSplit.addArrangedSubview(scroll(mdSource, editable: true, monospaced: true))
        mdSplit.addArrangedSubview(scroll(mdPreview, editable: false, monospaced: false))
        return mdSplit
    }

    /// CSV view — two panes: the CSV source (left) and an Excel-like grid (right).
    private func makeCsvView() -> NSView {
        guard !record.items.tables.isEmpty else { return makeReadOnly("", empty: "No tables found") }
        csvSplit.isVertical = true
        csvSplit.dividerStyle = .thin
        csvSplit.translatesAutoresizingMaskIntoConstraints = false
        let csvText = NSTextView()
        csvSplit.addArrangedSubview(scroll(csvText, editable: false, monospaced: true,
                                           string: ExtractionViews.csv(record.items)))
        csvSplit.addArrangedSubview(NSHostingView(rootView: ExtractionTablesView(tables: record.items.tables)))
        return csvSplit
    }

    private func renderPreview() {
        mdPreview.textStorage?.setAttributedString(MarkdownPreviewRenderer.render(mdSource.string))
        // Diagnostic for the missing-horizontal-scroller report: capture the
        // geometry after layout has had a turn, not at set-time.
        DispatchQueue.main.async { [weak self] in
            ExtractWindowDiag.snapshot(self?.window?.contentView, context: "after-render")
        }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        ExtractWindowDiag.snapshot(window?.contentView, context: "after-resize")
    }

    func textDidChange(_ notification: Notification) {
        if (notification.object as? NSTextView) === mdSource { renderPreview() }
    }

    // MARK: helpers

    private func makeReadOnly(_ text: String, empty: String) -> NSView {
        if text.isEmpty && !empty.isEmpty {
            let label = NSTextField(labelWithString: empty)
            label.textColor = .secondaryLabelColor
            let wrap = NSView()
            label.translatesAutoresizingMaskIntoConstraints = false
            wrap.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: wrap.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: wrap.centerYAnchor),
            ])
            return wrap
        }
        let tv = NSTextView()
        return scroll(tv, editable: false, monospaced: true, string: text)
    }

    private func scroll(_ tv: NSTextView, editable: Bool, monospaced: Bool, string: String? = nil) -> NSScrollView {
        let s = NSScrollView()
        s.hasVerticalScroller = true
        // Every view in this window is line-structured data — space-padded
        // tables (which the renderer deliberately styles `.byClipping`), CSV,
        // JSON, and OCR text that recognition already broke into lines. The
        // views used to soft-wrap (`widthTracksTextView = true`) with no
        // horizontal scroller, so a wide table's columns were clipped at the
        // view edge with NO way to reach them. Lines now keep their width and
        // the scroller appears when they exceed it.
        s.hasHorizontalScroller = true
        // Without autohide (default OFF for programmatic scroll views), legacy
        // scrollers show a permanent EMPTY track even when every column fits —
        // which reads as "there is a scroll bar but no scroller to drag".
        // Autohidden, the track only appears when there is something to reach,
        // and then it has a knob.
        s.autohidesScrollers = true
        s.borderType = .noBorder
        s.translatesAutoresizingMaskIntoConstraints = false
        tv.isEditable = editable
        tv.isRichText = !editable
        tv.textContainerInset = NSSize(width: 10, height: 10)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = true
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                            height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                 height: CGFloat.greatestFiniteMagnitude)
        if monospaced { tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular) }
        if let string { tv.string = string }
        s.documentView = tv
        return s
    }

    private func currentText() -> String {
        switch currentTab {
        case .plaintext: return plaintextView.string
        case .markdown:
            // Single-presentation mode: Copy/Export carry what the user SEES —
            // the rendered preview text — not the Markdown source.
            return Self.showAllPresentations ? mdSource.string : mdPreview.string
        case .table:     return ExtractionViews.tsv(record.items)
        case .csv:       return ExtractionViews.csv(record.items)
        case .json:      return ExtractionViews.json(record.items)
        case .source:    return mdSource.string
        }
    }

    /// Export extension for the current tab — plain .txt in single-presentation
    /// mode (the export is the rendered preview text, not Markdown source).
    private func currentExportExt() -> String {
        currentTab == .markdown && !Self.showAllPresentations ? "txt" : currentTab.ext
    }

    // MARK: actions

    @objc private func copyCurrent() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(currentText(), forType: .string)
    }

    @objc private func exportCurrent() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(exportBaseName).\(currentExportExt())"
        let text = currentText()
        panel.begin { resp in
            guard resp == .OK, let url = panel.url else { return }
            try? text.data(using: .utf8)?.write(to: url)
        }
    }

    @objc private func reExtractTapped() {
        closeWindow()
        onReExtract()
    }

    @objc private func closeWindow() { window?.performClose(nil) }

    func windowWillClose(_ notification: Notification) {
        ExtractWindowDiag.snapshot(window?.contentView, context: "at-close")
        Self.open.remove(self)
    }
}
