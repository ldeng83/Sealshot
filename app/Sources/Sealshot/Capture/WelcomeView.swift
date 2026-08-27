import SwiftUI
import KeyboardShortcuts

/// First-launch welcome tour. The cards, and how many there are, come from
/// `WelcomeTourPage.visible()` — Intel Macs drop the smarter-redaction card,
/// whose model is arm64-only. Reappearance is controlled solely by the "Don't
/// show this again at startup" checkbox, which writes `WelcomePreference`.
///
/// Shortcut chips come from `WelcomeTourCopy`, which reads the LIVE binding —
/// never hardcode a combo here; it will drift out of sync with
/// `CaptureShortcuts` and teach the wrong keys.
struct WelcomeView: View {
    let onDone: () -> Void

    @State private var page = 0
    @State private var dontShowAgain = WelcomePreference.hasShown()

    private let pages = WelcomeTourPage.visible()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                Group {
                    // Clamped: `pages` is never empty, and the footer can only
                    // move `page` within it, but an out-of-range index would
                    // trap rather than merely misdraw.
                    switch pages[min(page, pages.count - 1)] {
                    case .privacy: privacyPage
                    case .captureRecord: captureRecordPage
                    case .smarterRedaction: smarterRedactionPage
                    case .editAnnotate: editAnnotatePage
                    case .findOrganize: findOrganizePage
                    case .shareProtect: shareProtectPage
                    case .permissions: permissionsPage
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxHeight: .infinity)

            footer
        }
        .padding(28)
        // Sized for the DENSEST card — Capture & record, whose six shortcut
        // rows plus two section headers clipped at the old 564 (the sixth row
        // cut in half behind a scrollbar). Still well under the 705 this was
        // before ac359e82 trimmed it, and it fits a 1440×900 display.
        .frame(width: 720, height: 624)
    }

    // MARK: - Pages

    private var privacyPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            header(title: "Welcome to Sealshot", symbol: nil)
            subtitle("Private screenshots: everything happens on your Mac.")
            VStack(spacing: 8) {
                item("wifi.slash", "No network, ever",
                     "Captures never leave your Mac.")
                item("person.crop.circle.badge.xmark", "No account, no telemetry",
                     "Nothing to sign up for; nothing is tracked.")
                item("cpu", "On-device detection",
                     "Sensitive-data detection runs locally.")
                if WelcomeTourCopy.showsFreeUseRow() {
                    item("heart", WelcomeTourCopy.freeUseTitle,
                         WelcomeTourCopy.freeUseDetail)
                }
            }
        }
    }

    private var captureRecordPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            header(title: "Capture & record", symbol: "camera.viewfinder")
            subtitle("Grab anything on screen — or record it. Shortcuts work in any app.")

            sectionHeader("Capture image")
            VStack(spacing: 8) {
                shortcut(.captureUnified, "Capture an area, window, or screen")
                shortcut(.captureDelayed, "Delayed capture (countdown)")
                shortcut(.captureScroll, "Scrolling capture (one tall image)")
                shortcut(.captureLive, "Live Capture (windows as movable layers)")
            }

            sectionHeader("Record video")
            VStack(spacing: 8) {
                shortcut(.recordToggle, "Record the screen (system + mic audio)")
                shortcut(.recordSelection, "Record a region or window")
            }
        }
    }

    private var smarterRedactionPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            header(title: "Smarter redaction", symbol: "wand.and.stars")
            subtitle("Download an optional on-device AI model for far more accurate, fully-local sensitive-info detection.")
            RedactionModelWelcomeCard()
        }
    }

    private var editAnnotatePage: some View {
        VStack(alignment: .leading, spacing: 16) {
            header(title: "Edit & annotate", symbol: "pencil.and.outline")
            subtitle("A full editor for every capture.")
            VStack(spacing: 8) {
                item("pencil.and.outline", "Annotate",
                     "Pen, shapes, arrows, text, and crop.")
                item("eye.slash", "Blur or box out",
                     "Hide anything by hand.")
                item("arrow.uturn.backward", "One undo for everything",
                     "⌘Z steps back through images, videos, and metadata edits alike.")
            }
        }
    }

    private var findOrganizePage: some View {
        VStack(alignment: .leading, spacing: 16) {
            header(title: "Find & organize", symbol: "magnifyingglass")
            subtitle("Your captures, searchable.")
            VStack(spacing: 8) {
                item("photo.on.rectangle.angled", "Library",
                     "Captures and recordings together — group them into Collections.")
                item("tag", "Tags & keywords",
                     "Keywords are suggested automatically; add your own tags.")
                item("text.magnifyingglass", "Find in Image",
                     "Search the text inside a capture (on-device OCR).")
                item("tablecells", "Extract Data",
                     "Pull tables out of a capture as CSV — on device.")
            }
        }
    }

    private var shareProtectPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            header(title: "Share & protect", symbol: "square.and.arrow.up")
            subtitle("Send captures without leaking anything.")
            VStack(spacing: 8) {
                item("photo", "Export to Image",
                     "Save one or many as PNG.")
                item("shippingbox", "Export to Package",
                     ".sealshare or .zip, optionally passcode-encrypted.")
                item("lock.shield", "Enhanced Security",
                     "Encrypt your library at rest.")
                item("key.horizontal", "Keep your Recovery Kit",
                     "Save or print it when you turn encryption on — without the "
                     + "recovery code, encrypted captures cannot be opened.")
            }
        }
    }

    private var permissionsPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            header(title: "Permissions", symbol: "checklist")
            subtitle("Grant what you need — Sealshot works the moment these are on.")
            PermissionStatusList(requirements: PermissionRequirement.appRequirements())
        }
    }

    // MARK: - Card header (accent badge + title)

    private func header(title: String, symbol: String?) -> some View {
        HStack(spacing: 14) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 54, height: 54)
                    .background(Color.accentColor.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Color.accentColor.opacity(0.25)))
            } else {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().frame(width: 54, height: 54)
            }
            Text(title).font(.title2.bold())
        }
    }

    private func subtitle(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 4)
    }

    // MARK: - Feature item (meaningful icon + title + description)

    private func item(_ symbol: String, _ title: String, _ desc: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 18))
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(desc).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
        }
        .cardRow()
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 12) {
            HStack {
                Toggle("Don't show this again at startup", isOn: $dontShowAgain)
                    .toggleStyle(.checkbox)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .onChange(of: dontShowAgain) { _, newValue in
                        WelcomePreference.setShown(newValue)
                    }
                Spacer()
            }
            HStack {
                if page > 0 {
                    Button("Back") { withAnimation { page -= 1 } }
                }
                Spacer()
                HStack(spacing: 6) {
                    ForEach(0..<pages.count, id: \.self) { i in
                        Circle()
                            .fill(i == page ? Color.accentColor : Color.secondary.opacity(0.35))
                            .frame(width: 7, height: 7)
                    }
                }
                Spacer()
                if page < pages.count - 1 {
                    Button("Next") { withAnimation { page += 1 } }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Get Started", action: onDone)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(.top, 12)
    }

    // MARK: - Shortcut rows

    /// Renders the shortcut CURRENTLY bound to `name` — the shipped default, or
    /// the user's own combo if they rebound it in Settings.
    private func shortcut(_ name: KeyboardShortcuts.Name, _ label: String) -> some View {
        let keys = WelcomeTourCopy.shortcutChips(for: name)
        return HStack(spacing: 12) {
            HStack(spacing: 4) {   // one chip per key, joined with "+"
                ForEach(Array(keys.enumerated()), id: \.offset) { i, key in
                    if i > 0 {
                        Text("+")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text(key)
                        .font(.system(.callout, design: .monospaced).weight(.semibold))
                        .frame(minWidth: 24)
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
                }
            }
            Text(label).font(.callout).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .cardRow()
    }
}

// MARK: - Shared filled-card row chrome

extension View {
    func cardRow() -> some View {
        self
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.05)))
    }
}
