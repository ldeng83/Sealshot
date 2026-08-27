import SwiftUI
import AppKit

/// State for the Resize popover. Owned by the CONTROLLER (not the meta row):
/// Apply swaps the editor state, which rebuilds the meta row — the model
/// surviving that swap is what lets the popover stay open with the user's
/// unit/lock choices intact for iterative adjustment.
@MainActor
final class ResizePopoverModel: ObservableObject {
    /// The pristine visible size — Reset target, %-basis, and clamp basis.
    @Published var original: CGSize
    /// The document's current visible size (updates after each Apply).
    @Published var current: CGSize
    @Published var unit: ResizeMath.Unit = .pixels {
        didSet { refreshFieldTexts() }
    }
    @Published var dpiText = "\(Int(ResizeMath.defaultDPI))" {
        didSet { refreshFieldTexts() }
    }
    @Published var lockRatio = true
    @Published var widthText = ""
    @Published var heightText = ""
    /// The requested target in pixels (pre-clamp; clamped on Apply + shown).
    @Published private(set) var target: CGSize

    /// LIVE apply: fired (clamped) after every target change — typing, a
    /// stepper click, a preset, Reset. The controller debounces and resamples;
    /// there is no Apply button.
    var onTargetChanged: (CGSize) -> Void = { _ in }

    init(original: CGSize, current: CGSize) {
        self.original = original
        self.current = current
        self.target = current
        refreshFieldTexts()
    }

    var dpi: CGFloat {
        let v = CGFloat(Double(dpiText) ?? Double(ResizeMath.defaultDPI))
        return v > 0 ? v : ResizeMath.defaultDPI
    }

    var clampedTarget: CGSize { ResizeMath.clamped(target, original: original) }
    var clampNote: String? {
        let c = clampedTarget
        return (Int(c.width) != Int(target.width.rounded())
                || Int(c.height) != Int(target.height.rounded()))
            ? "capped at \(ResizeMath.maxUpscaleFactor.formatted())× original" : nil
    }

    func setTarget(_ t: CGSize) {
        target = t
        refreshFieldTexts()
        onTargetChanged(clampedTarget)
    }

    /// Parse both fields (width first, so a locked pair follows width when
    /// both were edited without committing) and fold into `target`.
    func commitFields() {
        commitField(axisIsWidth: true, text: widthText)
        commitField(axisIsWidth: false, text: heightText)
        refreshFieldTexts()
    }

    func commitField(axisIsWidth: Bool, text: String) {
        guard let v = Double(text.replacingOccurrences(of: ",", with: ".")), v > 0 else {
            refreshFieldTexts(); return
        }
        let axisOriginal = axisIsWidth ? original.width : original.height
        let px = ResizeMath.pixels(fromDisplay: CGFloat(v), unit: unit,
                                   originalAxis: axisOriginal, dpi: dpi)
        target = ResizeMath.applyingEdit(enteredPx: px, axisIsWidth: axisIsWidth,
                                         lockRatio: lockRatio, current: target)
        refreshFieldTexts()
        onTargetChanged(clampedTarget)
    }

    func applyPreset(percent: CGFloat) {
        setTarget(CGSize(width: original.width * percent / 100,
                         height: original.height * percent / 100))
    }

    func applyPreset(width: CGFloat) {
        let ratio = original.width > 0 ? original.height / original.width : 1
        setTarget(CGSize(width: width, height: (width * ratio).rounded()))
    }

    func resetToOriginal() { setTarget(original) }

    /// One stepper click: ±unitStep in the active unit (⌥ = ×10 via
    /// `multiplier`), folded through the same ratio-locked edit as typing.
    func nudge(axisIsWidth: Bool, direction: CGFloat, multiplier: CGFloat = 1) {
        let axisOriginal = axisIsWidth ? original.width : original.height
        let currentPx = axisIsWidth ? target.width : target.height
        let display = ResizeMath.displayValue(pixels: currentPx, unit: unit,
                                              originalAxis: axisOriginal, dpi: dpi)
        let next = display + ResizeMath.unitStep(unit) * direction * multiplier
        let px = ResizeMath.pixels(fromDisplay: next, unit: unit,
                                   originalAxis: axisOriginal, dpi: dpi)
        target = ResizeMath.applyingEdit(enteredPx: px, axisIsWidth: axisIsWidth,
                                         lockRatio: lockRatio, current: target)
        refreshFieldTexts()
        onTargetChanged(clampedTarget)
    }


    func refreshFieldTexts() {
        widthText = formatted(ResizeMath.displayValue(
            pixels: target.width, unit: unit, originalAxis: original.width, dpi: dpi))
        heightText = formatted(ResizeMath.displayValue(
            pixels: target.height, unit: unit, originalAxis: original.height, dpi: dpi))
    }

    private func formatted(_ v: CGFloat) -> String {
        unit == .pixels ? "\(Int(v.rounded()))"
                        : String(format: "%.2f", v)
    }
}

/// The Resize form, hosted in an NSPopover anchored above the meta row's
/// dimensions button. Apply keeps the popover open (iterative adjustment);
/// the popover's .transient behavior dismisses it on any outside click.
struct ResizePopoverView: View {
    @ObservedObject var model: ResizePopoverModel
    private enum Field: Hashable { case width, height, dpi }
    @FocusState private var focusedField: Field?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Single row: W · stepper · lock · H · stepper · unit.
            HStack(spacing: 8) {
                HStack(spacing: 3) {
                    TextField("Width", text: $model.widthText)
                        .frame(width: 68)
                        .focused($focusedField, equals: .width)
                        .onSubmit { model.commitField(axisIsWidth: true, text: model.widthText) }
                    VerticalStepper { direction, multiplier in
                        model.nudge(axisIsWidth: true, direction: direction, multiplier: multiplier)
                    }
                }
                lockButton
                HStack(spacing: 3) {
                    TextField("Height", text: $model.heightText)
                        .frame(width: 68)
                        .focused($focusedField, equals: .height)
                        .onSubmit { model.commitField(axisIsWidth: false, text: model.heightText) }
                    VerticalStepper { direction, multiplier in
                        model.nudge(axisIsWidth: false, direction: direction, multiplier: multiplier)
                    }
                }
                Picker("", selection: $model.unit) {
                    ForEach(ResizeMath.Unit.allCases, id: \.self) { Text($0.rawValue) }
                }
                .labelsHidden()
                .frame(width: 66)
            }
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12, design: .monospaced))

            if model.unit == .inches || model.unit == .centimeters {
                HStack(spacing: 6) {
                    Text("DPI").font(.caption).foregroundStyle(.secondary)
                    TextField("DPI", text: $model.dpiText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 52)
                        .focused($focusedField, equals: .dpi)
                    Text("used by physical units").font(.caption2).foregroundStyle(.secondary)
                }
            }

            // Two rows so every preset shows its full label (single-row chips
            // ellipsized: "640…").
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    ForEach([25, 50, 75], id: \.self) { pct in
                        chip("\(pct)%") { model.applyPreset(percent: CGFloat(pct)) }
                    }
                }
                HStack(spacing: 6) {
                    ForEach([640, 1280, 1920], id: \.self) { w in
                        chip("\(w) px wide") { model.applyPreset(width: CGFloat(w)) }
                    }
                }
            }

            HStack(spacing: 4) {
                Text("Result: \(Int(model.clampedTarget.width)) × \(Int(model.clampedTarget.height)) px")
                if let note = model.clampNote {
                    Text("— \(note)").foregroundStyle(.orange)
                }
                Text("· original \(Int(model.original.width)) × \(Int(model.original.height))")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)

            HStack {
                Button("Reset to original") { model.resetToOriginal() }
                    .disabled(Int(model.target.width) == Int(model.original.width)
                              && Int(model.target.height) == Int(model.original.height)
                              && Int(model.current.width) == Int(model.original.width)
                              && Int(model.current.height) == Int(model.original.height))
                Spacer()
                Text("changes apply live · ⌥-click steppers ×10")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(18)
        .frame(width: 380)
        // Clicking anywhere that steals focus COMMITS the field being left —
        // matching Enter — so a typed value is never silently dropped.
        .onChange(of: focusedField) { old, _ in
            switch old {
            case .width: model.commitField(axisIsWidth: true, text: model.widthText)
            case .height: model.commitField(axisIsWidth: false, text: model.heightText)
            case .dpi: model.refreshFieldTexts()
            case nil: break
            }
        }
        // Clicking the popover's background (not a control) drops field focus,
        // which commits via the onChange above.
        .contentShape(Rectangle())
        .onTapGesture { focusedField = nil }
    }

    /// Accent-tinted when engaged; hairline otherwise — matches the theme's
    /// quiet control chrome.
    private var lockButton: some View {
        Button {
            model.lockRatio.toggle()
        } label: {
            Image(systemName: "link")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(model.lockRatio ? Color.accentColor : .secondary)
                .padding(.horizontal, 6).padding(.vertical, 5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(model.lockRatio ? Color.accentColor.opacity(0.12) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .stroke(model.lockRatio ? Color.accentColor.opacity(0.5)
                                    : Color(nsColor: .separatorColor), lineWidth: 1))
        .help(model.lockRatio ? "Aspect ratio locked" : "Aspect ratio unlocked (free stretch)")
    }

    /// Pill preset chip — full label, never truncates.
    private func chip(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11))
                .padding(.horizontal, 11).padding(.vertical, 4)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background(Color(nsColor: .windowBackgroundColor), in: Capsule())
        .overlay(Capsule().stroke(Color(nsColor: .separatorColor), lineWidth: 1))
        .fixedSize()
    }
}

/// Compact macOS-style vertical ⌃/⌄ stepper glued to a numeric field.
/// ⌥-click steps ×10; click-and-hold auto-repeats.
private struct VerticalStepper: View {
    /// (direction: +1 up / −1 down, multiplier: 1 or 10 for ⌥)
    let onStep: (CGFloat, CGFloat) -> Void

    var body: some View {
        VStack(spacing: 0) {
            stepButton(direction: 1, symbol: "chevron.up")
            Divider().frame(width: 19)
            stepButton(direction: -1, symbol: "chevron.down")
        }
        .background(Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5)
            .stroke(Color(nsColor: .separatorColor), lineWidth: 1))
        .help("Step by the unit's increment · ⌥-click ×10 · hold to repeat")
    }

    private func stepButton(direction: CGFloat, symbol: String) -> some View {
        Button {
            let multiplier: CGFloat = NSEvent.modifierFlags.contains(.option) ? 10 : 1
            onStep(direction, multiplier)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 19, height: 11)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .buttonRepeatBehavior(.enabled)
    }
}
