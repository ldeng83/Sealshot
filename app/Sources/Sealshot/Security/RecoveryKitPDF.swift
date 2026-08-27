import SwiftUI
import AppKit
import PDFKit

/// One-page, printable "Recovery Kit" for the recovery code shown during the
/// ceremony (`RecoveryKeyCeremonyView`). Pure builder — all the values that
/// vary by environment (licensing, Mac name, current date) are resolved by
/// the caller and passed in, so this stays deterministic and testable.
enum RecoveryKitPDF {
    static let defaultFilename = "Sealshot Recovery Kit.pdf"

    /// US-Letter page size in points (72 dpi).
    static let pageSize = CGSize(width: 612, height: 792)

    /// Render the kit to PDF data via an offscreen `NSHostingView` of
    /// `RecoveryKitPage`.
    ///
    /// Guarantee: for fixed inputs, the *extracted text content* of the
    /// resulting PDF is identical across calls. Raw PDF bytes are **not**
    /// guaranteed to be identical — the PDF machinery stamps its own
    /// `/CreationDate` (and similar metadata) independent of the caller's
    /// `generatedAt`, so byte-for-byte comparisons can legitimately differ
    /// even when nothing meaningful changed.
    static func make(code: String, generatedAt: Date, macName: String,
                     licenseeLine: String?) -> Data {
        let page = RecoveryKitPage(code: code, generatedAt: generatedAt,
                                   macName: macName, licenseeLine: licenseeLine)
        let hostingView = NSHostingView(rootView: page)
        let frame = CGRect(origin: .zero, size: pageSize)
        hostingView.frame = frame

        // NSHostingView needs a real window to lay out and render text
        // correctly (a bare, unparented view produces a structurally valid
        // but visually empty PDF). Host it in an offscreen, never-ordered
        // NSWindow purely to give it that context.
        let window = NSWindow(contentRect: frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()

        let data = hostingView.dataWithPDF(inside: frame)
        window.orderOut(nil)
        if data.starts(with: Data("%PDF".utf8)), pdfContainsText(data, needle: code) {
            return data
        }
        // Fallback: some headless/offscreen contexts still render an empty
        // hosting view (no layer surface at all — e.g. certain CI sandboxes).
        // Draw the same content directly into a CGContext-backed PDF instead.
        return makeViaCoreGraphics(code: code, generatedAt: generatedAt,
                                   macName: macName, licenseeLine: licenseeLine)
    }

    /// Self-check: does the rendered PDF's extracted text actually contain
    /// `needle`? Used to detect the "structurally valid but visually empty"
    /// NSHostingView failure mode (an unparented/offscreen hosting view can
    /// produce a well-formed PDF with no drawn glyphs on some systems).
    private static func pdfContainsText(_ data: Data, needle: String) -> Bool {
        guard let document = PDFDocument(data: data), let text = document.string else {
            return false
        }
        return text.contains(needle)
    }

    /// Direct CoreGraphics fallback used when the `NSHostingView` render
    /// path produces an empty PDF (see `make`). Not `private` so it has its
    /// own direct unit test coverage — the whole reason it exists is to
    /// cover a failure mode of the primary path, so it needs to be provably
    /// correct on its own, not just reachable as a side effect of `make`.
    static func makeViaCoreGraphics(code: String, generatedAt: Date, macName: String,
                                            licenseeLine: String?) -> Data {
        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else { return Data() }

        context.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.current = nsContext

        var y = pageSize.height - 72

        func draw(_ text: String, font: NSFont, color: NSColor = .black, gap: CGFloat = 8) {
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let attributed = NSAttributedString(string: text, attributes: attrs)
            let bounds = attributed.boundingRect(with: CGSize(width: pageSize.width - 144,
                                                              height: .greatestFiniteMagnitude),
                                                 options: [.usesLineFragmentOrigin])
            y -= bounds.height
            attributed.draw(at: CGPoint(x: 72, y: y))
            y -= gap
        }

        draw("Sealshot Recovery Kit", font: .boldSystemFont(ofSize: 24))
        draw(code, font: .monospacedSystemFont(ofSize: RecoveryKitPage.codeFontSize(for: code),
                                               weight: .bold), gap: 16)

        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        draw("Generated: \(formatter.string(from: generatedAt))", font: .systemFont(ofSize: 12))
        draw("Mac: \(macName)", font: .systemFont(ofSize: 12))
        if let licenseeLine {
            draw(licenseeLine, font: .systemFont(ofSize: 12))
        }
        draw(" ", font: .systemFont(ofSize: 12), gap: 8)
        for line in RecoveryKitPage.instructionLines {
            draw(line, font: .systemFont(ofSize: 11), color: .darkGray)
        }

        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }
}

/// The visual layout used both for the offscreen `NSHostingView` render path
/// and (conceptually mirrored) by the CoreGraphics fallback in
/// `RecoveryKitPDF.makeViaCoreGraphics`.
struct RecoveryKitPage: View {
    let code: String
    let generatedAt: Date
    let macName: String
    let licenseeLine: String?

    static let instructionLines = [
        "This code is the only way to recover your encrypted Sealshot library.",
        "Sealshot support cannot recover an encrypted library without it.",
        "Store this page on paper, somewhere other than the Mac it protects.",
    ]

    private var dateText: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        return formatter.string(from: generatedAt)
    }

    /// Printable width available for content (page width minus the 72pt
    /// margins on both sides).
    static let printableWidth: CGFloat = RecoveryKitPDF.pageSize.width - 144

    /// Deterministic font size for the code so it always stays on one line.
    /// SwiftUI's `minimumScaleFactor` depends on a real layout/render pass
    /// that an offscreen `NSHostingView` doesn't reliably perform (it can
    /// silently clip instead of shrinking) — computing the size ourselves,
    /// from a conservative average monospaced advance width, keeps behavior
    /// deterministic regardless of host (also reused by the CoreGraphics
    /// fallback in `RecoveryKitPDF.makeViaCoreGraphics`). Real generated
    /// codes (29 chars) render at the full 20pt; longer codes shrink to fit.
    static func codeFontSize(for code: String) -> CGFloat {
        let maxSize: CGFloat = 20
        let minSize: CGFloat = 4
        let averageAdvance: CGFloat = 0.62 // fraction of point-size, monospaced
        guard !code.isEmpty else { return maxSize }
        let sizeThatFits = printableWidth / (CGFloat(code.count) * averageAdvance)
        return min(maxSize, max(minSize, sizeThatFits))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sealshot Recovery Kit").font(.system(size: 24, weight: .bold))
            Text(code).font(.system(size: Self.codeFontSize(for: code), weight: .bold,
                                    design: .monospaced))
                .lineLimit(1)
            Text("Generated: \(dateText)").font(.system(size: 12))
            Text("Mac: \(macName)").font(.system(size: 12))
            if let licenseeLine {
                Text(licenseeLine).font(.system(size: 12))
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Self.instructionLines, id: \.self) { line in
                    Text(line).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(72)
        .frame(width: RecoveryKitPDF.pageSize.width, height: RecoveryKitPDF.pageSize.height,
              alignment: .topLeading)
        .background(Color.white)
    }
}
