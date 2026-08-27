import AppKit

/// Per-tool property panels for `EditorSidebarView`. Each factory builds
/// the controls the user can configure for that tool.
@MainActor
enum EditorToolPropertiesViews {

    private static var applierKey: UInt8 = 0

    /// A reusable color chip bound to `onPick`. `onSessionStart` (optional)
    /// fires when the palette opens, for undo grouping.
    static func colorField(initial: NSColor?, allowsNoColor: Bool,
                           onSessionStart: (() -> Void)? = nil,
                           onPick: @escaping (NSColor?) -> Void) -> ColorChipButton {
        let chip = ColorChipButton(color: initial, allowsNoColor: allowsNoColor)
        chip.onSessionStart = onSessionStart
        chip.onPick = onPick
        return chip
    }

    /// The tool-default Outline color chip (nil = no outline). Seeds
    /// `selectedOutlineColor`, grouped beside the Stroke chip in each panel.
    private static func outlineChip(state: EditorState) -> ColorChipButton {
        colorField(initial: state.selectedOutlineColor, allowsNoColor: true,
                   onPick: { color in state.selectedOutlineColor = color.map { opaqueSRGB($0) } })
    }

    static func make(
        for tool: EditorTool,
        state: EditorState,
        onCommitCrop: @escaping () -> Void,
        onCopyCrop: @escaping () -> Void = {},
        onCutCrop: @escaping () -> Void = {},
        onSoftCrop: @escaping () -> Void = {},
        onCopySelectedText: @escaping () -> Void,
        onCopyAllText: @escaping () -> Void,
        onLiveTextButtons: ((_ selected: ClosureButton, _ all: ClosureButton) -> Void)? = nil
    ) -> NSView {
        switch tool {
        case .select: return makeNeutral(state: state)  // selection cursor — neutral panel
        case .hand: return makeNeutral(state: state)    // pan tool — no properties
        case .textSelect: return makeTextSelect(hasText: state.liveTextHasText,
                                                onCopySelectedText: onCopySelectedText,
                                                onCopyAllText: onCopyAllText,
                                                onButtons: onLiveTextButtons)
        case .crop: return makeCrop(state: state,
                                    onCommitCrop: onCommitCrop,
                                    onCopyCrop: onCopyCrop,
                                    onCutCrop: onCutCrop,
                                    onSoftCrop: onSoftCrop)
        case .arrow: return makeArrow(state: state)
        case .rectangle: return makeRectangle(state: state)
        case .text: return makeText(state: state)
        case .ellipse: return makeEllipse(state: state)
        case .line: return makeLine(state: state)
        case .badge: return makeBadge(state: state)
        case .pen: return makePen(state: state)
        case .penArrow: return makePenArrow(state: state)
        case .blur: return makeBlur(state: state)
        }
    }

    /// Live Text panel: a hint plus "Copy Selected Text" and "Copy All Text".
    /// `onButtons` hands the two buttons back so the owner can flash a copy
    /// confirmation on the one that was triggered (button click or ⌘C).
    /// `hasText`: nil = idle/recognizing (unknown), true = text found,
    /// false = recognition completed with no text (disable copy + show hint).
    static func makeTextSelect(hasText: Bool?,
                               onCopySelectedText: @escaping () -> Void,
                               onCopyAllText: @escaping () -> Void,
                               onButtons: ((_ selected: ClosureButton, _ all: ClosureButton) -> Void)? = nil) -> NSView {
        let stack = verticalStack()
        let noText = (hasText == false)
        if noText {
            stack.addArrangedSubview(label("No text found in this image.", secondary: true))
        } else {
            stack.addArrangedSubview(label("Drag to select recognized text.", secondary: true))
            stack.addArrangedSubview(label("⌘C copy · ⌘A select all", secondary: true))
        }
        let selected = ClosureButton(title: "Copy Selected Text", onClick: onCopySelectedText)
        let all = ClosureButton(title: "Copy All Text", onClick: onCopyAllText)
        selected.isEnabled = !noText
        all.isEnabled = !noText
        stack.addArrangedSubview(selected)
        stack.addArrangedSubview(all)
        onButtons?(selected, all)
        return stack
    }

    // MARK: Object (selected annotation)

    /// Property panel for the currently selected annotation. Edits the
    /// selected object's style live, with one undo checkpoint per
    /// interaction (per slider drag / per color chip session).
    static func makeObject(state: EditorState) -> NSView {
        guard let annotation = state.selectedAnnotation else {
            let stack = verticalStack()
            stack.addArrangedSubview(label("No object selected.", secondary: true))
            return stack
        }
        return makeObjectControls(state: state, annotation: annotation)
    }

    /// The editable property controls for a *specific* annotation, bound to its
    /// id (not the primary selection) so the objects-list rows can each edit
    /// their own object inline. `makeObject` calls this with the primary.
    static func makeObjectControls(state: EditorState, annotation: Annotation) -> NSView {
        let stack = verticalStack()
        let id = annotation.id

        // Blur has its own self-contained panel (mode + strength), nothing in
        // common with the stroke/fill controls below.
        if case let .blur(region) = annotation.geometry {
            return makeBlurObjectControls(state: state, id: id, style: annotation.style, region: region)
        }

        let isRectangle: Bool
        let isText: Bool
        let isEllipse: Bool
        let isBadge: Bool
        let isImage: Bool
        switch annotation.geometry {
        case .rectangle: isRectangle = true;  isText = false; isEllipse = false; isBadge = false; isImage = false
        case .arrow:     isRectangle = false; isText = false; isEllipse = false; isBadge = false; isImage = false
        case .text:      isRectangle = false; isText = true;  isEllipse = false; isBadge = false; isImage = false
        case .ellipse:   isRectangle = false; isText = false; isEllipse = true;  isBadge = false; isImage = false
        case .line:      isRectangle = false; isText = false; isEllipse = false; isBadge = false; isImage = false
        case .badge:     isRectangle = false; isText = false; isEllipse = false; isBadge = true;  isImage = false
        case .pen:       isRectangle = false; isText = false; isEllipse = false; isBadge = false; isImage = false
        case .penArrow:  isRectangle = false; isText = false; isEllipse = false; isBadge = false; isImage = false
        case .blur:      isRectangle = false; isText = false; isEllipse = false; isBadge = false; isImage = false
        case .image:     isRectangle = false; isText = false; isEllipse = false; isBadge = false; isImage = true
        case .cut:       isRectangle = false; isText = false; isEllipse = false; isBadge = false; isImage = false
        }
        if isText {
            // Box-level controls applied uniformly to every run (per-word styling
            // stays via double-click editing). Two-column: caption ▸ control.
            let runs: [TextRun] = { if case let .text(_, r) = annotation.geometry { return r }; return [] }()
            let first = runs.first
            let al = annotation.style.textAlignment
            let alignIdx = al == .center ? 1 : (al == .right ? 2 : 0)
            let va = annotation.style.textVerticalAlignment
            let vIdx = va == .middle ? 1 : (va == .bottom ? 2 : 0)

            // Emphasis control built first so the Weight slider can clear Bold.
            let emphasis = emphasisGroup(
                bold: first?.isBold ?? false, italic: first?.isItalic ?? false,
                underline: first?.underline ?? false, strike: first?.strikethrough ?? false) { [weak state] b, i, u, s in
                    state?.recordUndoCheckpoint(action: "Text Style")
                    state?.updateTextRuns(id: id) { r in
                        for k in r.indices { r[k].isBold = b; r[k].isItalic = i; r[k].underline = u; r[k].strikethrough = s }
                    }
                }

            // — Font —
            toolSection(stack, "Font")
            stack.addArrangedSubview(fieldRow("Family", fontFamilyPopup(current: first?.fontFamily) { [weak state] fam in
                guard let state else { return }
                state.recordUndoCheckpoint(action: "Change Font")
                state.updateTextRuns(id: id) { r in for i in r.indices { r[i].fontFamily = fam } }
                state.textFontFamily = fam
                AnnotationTextFont.remembered = fam
            }))
            stack.addArrangedSubview(fieldRow("Weight", weightSlider(current: first?.weight,
                onDragStart: { [weak state] in state?.beginStyleEdit(); state?.recordUndoCheckpoint(action: "Change Weight") },
                onDragEnd: { [weak state] in state?.endStyleEdit() },
                onChange: { [weak state] w in
                    // Weight owns the weight axis now — clear Bold on the same runs
                    // and untick the Bold emphasis segment.
                    state?.updateTextRuns(id: id) { r in for i in r.indices { r[i].weight = w; r[i].isBold = false } }
                    emphasis.setSelected(false, forSegment: 0)
                })))
            stack.addArrangedSubview(fieldRow("Size", runValueSlider(
                value: Double(first?.fontSize ?? 18), min: 10, max: 200,
                onDragStart: { [weak state] in state?.beginStyleEdit(); state?.recordUndoCheckpoint(action: "Change Font Size") },
                onDragEnd: { [weak state] in state?.endStyleEdit() },
                onChange: { [weak state] v in state?.updateTextRuns(id: id) { r in for i in r.indices { r[i].fontSize = CGFloat(v) } } })))

            // — Emphasis —
            toolSection(stack, "Emphasis")
            stack.addArrangedSubview(fieldRow("Style", emphasis))

            // — Color — three chips in one row, caption above each.
            toolSection(stack, "Color")
            let colorApplier = TextRunColorApplier(state: state, id: id)
            let colorChip = colorField(
                initial: (first?.color ?? SerializableColor(.black)).nsColor, allowsNoColor: false,
                onSessionStart: { colorApplier.begin() },
                onPick: { colorApplier.pick($0) })
            objc_setAssociatedObject(colorChip, &Self.applierKey, colorApplier, .OBJC_ASSOCIATION_RETAIN)
            let highlightChip = colorField(
                initial: first?.highlight?.nsColor, allowsNoColor: true,
                onSessionStart: { [weak state] in state?.recordUndoCheckpoint(action: "Highlight") },
                onPick: { [weak state] c in state?.updateTextRuns(id: id) { r in for i in r.indices { r[i].highlight = c.map { SerializableColor(opaqueSRGB($0)) } } } })
            let outlineChip = colorField(
                initial: first?.outlineColor?.nsColor, allowsNoColor: true,
                onSessionStart: { [weak state] in state?.recordUndoCheckpoint(action: "Outline") },
                onPick: { [weak state] c in state?.updateTextRuns(id: id) { r in for i in r.indices { r[i].outlineColor = c.map { SerializableColor(opaqueSRGB($0)) } } } })
            let colorRow = NSStackView(views: [chipColumn("Text", colorChip),
                                               chipColumn("Highlight", highlightChip),
                                               chipColumn("Outline", outlineChip)])
            colorRow.orientation = .horizontal
            colorRow.spacing = 18
            colorRow.alignment = .top
            // Default gravity distribution (not .equalSpacing): keep the three
            // chips left-packed with a fixed gap so their spacing doesn't shift
            // as chip widths change (e.g. Highlight/Outline toggling no-color)
            // while clicking around other properties.
            stack.addArrangedSubview(colorRow)
            stack.addArrangedSubview(fieldRow("Outline w", runValueSlider(
                value: Double(first?.outlineWidth ?? 6), min: 1, max: 20, unit: "%",
                onDragStart: { [weak state] in state?.beginStyleEdit(); state?.recordUndoCheckpoint(action: "Outline Width") },
                onDragEnd: { [weak state] in state?.endStyleEdit() },
                onChange: { [weak state] v in state?.updateTextRuns(id: id) { r in for i in r.indices { r[i].outlineWidth = CGFloat(v) } } })))

            // — Paragraph —
            toolSection(stack, "Paragraph")
            stack.addArrangedSubview(fieldRow("Align", iconChoice(
                ["text.alignleft", "text.aligncenter", "text.alignright"], selected: alignIdx) { [weak state] idx in
                    state?.recordUndoCheckpoint(action: "Align")
                    let a: TextAlignment = idx == 1 ? .center : (idx == 2 ? .right : .left)
                    state?.updateTextBoxStyle(id: id) { $0.textAlignment = a }
                }))
            stack.addArrangedSubview(fieldRow("Vertical", iconChoice(
                ["arrow.up.to.line", "arrow.up.and.down", "arrow.down.to.line"], selected: vIdx) { [weak state] idx in
                    state?.recordUndoCheckpoint(action: "Vertical Align")
                    let v: TextVerticalAlignment = idx == 1 ? .middle : (idx == 2 ? .bottom : .top)
                    state?.updateTextBoxStyle(id: id) { $0.textVerticalAlignment = v }
                }))
            stack.addArrangedSubview(fieldRow("Line sp.", runValueSlider(
                value: Double(annotation.style.lineSpacing), min: 0, max: 40,
                onDragStart: { [weak state] in state?.beginStyleEdit(); state?.recordUndoCheckpoint(action: "Line Spacing") },
                onDragEnd: { [weak state] in state?.endStyleEdit() },
                onChange: { [weak state] v in state?.updateTextBoxStyle(id: id) { $0.lineSpacing = CGFloat(v) } })))

            // — Opacity — (same runValueSlider layout as the inline / tool-default
            // text panels, so the three read identically when rotating states)
            toolSection(stack, "Opacity")
            stack.addArrangedSubview(runValueSlider(
                value: annotation.style.opacity * 100, min: 10, max: 100, unit: "%",
                onDragStart: { [weak state] in state?.beginStyleEdit(); state?.recordUndoCheckpoint(action: "Opacity") },
                onDragEnd: { [weak state] in state?.endStyleEdit() },
                onChange: { [weak state] v in state?.updateStyle(id: id) { $0.opacity = v / 100.0 } }))

            addArrangeSection(to: stack, state: state)
            addTransformSection(to: stack, state: state, annotation: annotation)
            toolSection(stack, "Effects")
            stack.addArrangedSubview(shadowRow(
                read: { [weak state] in
                    state?.annotations.first(where: { $0.id == id })?.style.shadow ?? .off
                },
                write: { [weak state] s in
                    state?.updateStyle(id: id) { $0.shadow = s }
                },
                onEditBegin: { [weak state] in
                    state?.recordUndoCheckpoint(action: "Change Shadow")
                },
                onSessionBegin: { [weak state] in state?.beginStyleEdit() },
                onSessionEnd: { [weak state] in state?.endStyleEdit() }))
            return stack
        }

        if isBadge {
            // Number (digit) + Fill (disc) colors, shoulder-to-shoulder with
            // Number on the left — same layout as the shape Stroke/Fill row.
            toolSection(stack, "Color")
            let numApplier = StyleColorApplier(state: state, id: id) { style, color in
                if let color = color { style.strokeColor = SerializableColor(opaqueSRGB(color)) }
            }
            let numChip = colorField(
                initial: annotation.style.strokeColor.nsColor, allowsNoColor: false,
                onSessionStart: { numApplier.begin() },
                onPick: { numApplier.pick($0) })
            objc_setAssociatedObject(numChip, &Self.applierKey, numApplier, .OBJC_ASSOCIATION_RETAIN)

            let fillApplier = StyleColorApplier(state: state, id: id) { style, color in
                if let color = color { style.fillColor = SerializableColor(opaqueSRGB(color)) }
            }
            let fillChip = colorField(
                initial: (annotation.style.fillColor ?? SerializableColor(.systemRed)).nsColor, allowsNoColor: false,
                onSessionStart: { fillApplier.begin() },
                onPick: { fillApplier.pick($0) })
            objc_setAssociatedObject(fillChip, &Self.applierKey, fillApplier, .OBJC_ASSOCIATION_RETAIN)

            let badgeOutlineApplier = StyleColorApplier(state: state, id: id) { style, color in
                style.outlineColor = color.map { SerializableColor(opaqueSRGB($0)) }
            }
            let badgeOutlineChip = colorField(
                initial: annotation.style.outlineColor?.nsColor, allowsNoColor: true,
                onSessionStart: { badgeOutlineApplier.begin() },
                onPick: { badgeOutlineApplier.pick($0) })
            objc_setAssociatedObject(badgeOutlineChip, &Self.applierKey, badgeOutlineApplier, .OBJC_ASSOCIATION_RETAIN)
            stack.addArrangedSubview(colorColumnsRow([("Number", numChip), ("Fill", fillChip),
                                                      ("Outline", badgeOutlineChip)]))

            toolSection(stack, "Size")
            let currentRadius: CGFloat = {
                if case let .badge(_, r) = annotation.geometry { return r }
                return state.badgeRadius
            }()
            let radiusHandler = BadgeRadiusHandler(state: state, id: id)
            let radiusSlider = StyleEditSlider(value: Double(currentRadius), minValue: 8, maxValue: 60,
                                               target: radiusHandler,
                                               action: #selector(BadgeRadiusHandler.changed(_:)))
            radiusSlider.onDragStart = { [weak state] in state?.beginStyleEdit(); state?.recordUndoCheckpoint(action: "Change Size") }
            radiusSlider.onDragEnd = { [weak state] in state?.endStyleEdit() }
            radiusSlider.isContinuous = true
            radiusSlider.translatesAutoresizingMaskIntoConstraints = false
            radiusSlider.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
            objc_setAssociatedObject(radiusSlider, &BadgeRadiusHandler.assocKey, radiusHandler, .OBJC_ASSOCIATION_RETAIN)
            stack.addArrangedSubview(radiusSlider)

            toolSection(stack, "Outline width")
            stack.addArrangedSubview(styleSlider(
                state: state, id: id, value: Double(annotation.style.outlineWidth),
                min: 1, max: 20, unit: "pt"
            ) { $0.outlineWidth = CGFloat($1) })

            toolSection(stack, "Opacity")
            stack.addArrangedSubview(styleSlider(
                state: state, id: id, value: annotation.style.opacity * 100, min: 10, max: 100, unit: "%"
            ) { $0.opacity = $1 / 100.0 })

            addArrangeSection(to: stack, state: state)
            addTransformSection(to: stack, state: state, annotation: annotation)
            toolSection(stack, "Effects")
            stack.addArrangedSubview(shadowRow(
                read: { [weak state] in
                    state?.annotations.first(where: { $0.id == id })?.style.shadow ?? .off
                },
                write: { [weak state] s in
                    state?.updateStyle(id: id) { $0.shadow = s }
                },
                onEditBegin: { [weak state] in
                    state?.recordUndoCheckpoint(action: "Change Shadow")
                },
                onSessionBegin: { [weak state] in state?.beginStyleEdit() },
                onSessionEnd: { [weak state] in state?.endStyleEdit() }))
            return stack
        }

        if isImage {
            toolSection(stack, "Opacity")
            stack.addArrangedSubview(styleSlider(
                state: state, id: id, value: annotation.style.opacity * 100,
                min: 10, max: 100, unit: "%"
            ) { $0.opacity = $1 / 100.0 })

            toolSection(stack, "Image")
            let replaceHandler = ReplaceImageHandler(state: state, id: id)
            let replace = NSButton(title: "Replace…", target: replaceHandler,
                                   action: #selector(ReplaceImageHandler.replace))
            replace.bezelStyle = .rounded
            objc_setAssociatedObject(replace, &ReplaceImageHandler.assocKey,
                                     replaceHandler, .OBJC_ASSOCIATION_RETAIN)
            stack.addArrangedSubview(replace)
            addArrangeSection(to: stack, state: state)
            addTransformSection(to: stack, state: state, annotation: annotation)
            return stack
        }

        // Color — stroke and (for rectangles/ellipses) fill chips side by side;
        // each chip opens the color palette popover.
        toolSection(stack, "Color")

        let strokeApplier = StyleColorApplier(state: state, id: id) { style, color in
            if let color = color { style.strokeColor = SerializableColor(opaqueSRGB(color)) }
        }
        let strokeChip = colorField(
            initial: annotation.style.strokeColor.nsColor, allowsNoColor: false,
            onSessionStart: { strokeApplier.begin() },
            onPick: { strokeApplier.pick($0) })
        objc_setAssociatedObject(strokeChip, &Self.applierKey, strokeApplier, .OBJC_ASSOCIATION_RETAIN)
        var columns: [(title: String, chip: NSView)] = [("Stroke", strokeChip)]

        if isRectangle || isEllipse {
            let fillApplier = StyleColorApplier(state: state, id: id) { style, color in
                style.fillColor = color.map { SerializableColor(opaqueSRGB($0)) }
            }
            let fillChip = colorField(
                initial: annotation.style.fillColor?.nsColor, allowsNoColor: true,
                onSessionStart: { fillApplier.begin() },
                onPick: { fillApplier.pick($0) })
            objc_setAssociatedObject(fillChip, &Self.applierKey, fillApplier, .OBJC_ASSOCIATION_RETAIN)
            columns.append(("Fill", fillChip))
        }
        // Outline (casing) color — grouped beside Stroke/Fill; allowsNoColor = off.
        let outlineApplier = StyleColorApplier(state: state, id: id) { style, color in
            style.outlineColor = color.map { SerializableColor(opaqueSRGB($0)) }
        }
        let outlineObjChip = colorField(
            initial: annotation.style.outlineColor?.nsColor, allowsNoColor: true,
            onSessionStart: { outlineApplier.begin() },
            onPick: { outlineApplier.pick($0) })
        objc_setAssociatedObject(outlineObjChip, &Self.applierKey, outlineApplier, .OBJC_ASSOCIATION_RETAIN)
        columns.append(("Outline", outlineObjChip))
        stack.addArrangedSubview(colorColumnsRow(columns))

        toolSection(stack, "Stroke width")
        stack.addArrangedSubview(styleSlider(
            state: state, id: id, value: Double(annotation.style.strokeWidth),
            min: (isRectangle || isEllipse) ? 0 : 1, max: 50, unit: "pt"
        ) { $0.strokeWidth = CGFloat($1) })

        toolSection(stack, "Outline width")
        stack.addArrangedSubview(styleSlider(
            state: state, id: id, value: Double(annotation.style.outlineWidth),
            min: 1, max: 20, unit: "pt"
        ) { $0.outlineWidth = CGFloat($1) })

        toolSection(stack, "Opacity")
        stack.addArrangedSubview(styleSlider(
            state: state, id: id, value: annotation.style.opacity * 100, min: 10, max: 100, unit: "%"
        ) { $0.opacity = $1 / 100.0 })

        // Arrowheads (straight arrow & free arrow) + dash style (arrow & line).
        let isArrow: Bool = { if case .arrow = annotation.geometry { return true }; return false }()
        let isLine: Bool = { if case .line = annotation.geometry { return true }; return false }()
        let isPenArrow: Bool = { if case .penArrow = annotation.geometry { return true }; return false }()
        if isArrow || isPenArrow {
            toolSection(stack, "Arrowheads")
            let startPopup = stylePopUp(
                state: state, id: id, titles: arrowCapTitles,
                selectedIndex: arrowCapOrder.firstIndex(of: annotation.style.startCap) ?? 0
            ) { $0.startCap = arrowCapOrder[$1] }
            setItemImages(startPopup, arrowCapOrder.map { capSampleImage($0, atStart: true) })
            stack.addArrangedSubview(labeledColumn("Start", startPopup))

            let endPopup = stylePopUp(
                state: state, id: id, titles: arrowCapTitles,
                selectedIndex: arrowCapOrder.firstIndex(of: annotation.style.endCap) ?? 0
            ) { $0.endCap = arrowCapOrder[$1] }
            setItemImages(endPopup, arrowCapOrder.map { capSampleImage($0, atStart: false) })
            stack.addArrangedSubview(labeledColumn("End", endPopup))
        }
        if isArrow {
            // Straight arrows only — freehand arrows always render uniform.
            toolSection(stack, "Shaft")
            let shaftOrder: [ShaftStyle] = [.tapered, .uniform]
            let shaftPopup = stylePopUp(
                state: state, id: id, titles: ["Tapered", "Uniform"],
                selectedIndex: shaftOrder.firstIndex(of: annotation.style.shaftStyle) ?? 0
            ) { $0.shaftStyle = shaftOrder[$1] }
            stack.addArrangedSubview(labeledColumn("Profile", shaftPopup))
        }
        if isArrow || isLine {
            toolSection(stack, "Line style")
            let dashPopup = stylePopUp(
                state: state, id: id, titles: dashTitles,
                selectedIndex: dashOrder.firstIndex(of: annotation.style.dashStyle) ?? 0
            ) { $0.dashStyle = dashOrder[$1] }
            setItemImages(dashPopup, dashOrder.map { dashSampleImage($0) })
            stack.addArrangedSubview(dashPopup)
        }

        if isRectangle {
            toolSection(stack, "Corner radius")
            stack.addArrangedSubview(styleSlider(
                state: state, id: id, value: Double(annotation.style.cornerRadius), min: 0, max: 40
            ) { $0.cornerRadius = CGFloat($1) })
        }

        addArrangeSection(to: stack, state: state)
        addTransformSection(to: stack, state: state, annotation: annotation)
        toolSection(stack, "Effects")
        stack.addArrangedSubview(shadowRow(
            read: { [weak state] in
                state?.annotations.first(where: { $0.id == id })?.style.shadow ?? .off
            },
            write: { [weak state] s in
                state?.updateStyle(id: id) { $0.shadow = s }
            },
            onEditBegin: { [weak state] in
                state?.recordUndoCheckpoint(action: "Change Shadow")
            },
            onSessionBegin: { [weak state] in state?.beginStyleEdit() },
            onSessionEnd: { [weak state] in state?.endStyleEdit() }))
        return stack
    }

    /// Depth controls — identical on every object panel (arrangement is
    /// selection-only, so there is no tool-default analog).
    private static func addArrangeSection(to stack: NSStackView, state: EditorState) {
        toolSection(stack, "Arrange")
        let handler = ZOrderButtonsHandler(state: state)
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 6
        let buttons: [(String, String, Selector)] = [
            ("square.3.layers.3d.top.filled", "Bring to Front (⌥⌘])",
             #selector(ZOrderButtonsHandler.toFront)),
            ("square.2.layers.3d.top.filled", "Bring Forward (⌘])",
             #selector(ZOrderButtonsHandler.forward)),
            ("square.2.layers.3d.bottom.filled", "Send Backward (⌘[)",
             #selector(ZOrderButtonsHandler.backward)),
            ("square.3.layers.3d.bottom.filled", "Send to Back (⌥⌘[)",
             #selector(ZOrderButtonsHandler.toBack)),
        ]
        for (symbol, help, action) in buttons {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)
                ?? NSImage(systemSymbolName: "square.3.stack.3d", accessibilityDescription: help)!
            let b = NSButton(image: image, target: handler, action: action)
            b.bezelStyle = .texturedRounded
            b.toolTip = help
            row.addArrangedSubview(b)
        }
        objc_setAssociatedObject(row, &ZOrderButtonsHandler.assocKey, handler,
                                 .OBJC_ASSOCIATION_RETAIN)
        stack.addArrangedSubview(row)
    }

    /// Rotation + flips — on every object panel (selection-only, like
    /// Arrange). Flip buttons are omitted for text/badge, where glyph
    /// mirroring is never wanted.
    private static func addTransformSection(to stack: NSStackView, state: EditorState,
                                            annotation: Annotation) {
        toolSection(stack, "Transform")
        let handler = TransformControlsHandler(state: state, id: annotation.id)
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 6

        let field = NSTextField(string: "\(Int(annotation.transform.rotationDegrees.rounded()))")
        field.widthAnchor.constraint(equalToConstant: 48).isActive = true
        field.alignment = .right
        field.target = handler
        field.action = #selector(TransformControlsHandler.angleEntered(_:))
        let degrees = NSTextField(labelWithString: "°")
        let stepper = NSStepper()
        stepper.minValue = -180; stepper.maxValue = 179
        stepper.increment = 1
        stepper.valueWraps = true
        stepper.integerValue = Int(annotation.transform.rotationDegrees.rounded())
        stepper.target = handler
        stepper.action = #selector(TransformControlsHandler.stepperChanged(_:))
        handler.field = field; handler.stepper = stepper
        row.addArrangedSubview(field)
        row.addArrangedSubview(degrees)
        row.addArrangedSubview(stepper)

        if EditorState.isFlippable(annotation.geometry) {
            let buttons: [(String, String, Selector)] = [
                ("arrow.left.and.right.righttriangle.left.righttriangle.right",
                 "Flip Horizontal", #selector(TransformControlsHandler.flipH)),
                ("arrow.up.and.down.righttriangle.up.righttriangle.down",
                 "Flip Vertical", #selector(TransformControlsHandler.flipV)),
            ]
            for (symbol, help, action) in buttons {
                let image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)
                    ?? NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: help)!
                let b = NSButton(image: image, target: handler, action: action)
                b.bezelStyle = .texturedRounded
                b.toolTip = help
                row.addArrangedSubview(b)
            }
        }
        objc_setAssociatedObject(row, &TransformControlsHandler.assocKey, handler,
                                 .OBJC_ASSOCIATION_RETAIN)
        stack.addArrangedSubview(row)
    }

    /// Live text styling bound to the active edit session (applies to the
    /// current selection). Color, font size, bold.
    /// A font-family dropdown: "System" + every installed family, each row drawn
    /// in its own font. `current` (nil = System) is preselected; `onPick` gets
    /// the chosen family (nil for System). "Full fonts" per the design.
    static func fontFamilyPopup(current: String?, onPick: @escaping (String?) -> Void) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        let handler = FontFamilyPopupHandler(onPick: onPick)
        popup.target = handler
        popup.action = #selector(FontFamilyPopupHandler.changed(_:))
        objc_setAssociatedObject(popup, &FontFamilyPopupHandler.assocKey, handler, .OBJC_ASSOCIATION_RETAIN)

        let systemItem = NSMenuItem(title: "System", action: nil, keyEquivalent: "")
        systemItem.attributedTitle = NSAttributedString(
            string: "System", attributes: [.font: NSFont.systemFont(ofSize: 13)])
        popup.menu?.addItem(systemItem)
        popup.menu?.addItem(.separator())

        for fam in NSFontManager.shared.availableFontFamilies.sorted() {
            let item = NSMenuItem(title: fam, action: nil, keyEquivalent: "")
            let preview = NSFontManager.shared.font(withFamily: fam, traits: [], weight: 5, size: 13)
                ?? NSFont.systemFont(ofSize: 13)
            item.attributedTitle = NSAttributedString(string: fam, attributes: [.font: preview])
            item.representedObject = fam
            popup.menu?.addItem(item)
        }

        if let current, !isSystemFontFamily(current), popup.item(withTitle: current) != nil {
            popup.selectItem(withTitle: current)
        } else {
            popup.selectItem(withTitle: "System")
        }
        return popup
    }

    /// A labelled on/off switch row wired to a closure.
    static func styleToggleRow(_ title: String, initial: Bool,
                               onChange: @escaping (Bool) -> Void) -> NSView {
        let row = NSStackView(); row.orientation = .horizontal; row.spacing = 8
        let sw = NSSwitch(); sw.state = initial ? .on : .off
        let h = SwitchHandler(onChange)
        sw.target = h; sw.action = #selector(SwitchHandler.toggled(_:))
        objc_setAssociatedObject(sw, &SwitchHandler.assocKey, h, .OBJC_ASSOCIATION_RETAIN)
        row.addArrangedSubview(sw); row.addArrangedSubview(label(title))
        return row
    }


    /// A fixed-width, left-aligned caption for a two-column (label ▸ control)
    /// row. The fixed width keeps every control's left edge aligned.
    private static func fieldLabel(_ text: String) -> NSTextField {
        let l = label(text, secondary: true)
        l.alignment = .left
        l.setContentHuggingPriority(.required, for: .horizontal)
        l.setContentCompressionResistancePriority(.required, for: .horizontal)
        l.widthAnchor.constraint(equalToConstant: 64).isActive = true
        return l
    }

    /// One two-column row: right-aligned caption on the left, control on the right.
    static func fieldRow(_ title: String, _ control: NSView) -> NSView {
        let row = NSStackView(views: [fieldLabel(title), control])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }

    /// Multi-select icon group for character emphasis (Bold / Italic / Underline
    /// / Strikethrough), each segment toggling independently.
    static func emphasisGroup(bold: Bool, italic: Bool, underline: Bool, strike: Bool,
                              onChange: @escaping (Bool, Bool, Bool, Bool) -> Void) -> NSSegmentedControl {
        let syms = ["bold", "italic", "underline", "strikethrough"]
        let seg = NSSegmentedControl()
        seg.segmentCount = syms.count
        seg.trackingMode = .selectAny
        for (i, s) in syms.enumerated() {
            seg.setImage(NSImage(systemSymbolName: s, accessibilityDescription: s), forSegment: i)
            seg.setWidth(34, forSegment: i)
        }
        seg.setSelected(bold, forSegment: 0)
        seg.setSelected(italic, forSegment: 1)
        seg.setSelected(underline, forSegment: 2)
        seg.setSelected(strike, forSegment: 3)
        let h = EmphasisHandler(onChange)
        seg.target = h; seg.action = #selector(EmphasisHandler.changed(_:))
        objc_setAssociatedObject(seg, &EmphasisHandler.assocKey, h, .OBJC_ASSOCIATION_RETAIN)
        seg.translatesAutoresizingMaskIntoConstraints = false
        return seg
    }

    /// Single-select icon group (e.g. alignment), reporting the chosen index.
    static func iconChoice(_ symbols: [String], selected: Int,
                           onSelect: @escaping (Int) -> Void) -> NSSegmentedControl {
        let seg = NSSegmentedControl()
        seg.segmentCount = symbols.count
        seg.trackingMode = .selectOne
        for (i, s) in symbols.enumerated() {
            seg.setImage(NSImage(systemSymbolName: s, accessibilityDescription: s), forSegment: i)
            seg.setWidth(34, forSegment: i)
        }
        seg.selectedSegment = selected
        let h = IconChoiceHandler(onSelect)
        seg.target = h; seg.action = #selector(IconChoiceHandler.changed(_:))
        objc_setAssociatedObject(seg, &IconChoiceHandler.assocKey, h, .OBJC_ASSOCIATION_RETAIN)
        seg.translatesAutoresizingMaskIntoConstraints = false
        return seg
    }

    /// A `StyleEditSlider` wired to a closure (image-space value) with a live
    /// integer read-out (+ optional `unit`) on the right, flexible width.
    static func runValueSlider(value: Double, min: Double, max: Double, unit: String = "",
                               onDragStart: @escaping () -> Void, onDragEnd: @escaping () -> Void,
                               onChange: @escaping (Double) -> Void) -> NSView {
        let valueLabel = NSTextField(labelWithString: "\(Int(value.rounded()))\(unit)")
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        valueLabel.alignment = .right
        valueLabel.textColor = .labelColor
        valueLabel.setContentHuggingPriority(.required, for: .horizontal)
        valueLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 34).isActive = true
        let handler = ClosureSliderHandler(apply: { v in
            valueLabel.stringValue = "\(Int(v.rounded()))\(unit)"
            onChange(v)
        })
        let slider = StyleEditSlider(value: value, minValue: min, maxValue: max,
                                     target: handler, action: #selector(ClosureSliderHandler.changed(_:)))
        slider.onDragStart = onDragStart
        slider.onDragEnd = onDragEnd
        slider.isContinuous = true
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true
        objc_setAssociatedObject(slider, &ClosureSliderHandler.assocKey, handler, .OBJC_ASSOCIATION_RETAIN)
        let row = NSStackView(views: [slider, valueLabel])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        return row
    }

    /// A discrete slider over the 8 named weights (Ultralight…Black) with a name
    /// read-out — the draggable replacement for the weight popup. Snaps to whole
    /// steps and reports the chosen `TextWeight`. `onDragStart`/`onDragEnd` bracket
    /// the drag for one undo checkpoint + rebuild suppression (pass empty closures
    /// where those don't apply, e.g. the inline/tool-default panels).
    static func weightSlider(current: TextWeight?,
                             onDragStart: @escaping () -> Void, onDragEnd: @escaping () -> Void,
                             onChange: @escaping (TextWeight) -> Void) -> NSView {
        let weights: [TextWeight] = [.ultralight, .light, .regular, .medium, .semibold, .bold, .heavy, .black]
        let names = ["Ultralight", "Light", "Regular", "Medium", "Semibold", "Bold", "Heavy", "Black"]
        let curIdx = current.flatMap { weights.firstIndex(of: $0) } ?? 2   // default = Regular
        let valueLabel = NSTextField(labelWithString: names[curIdx])
        valueLabel.font = .systemFont(ofSize: 11, weight: .medium)
        valueLabel.alignment = .right
        valueLabel.textColor = .labelColor
        valueLabel.lineBreakMode = .byClipping
        // FIXED width (fits the longest name, "Ultralight") so switching weights
        // never changes the row — and hence the panel — width. A flexible label
        // would resize the panel and make the color row's equal-spacing jump.
        valueLabel.setContentHuggingPriority(.required, for: .horizontal)
        valueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        valueLabel.widthAnchor.constraint(equalToConstant: 72).isActive = true
        let handler = ClosureSliderHandler(apply: { v in
            let idx = Swift.max(0, Swift.min(weights.count - 1, Int(v.rounded())))
            valueLabel.stringValue = names[idx]
            onChange(weights[idx])
        })
        let slider = StyleEditSlider(value: Double(curIdx), minValue: 0, maxValue: Double(weights.count - 1),
                                     target: handler, action: #selector(ClosureSliderHandler.changed(_:)))
        slider.onDragStart = onDragStart
        slider.onDragEnd = onDragEnd
        slider.numberOfTickMarks = weights.count
        slider.allowsTickMarkValuesOnly = true
        slider.isContinuous = true
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true
        objc_setAssociatedObject(slider, &ClosureSliderHandler.assocKey, handler, .OBJC_ASSOCIATION_RETAIN)
        let row = NSStackView(views: [slider, valueLabel])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        return row
    }

    /// A fixed-height empty view used to space sub-sections apart.
    private static func gap(_ h: CGFloat = 12) -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: h).isActive = true
        return v
    }

    /// A caption centered above a control (used for the Color chip row).
    private static func chipColumn(_ caption: String, _ chip: NSView) -> NSView {
        let cap = label(caption, secondary: true)
        cap.alignment = .center
        let col = NSStackView(views: [cap, chip])
        col.orientation = .vertical
        col.spacing = 4
        col.alignment = .centerX
        return col
    }

    /// The inline text-editing panel. Mirrors the selected-text-object panel
    /// (`makeObjectControls` text branch) but binds to the live `session` — so
    /// creating a text and editing it inline exposes the same controls. Character
    /// and paragraph edits preview live; vertical-align and opacity take effect on
    /// commit.
    static func makeTextEditing(session: TextEditingSession) -> NSView {
        let stack = verticalStack()
        let al = session.alignment
        let alignIdx = al == .center ? 1 : (al == .right ? 2 : 0)
        let va = session.verticalAlignment
        let vIdx = va == .middle ? 1 : (va == .bottom ? 2 : 0)

        // Emphasis control built first so the Weight slider can clear Bold.
        let emphasis = emphasisGroup(
            bold: session.isBold ?? false, italic: session.isItalic,
            underline: session.underline, strike: session.strikethrough) { [weak session] b, i, u, s in
                session?.setBold(b); session?.setItalic(i); session?.setUnderline(u); session?.setStrikethrough(s)
            }

        // — Font —
        toolSection(stack, "Font")
        stack.addArrangedSubview(fieldRow("Family", fontFamilyPopup(current: session.fontFamily) { [weak session] fam in
            session?.applyFontFamily(fam)
        }))
        stack.addArrangedSubview(fieldRow("Weight", weightSlider(current: session.weight,
            onDragStart: {}, onDragEnd: {},
            onChange: { [weak session] w in
                session?.applyWeight(w)
                // Weight owns the weight axis now — clear the Bold emphasis toggle.
                if session?.isBold == true { session?.setBold(false); emphasis.setSelected(false, forSegment: 0) }
            })))
        stack.addArrangedSubview(fieldRow("Size", runValueSlider(
            value: Double(session.fontSize ?? 18), min: 10, max: 200,
            onDragStart: {}, onDragEnd: {},
            onChange: { [weak session] v in session?.applyFontSize(CGFloat(v)) })))

        // — Emphasis —
        toolSection(stack, "Emphasis")
        stack.addArrangedSubview(fieldRow("Style", emphasis))

        // — Color —
        toolSection(stack, "Color")
        let colorChip = colorField(initial: session.color ?? .black, allowsNoColor: false,
                                   onPick: { [weak session] in if let c = $0 { session?.applyColor(c) } })
        let highlightChip = colorField(initial: session.highlight, allowsNoColor: true,
                                       onPick: { [weak session] in session?.applyHighlight($0) })
        let outlineChip = colorField(initial: session.outlineColor, allowsNoColor: true,
                                     onPick: { [weak session] in session?.applyOutline($0) })
        let colorRow = NSStackView(views: [chipColumn("Text", colorChip),
                                           chipColumn("Highlight", highlightChip),
                                           chipColumn("Outline", outlineChip)])
        colorRow.orientation = .horizontal
        colorRow.spacing = 18
        colorRow.alignment = .top
        // Default gravity distribution (not .equalSpacing) keeps the three chips
        // left-packed with a fixed gap so spacing doesn't shift as chip widths
        // change (Highlight/Outline toggling no-color) while clicking around.
        stack.addArrangedSubview(colorRow)
        stack.addArrangedSubview(fieldRow("Outline w", runValueSlider(
            value: Double(session.outlineWidth), min: 1, max: 20, unit: "%",
            onDragStart: {}, onDragEnd: {},
            onChange: { [weak session] v in session?.applyOutlineWidth(CGFloat(v)) })))

        // — Paragraph —
        toolSection(stack, "Paragraph")
        stack.addArrangedSubview(fieldRow("Align", iconChoice(
            ["text.alignleft", "text.aligncenter", "text.alignright"], selected: alignIdx) { [weak session] idx in
                session?.setAlignment(idx == 1 ? .center : (idx == 2 ? .right : .left))
            }))
        stack.addArrangedSubview(fieldRow("Vertical", iconChoice(
            ["arrow.up.to.line", "arrow.up.and.down", "arrow.down.to.line"], selected: vIdx) { [weak session] idx in
                session?.setVerticalAlignment(idx == 1 ? .middle : (idx == 2 ? .bottom : .top))
            }))
        stack.addArrangedSubview(fieldRow("Line sp.", runValueSlider(
            value: Double(session.lineSpacing), min: 0, max: 40,
            onDragStart: {}, onDragEnd: {},
            onChange: { [weak session] v in session?.setLineSpacing(CGFloat(v)) })))

        // — Opacity —
        toolSection(stack, "Opacity")
        stack.addArrangedSubview(runValueSlider(
            value: session.opacity * 100, min: 10, max: 100, unit: "%",
            onDragStart: {}, onDragEnd: {},
            onChange: { [weak session] v in session?.setOpacity(v / 100.0) }))

        return stack
    }

    /// Panel shown when more than one annotation is selected: a count summary
    /// and a Delete button. Bulk style editing is intentionally not offered.
    static func makeMultiObject(state: EditorState) -> NSView {
        let stack = verticalStack()
        let count = state.selectedAnnotationIDs.count
        stack.addArrangedSubview(label("\(count) objects selected.", secondary: true))
        let deleteButton = ClosureButton(title: "Delete") { [weak state] in
            state?.deleteSelected()
        }
        stack.addArrangedSubview(deleteButton)
        return stack
    }

    // MARK: Objects list (Select tool)

    /// The Select-tool layers list: every annotation as a row (front-most
    /// first). The disclosure triangle expands that row's editable controls
    /// inline (independent of selection); the title selects the object
    /// (⌘-click toggles). A bottom Delete removes the current selection.
    static func makeObjectsList(state: EditorState) -> NSView {
        let stack = verticalStack()

        let ordered = objectListOrder(state.annotations)
        stack.addArrangedSubview(label("\(ordered.count) object\(ordered.count == 1 ? "" : "s")", secondary: true))

        for annotation in ordered {
            stack.addArrangedSubview(makeObjectRow(state: state, annotation: annotation))
        }

        if !state.selectedAnnotationIDs.isEmpty {
            stack.addArrangedSubview(divider())
            stack.addArrangedSubview(ClosureButton(title: "Delete") { [weak state] in
                state?.deleteSelected()
            })
        }
        return stack
    }

    /// One row of the objects list: a highlighted header (disclosure + title)
    /// with the editable controls beneath when expanded.
    private static func makeObjectRow(state: EditorState, annotation: Annotation) -> NSView {
        let id = annotation.id
        let isSelected = state.selectedAnnotationIDs.contains(id)
        let isExpanded = state.expandedObjectIDs.contains(id)
        // The primary (focused) row is emphasized more strongly than the rest of
        // a multi-selection, matching the canvas emphasis.
        let isPrimary = state.selectedAnnotationIDs.count >= 2 && state.primarySelectionID == id

        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 6
        column.translatesAutoresizingMaskIntoConstraints = false

        // Header: disclosure triangle + clickable title, tinted when selected.
        let header = NSStackView()
        header.orientation = .horizontal
        header.spacing = 6
        header.alignment = .centerY
        header.edgeInsets = NSEdgeInsets(top: 3, left: 4, bottom: 3, right: 6)
        header.translatesAutoresizingMaskIntoConstraints = false
        if isSelected {
            header.wantsLayer = true
            header.layer?.backgroundColor = NSColor.controlAccentColor
                .withAlphaComponent(isPrimary ? 0.34 : 0.18).cgColor
            header.layer?.cornerRadius = 4
        }

        let disclosure = ClosureButton(title: "") { [weak state] in
            guard let state else { return }
            // Expanding auto-highlights the object (issue C). In a multi-
            // selection focus it so the canvas emphasizes it without leaving
            // the list; with nothing selected, just expand inline (avoid
            // collapsing the list into the single-object panel).
            if state.selectedAnnotationIDs.count >= 2 { state.focusObject(id) }
            state.toggleExpanded(id)
        }
        disclosure.bezelStyle = .disclosure
        disclosure.setButtonType(.toggle)
        disclosure.isBordered = true
        disclosure.title = ""
        disclosure.state = isExpanded ? .on : .off
        disclosure.setContentHuggingPriority(.required, for: .horizontal)

        let titleButton = ClosureButton(title: ObjectRowDescriptor.title(for: annotation)) { [weak state] in
            let toggle = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
            // Plain click highlights the object (makes it primary) without
            // descending into its property panel when several are selected;
            // ⌘-click toggles its membership.
            if toggle { state?.toggleSelection(id) } else { state?.focusObject(id) }
        }
        titleButton.isBordered = false
        titleButton.bezelStyle = .inline
        titleButton.alignment = .left
        titleButton.font = NSFont.systemFont(ofSize: 12, weight: isSelected ? .semibold : .regular)
        titleButton.contentTintColor = .labelColor

        header.addArrangedSubview(disclosure)
        header.addArrangedSubview(titleButton)
        column.addArrangedSubview(header)

        if isExpanded {
            let detail = NSStackView()
            detail.orientation = .vertical
            detail.alignment = .leading
            detail.edgeInsets = NSEdgeInsets(top: 0, left: 18, bottom: 4, right: 0)
            detail.translatesAutoresizingMaskIntoConstraints = false
            detail.addArrangedSubview(makeObjectControls(state: state, annotation: annotation))
            column.addArrangedSubview(detail)
        }

        return column
    }

    /// A small caption above a control, as a vertical column.
    private static func labeledColumn(_ title: String, _ control: NSView) -> NSView {
        let col = NSStackView()
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 4
        col.addArrangedSubview(label(title, secondary: true))
        col.addArrangedSubview(control)
        return col
    }

    private static func styleSlider(
        state: EditorState, id: UUID,
        value: Double, min: Double, max: Double, unit: String = "",
        apply: @escaping (inout Style, Double) -> Void
    ) -> NSView {
        let handler = StyleSliderHandler(state: state, id: id, apply: apply)
        let slider = StyleEditSlider(value: value, minValue: min, maxValue: max,
                                     target: handler, action: #selector(StyleSliderHandler.changed(_:)))
        slider.onDragStart = { [weak state] in state?.beginStyleEdit(); state?.recordUndoCheckpoint(action: "Change Style") }
        slider.onDragEnd = { [weak state] in state?.endStyleEdit() }
        slider.isContinuous = true
        slider.translatesAutoresizingMaskIntoConstraints = false
        objc_setAssociatedObject(slider, &StyleSliderHandler.assocKey, handler, .OBJC_ASSOCIATION_RETAIN)
        return sliderWithInput(slider, min: min, max: max, unit: unit, commit: { [weak state] v in
            guard let state else { return }
            state.beginStyleEdit()
            state.recordUndoCheckpoint(action: "Change Style")
            state.updateStyle(id: id) { apply(&$0, v) }
            state.endStyleEdit()
        })
    }

    /// A pop-up that edits one discrete `Style` field of the selected annotation,
    /// recording a single undo checkpoint per change (mirrors `styleSlider` for
    /// non-continuous choices like arrow caps / dash style).
    private static func stylePopUp(
        state: EditorState, id: UUID, titles: [String], selectedIndex: Int,
        apply: @escaping (inout Style, Int) -> Void
    ) -> NSPopUpButton {
        popUp(titles: titles, selectedIndex: selectedIndex) { [weak state] idx in
            guard let state else { return }
            state.recordUndoCheckpoint(action: "Change Style")
            state.updateStyle(id: id) { apply(&$0, idx) }
        }
    }


    // MARK: Neutral fallback (Select tool with no objects on the canvas)

    private static func makeNeutral(state: EditorState) -> NSView {
        let stack = verticalStack()
        stack.addArrangedSubview(label("No object selected.", secondary: true))
        return stack
    }

    // MARK: Info

    /// Sidebar panel for the Info tool. Shows the capture name, image
    /// dimensions, and tags. (Enhance lives on the toolbar, not here.)
    static func makeInfo(state: EditorState, onRename: ((String) -> Void)? = nil) -> NSView {
        if let videoURL = state.playingVideoURL {
            return makeVideoInfo(videoURL: videoURL, state: state, onRename: onRename)
        }
        let stack = verticalStack()
        // Read the manifest once: top-level fields (created/modified/sourceApp)
        // feed the Details section, `.metadata` feeds Tags.
        let manifest = state.sourceURL.flatMap { try? SealMetadataStore.readManifest(at: $0) }

        // Capture name (= the .seal filename / display title), above dimensions.
        // EDITABLE here (the title-bar name is read-only): Enter / focus loss
        // commits a rename through the controller's safe path, Esc reverts.
        if let url = state.sourceURL {
            stack.addArrangedSubview(sectionHeader("Name"))
            let nameRow = makeNameRow(url: url, readOnly: state.isReadOnly, onRename: onRename)
            stack.addArrangedSubview(nameRow)
            nameRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            stack.addArrangedSubview(divider())
        }

        // Summary — on-device summary of the capture, directly under Name. Shown
        // only when Foundation Models is available and AI is enabled — or when
        // it is merely switched off and the user could turn it on, in which case
        // the section stays with an explanation instead of a dead progress bar
        // (every permanently-unavailable reason keeps the omission). Shows a progress
        // bar while generating, then the formatted summary. Keywords (auto-generated
        // smartKeywords) are folded in here as a "Keywords: …" text line below the
        // summary — no standalone Smart Keywords section.
        let canGenerateSummary = AIAvailability.isFoundationModelAvailable
            && AIFeaturePreference().enabled
        let effectiveSummary = (manifest?.metadata?.effectiveSummary ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Keep the section when the user controls the summary (override or
        // suppression) even with AI off, so a suppressed one stays re-editable.
        let hasSummaryOverride = manifest?.metadata?.hasUserSummaryOverride ?? false
        // Apple Intelligence merely switched off is a ten-second fix — keep the
        // section and say so, rather than hiding a feature the user could have.
        // Every other unavailable reason keeps the omission below.
        let summaryNudge = AINudgePolicy.presentation(for: AIAvailability.status,
                                                      aiToggleOn: AIFeaturePreference().enabled)
        let showSummaryUnlock = !canGenerateSummary && (summaryNudge?.isActionable ?? false)
        if canGenerateSummary || showSummaryUnlock || !effectiveSummary.isEmpty || hasSummaryOverride {
            stack.addArrangedSubview(sectionHeader("Summary"))
            if showSummaryUnlock, effectiveSummary.isEmpty, !hasSummaryOverride {
                summaryUnlockViews().forEach(stack.addArrangedSubview)
            } else if effectiveSummary.isEmpty, state.isGeneratingSummary {
                stack.addArrangedSubview(label("Generating summary…", secondary: true))
                let bar = DeterminateProgressBar(value: { [weak state] in state?.imageSummaryProgress })
                stack.addArrangedSubview(bar)
                bar.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            } else if let url = state.sourceURL {
                // Click-to-edit (v13): the user's override wins over the
                // generated text and survives regeneration; the placeholder
                // lets a summary be written from scratch (e.g. a pure image).
                let tv = EditableSummaryView(
                    url: url,
                    generated: manifest?.metadata?.summary,
                    userSummary: manifest?.metadata?.userSummary,
                    highlightTags: (manifest?.metadata?.smartKeywords ?? [])
                        + (manifest?.metadata?.tags ?? []))
                stack.addArrangedSubview(tv)
                tv.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            } else {
                stack.addArrangedSubview(label("No summary yet.", secondary: true))
            }
            // Keywords — folded into Summary section; read-only "KEYWORDS: …"
            // line (auto-generated; users curate via Tags below). Progress bar
            // while generation is in flight; silent when empty.
            if let meta = manifest?.metadata, !meta.smartKeywords.isEmpty {
                let kwField = makeKeywordsLine(keywords: meta.smartKeywords)
                stack.addArrangedSubview(kwField)
                kwField.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            } else if state.isGeneratingTags {
                stack.addArrangedSubview(label("Generating keywords…", secondary: true))
                let bar = DeterminateProgressBar(value: { [weak state] in state?.imageTagsProgress })
                stack.addArrangedSubview(bar)
                bar.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
            stack.addArrangedSubview(divider())
        }

        // Tags — user-editable labels placed under Smart Keywords. Tags are never
        // auto-populated (generation writes to smartKeywords only), so there is no
        // generating-tags progress branch here. Shown whenever the capture has a
        // file to write to — even with no metadata yet (on-device AI off means no
        // generator ever creates one; the tag editor upserts a shell on first add).
        stack.addArrangedSubview(sectionHeader("Tags"))
        if let url = state.sourceURL {
            let tagsSection = makeTagsSection(
                url: url, meta: manifest?.metadata ?? .userEditableShell())
            stack.addArrangedSubview(tagsSection)
            // Full panel width so the chip flow inside has a definite width to wrap.
            tagsSection.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        } else {
            // No file yet (unsaved scratch canvas) — nowhere to persist tags.
            stack.addArrangedSubview(label("No tags yet.", secondary: true))
        }
        stack.addArrangedSubview(divider())

        // (Workflow section removed: the ★ Favorite toggle now lives in the
        // editor's top title bar; status moved out of the editor — it stays
        // available in the Library's workflow filters.)

        // Details: dimensions + capture metadata. Each metadata row is omitted
        // when its source is unavailable (no manifest, no source app, etc.).
        stack.addArrangedSubview(sectionHeader("Details"))
        stack.addArrangedSubview(detailRow("Dimensions",
                                           "\(state.sourceImage.width) × \(state.sourceImage.height)"))
        // While a document Resize is active, keep the pristine captured size
        // visible right under the working dimensions.
        if state.pristineSource != nil {
            let original = state.persistedSourceImage
            stack.addArrangedSubview(detailRow("Original size",
                                               "\(original.width) × \(original.height)"))
        }
        if let created = manifest.flatMap({ CaptureInfoFormatting.displayDate(iso: $0.createdISO8601) }) {
            stack.addArrangedSubview(detailRow("Captured", created))
        }
        // Modified only when it actually differs from Captured (a never-edited
        // capture has created == modified).
        if let m = manifest, m.modifiedISO8601 != m.createdISO8601,
           let modified = CaptureInfoFormatting.displayDate(iso: m.modifiedISO8601) {
            stack.addArrangedSubview(detailRow("Modified", modified))
        }
        if let app = manifest?.sourceApp, !app.isEmpty {
            stack.addArrangedSubview(detailRow("Source app", app))
        }
        if let kind = manifest?.captureKind {
            stack.addArrangedSubview(detailRow("Source", kind.displayLabel))
        }
        if let mode = manifest?.captureMode {
            stack.addArrangedSubview(detailRow("Capture type", mode.displayLabel))
        }
        if let domain = manifest?.pageDomain, !domain.isEmpty {
            stack.addArrangedSubview(detailRow("Website", domain))
        }
        if let url = state.sourceURL, let bytes = sealPackageSize(at: url) {
            stack.addArrangedSubview(detailRow(
                "Size", ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)))
        }

        // Objects: count + per-type breakdown of the canvas annotations. Wraps
        // (rather than truncating) so a multi-type breakdown stays fully visible
        // in the narrow pane.
        stack.addArrangedSubview(divider())
        stack.addArrangedSubview(sectionHeader("Objects"))
        let objectsLabel = label(
            CaptureInfoFormatting.objectSummary(state.annotations) ?? "No annotations yet.",
            secondary: true)
        objectsLabel.lineBreakMode = .byWordWrapping
        objectsLabel.maximumNumberOfLines = 0
        objectsLabel.preferredMaxLayoutWidth = EditorSidebarView.width - 32
        stack.addArrangedSubview(objectsLabel)
        // Constrain only after it's in the hierarchy (shares an ancestor with
        // the stack) — otherwise activating the constraint throws.
        objectsLabel.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true

        return stack
    }

    /// Info panel for a playing video `.seal`: Name, Workflow (favorite/status),
    /// frame dimensions, duration, Source, captured date, size. No Objects/Tags/
    /// Website/Content-type (not meaningful for a recording).
    private static func makeVideoInfo(videoURL: URL, state: EditorState,
                                      onRename: ((String) -> Void)? = nil) -> NSView {
        let stack = verticalStack()
        let manifest = try? SealMetadataStore.readManifest(at: videoURL)

        stack.addArrangedSubview(sectionHeader("Name"))
        let nameRow = makeNameRow(url: videoURL, readOnly: state.isReadOnly, onRename: onRename)
        stack.addArrangedSubview(nameRow)
        nameRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.addArrangedSubview(divider())

        // (Workflow section removed — ★ Favorite now lives in the title bar;
        // status moved to the Library's workflow filters.)

        // Summary — bulleted AI summary of the recording (proactive
        // background), click-to-edit (v13): the user's override wins and
        // survives regeneration. Shown when a summary exists (generated or
        // manual) or one can still be generated; the placeholder lets a
        // summary be written from scratch. Keywords are folded in below as
        // editable chips.
        // A recording saved as a plain movie has no manifest to read a summary
        // from or write one into, so VideoMetadataCoordinator skips it. This
        // panel has to agree: without that, the Summary section shows a
        // "Summarizing video…" bar for work that will never run, and never
        // finishes.
        let canCarryMetadata = videoURL.pathExtension.lowercased() == "seal"
        let videoFMOn = canCarryMetadata
            && AIAvailability.isFoundationModelAvailable && AIFeaturePreference().enabled
        let videoGenerated = manifest?.video?.summary
        // A video's generated summary lives on VideoInfo; the user override on
        // metadata still wins (an empty override = deliberately suppressed).
        let videoHasOverride = manifest?.metadata?.hasUserSummaryOverride ?? false
        let videoOverride = manifest?.metadata?.userSummary?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let videoEffective = videoHasOverride
            ? (videoOverride ?? "")
            : (videoGenerated ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // Same actionable-only rule as the image panel above.
        let videoSummaryNudge = AINudgePolicy.presentation(for: AIAvailability.status,
                                                           aiToggleOn: AIFeaturePreference().enabled)
        // Same gate: offering "turn on Apple Intelligence" for a file that
        // could not hold a summary even with it on would be a dead end.
        let showVideoSummaryUnlock = canCarryMetadata && !videoFMOn
            && (videoSummaryNudge?.isActionable ?? false)
        if videoGenerated != nil || videoFMOn || showVideoSummaryUnlock
            || !videoEffective.isEmpty || videoHasOverride {
            stack.addArrangedSubview(sectionHeader("Summary"))
            if showVideoSummaryUnlock, videoGenerated == nil, videoEffective.isEmpty,
               !videoHasOverride {
                summaryUnlockViews().forEach(stack.addArrangedSubview)
            } else if !videoHasOverride, videoEffective.isEmpty, videoGenerated == nil, videoFMOn {
                // Spinner only when nothing is user-controlled and generation is
                // still expected — a suppressed summary shows the (blank) editor.
                stack.addArrangedSubview(label("Summarizing video…", secondary: true))
                // Determinate bar bound to the open recording's generation progress.
                let progressBar = DeterminateProgressBar(value: { [weak state] in state?.videoSummaryProgress })
                stack.addArrangedSubview(progressBar)
                progressBar.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            } else {
                let tv = EditableSummaryView(
                    url: videoURL,
                    generated: videoGenerated,
                    userSummary: manifest?.metadata?.userSummary,
                    highlightTags: manifest?.metadata?.smartKeywords ?? [])
                stack.addArrangedSubview(tv)
                tv.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
            // Keywords — read-only "KEYWORDS: …" line; progress while generating.
            if let meta = manifest?.metadata, !meta.smartKeywords.isEmpty {
                let kwField = makeKeywordsLine(keywords: meta.smartKeywords)
                stack.addArrangedSubview(kwField)
                kwField.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            } else if state.isGeneratingVideoTags {
                stack.addArrangedSubview(label("Generating keywords…", secondary: true))
                let bar = DeterminateProgressBar(value: { [weak state] in state?.videoSummaryProgress })
                stack.addArrangedSubview(bar)
                bar.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
            stack.addArrangedSubview(divider())
        }

        // Tags — user-editable labels placed below Smart Keywords. Tags are never
        // auto-populated (generation writes to smartKeywords only), so there is no
        // "generating" branch. Always shown so the user can add tags at any time.
        stack.addArrangedSubview(sectionHeader("Tags"))
        let tagsView = makeTagsSection(
            url: videoURL, meta: manifest?.metadata ?? .userEditableShell())
        stack.addArrangedSubview(tagsView)
        tagsView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.addArrangedSubview(divider())

        stack.addArrangedSubview(sectionHeader("Details"))
        if let sz = manifest?.sourceSize {
            stack.addArrangedSubview(detailRow("Dimensions", "\(sz.width) × \(sz.height)"))
        }
        if let secs = manifest?.video?.durationSeconds, secs > 0 {
            stack.addArrangedSubview(detailRow("Duration", VideoPlaybackMath.timeLabel(secs)))
        } else if !canCarryMetadata,
                  let secs = VideoDurationLoader.cachedSeconds(for: videoURL), secs > 0 {
            // No manifest to hold a duration — reuse the value the strip's tile
            // already loaded and cached for this same file.
            stack.addArrangedSubview(detailRow("Duration", VideoPlaybackMath.timeLabel(secs)))
        }
        if let kind = manifest?.captureKind {
            stack.addArrangedSubview(detailRow("Source", kind.displayLabel))
        }
        if let created = manifest.flatMap({ CaptureInfoFormatting.displayDate(iso: $0.createdISO8601) }) {
            stack.addArrangedSubview(detailRow("Captured", created))
        }
        if let bytes = sealPackageSize(at: videoURL) {
            stack.addArrangedSubview(detailRow("Size",
                ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)))
        }

        // Everything above comes from the manifest. A plain movie has none, so
        // fill the section from the file itself — an empty Details panel reads
        // as a bug, when the real answer is "this format doesn't carry that".
        if !canCarryMetadata {
            stack.addArrangedSubview(detailRow(
                "Format", "\(videoURL.pathExtension.uppercased()) movie file"))
            let values = try? videoURL.resourceValues(
                forKeys: [.creationDateKey, .contentModificationDateKey, .fileSizeKey])
            if let created = values?.creationDate {
                stack.addArrangedSubview(
                    detailRow("Captured", CaptureInfoFormatting.displayDate(date: created)))
            }
            if let modified = values?.contentModificationDate {
                stack.addArrangedSubview(
                    detailRow("Modified", CaptureInfoFormatting.displayDate(date: modified)))
            }
            if let bytes = values?.fileSize {
                stack.addArrangedSubview(detailRow("Size",
                    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)))
            }
            stack.addArrangedSubview(label(
                "Saved as a movie file — no tags, summary or searchable text. Recordings saved as a package carry those.",
                secondary: true))
        }
        return stack
    }

    /// The Summary section's unlock affordance: one line explaining why there
    /// is no summary, plus — only when the pane can actually be opened — a
    /// button that goes there. Shared by the image and video Info panels so
    /// the wording can never drift between them.
    private static func summaryUnlockViews() -> [NSView] {
        var views: [NSView] = [
            label(AINudgePolicy.summaryUnlockLine, secondary: true)
        ]
        if AISystemSettingsLink.canOpen {
            let open = ClosureButton(title: "Open System Settings…") {
                AISystemSettingsLink.open()
            }
            open.bezelStyle = .inline
            open.controlSize = .small
            views.append(open)
        }
        return views
    }

    /// The Info panel's Name row: the full name, wrapped so all of it is
    /// always visible, click-to-edit in place (the same pattern as the
    /// summary) committing via `onRename` (the controller's safe rename
    /// path). Read-only captures (Trash) and panels without a rename route
    /// fall back to the wrapping selectable label.
    private static func makeNameRow(url: URL, readOnly: Bool,
                                    onRename: ((String) -> Void)?) -> NSView {
        let currentName = { CaptureDisplayName.resolve(for: url) }
        guard let onRename, !readOnly else {
            let nameLabel = WrappingLabel(string: currentName())
            nameLabel.toolTip = nameLabel.stringValue
            return nameLabel
        }
        return EditableNameView(currentName: currentName, onRename: onRename)
    }

    /// A compact "Name" caption above its value, for the Details section.
    private static func detailRow(_ name: String, _ value: String) -> NSView {
        let col = NSStackView()
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 1
        col.translatesAutoresizingMaskIntoConstraints = false
        let caption = label(name, secondary: true)
        caption.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        caption.textColor = .tertiaryLabelColor
        let valueLabel = label(value, secondary: false)
        valueLabel.isSelectable = true
        valueLabel.lineBreakMode = .byTruncatingMiddle
        valueLabel.toolTip = value
        col.addArrangedSubview(caption)
        col.addArrangedSubview(valueLabel)
        return col
    }

    /// Builds the tags section container (chip list + add field). Returns a
    /// plain `NSStackView` that can be rebuilt in place.
    private static func makeTagsSection(url: URL, meta: CaptureMetadata) -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 6
        container.translatesAutoresizingMaskIntoConstraints = false

        // Chips flow left-to-right and wrap to a new row when out of width.
        let chipsContainer = WrappingChipView()

        func buildChipRow(tag: String) -> NSView {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 4
            row.alignment = .centerY

            let tagLabel = NSTextField(labelWithString: tag)
            tagLabel.font = NSFont.systemFont(ofSize: 12)
            tagLabel.isSelectable = true   // selectable/copyable like the info values

            let removeBtn = ClosureButton(title: "✕") {
                try? SealMetadataStore.update(at: url) { m in
                    m.tags = TagNormalizer.normalize(m.tags.filter { $0 != tag })
                }
                NotificationCenter.default.post(
                    name: .captureMetadataDidChange, object: url)
                // Remove this chip from the flow immediately.
                chipsContainer.removeChip(row)
            }
            removeBtn.bezelStyle = .inline
            removeBtn.font = NSFont.systemFont(ofSize: 10)
            removeBtn.isBordered = false
            removeBtn.contentTintColor = .tertiaryLabelColor

            row.addArrangedSubview(tagLabel)
            row.addArrangedSubview(removeBtn)
            return row
        }

        for tag in meta.tags {
            chipsContainer.addChip(buildChipRow(tag: tag))
        }
        container.addArrangedSubview(chipsContainer)
        // Fill the section width so the flow view has a definite width to wrap
        // within (and re-wraps when the sidebar is resized).
        chipsContainer.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true

        // "Add tag…" text field
        let addField = NSTextField()
        addField.placeholderString = "Add tag…"
        addField.font = NSFont.systemFont(ofSize: 12)
        addField.bezelStyle = .roundedBezel
        addField.isBordered = true
        addField.isBezeled = true
        addField.translatesAutoresizingMaskIntoConstraints = false

        let addHandler = TagAddFieldHandler(url: url, addField: addField, chipsContainer: chipsContainer, buildChipRow: buildChipRow)
        addField.delegate = addHandler
        // Retain handler on addField via associated object
        objc_setAssociatedObject(addField, &TagAddFieldHandler.assocKey, addHandler, .OBJC_ASSOCIATION_RETAIN)
        // Kick off an async vocabulary fetch so suggestions are ready shortly after the panel opens.
        addHandler.refreshVocabulary()
        // Inset the field a couple points inside the full-width column so its
        // rounded bezel + focus ring clear the panel's clip edge (otherwise the
        // bezel is shaved a hair on the left and right).
        let addFieldWrap = NSView()
        addFieldWrap.translatesAutoresizingMaskIntoConstraints = false
        addFieldWrap.addSubview(addField)
        NSLayoutConstraint.activate([
            addField.leadingAnchor.constraint(equalTo: addFieldWrap.leadingAnchor, constant: 3),
            addField.trailingAnchor.constraint(equalTo: addFieldWrap.trailingAnchor, constant: -3),
            addField.topAnchor.constraint(equalTo: addFieldWrap.topAnchor),
            addField.bottomAnchor.constraint(equalTo: addFieldWrap.bottomAnchor),
        ])
        container.addArrangedSubview(addFieldWrap)
        addFieldWrap.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true

        return container
    }

    /// Builds the read-only "KEYWORDS: …" line shown inside the Summary section
    /// (image + video). Rendered with the SAME view type (`WrappingTextView`) and
    /// the SAME attributes the summary body uses — 12pt regular, `secondaryLabelColor`,
    /// `lineHeightMultiple` 1.30 — so it renders pixel-identically to the summary
    /// text (an `NSTextField` at the same point size renders with different metrics).
    private static func makeKeywordsLine(keywords: [String]) -> NSView {
        let para = NSMutableParagraphStyle()
        para.lineHeightMultiple = 1.30
        // The "KEYWORDS:" label sits 1pt below the section title; the keyword
        // VALUES are 1pt larger than the label (so they read a touch stronger).
        let labelSize = Theme.sectionHeaderFont.pointSize - 1
        let valueSize = labelSize + 1
        let base: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: para,
        ]
        let labelAttrs = base.merging([.font: NSFont.systemFont(ofSize: labelSize, weight: .regular)]) { $1 }
        let valueAttrs = base.merging([.font: NSFont.systemFont(ofSize: valueSize, weight: .regular)]) { $1 }
        let attributed = NSMutableAttributedString(string: "KEYWORDS: ", attributes: labelAttrs)
        attributed.append(NSAttributedString(string: keywords.joined(separator: " | "), attributes: valueAttrs))
        let tv = WrappingTextView()
        tv.setAttributed(attributed)
        return tv
    }

    // MARK: Enhance panel

    /// Right-sidebar Enhance panel. Shows an Enabled toggle (= showingEnhanced);
    /// when on, shows Upscale + Sharpness / Noise reduction / Contrast sliders
    /// and an Apply button (enabled iff the draft differs from the applied params
    /// or no enhanced image exists yet). `onApply` is wired to the controller's
    /// `runEnhanceApply()` via the sidebar's `onEnhanceApply` property.
    static func makeEnhance(state: EditorState, onApply: @escaping () -> Void,
                            onCancel: @escaping () -> Void = {}) -> NSView {
        let stack = verticalStack()

        // Enabled row: NSSwitch + "Enhanced" label.
        let enableRow = NSStackView()
        enableRow.orientation = .horizontal
        enableRow.spacing = 8
        enableRow.translatesAutoresizingMaskIntoConstraints = false

        let sw = NSSwitch()
        sw.state = state.showingEnhanced ? .on : .off
        let toggleHandler = EnhanceToggleHandler(state: state, onApply: onApply, onCancel: onCancel)
        sw.target = toggleHandler
        sw.action = #selector(EnhanceToggleHandler.toggled(_:))
        objc_setAssociatedObject(sw, &EnhanceToggleHandler.assocKey, toggleHandler, .OBJC_ASSOCIATION_RETAIN)
        // The flag can change UNDER the switch (⌘Z now steps across the
        // Enhance toggle) — mirror it, or undo looks like a no-op while the
        // switch keeps showing the stale position.
        mirrorEnhanceSwitch(sw, state: state)
        enableRow.addArrangedSubview(sw)
        enableRow.addArrangedSubview(label("Enhanced"))
        stack.addArrangedSubview(enableRow)

        // Params are only shown when the switch is on — guard early.
        guard state.showingEnhanced else {
            if state.enhanceRunning { disableControls(in: stack) }
            return stack
        }

        // Upscale (Off / 2× / 4×).
        stack.addArrangedSubview(sectionHeader("Upscale"))
        let upscaleOrder: [EnhanceParams.Upscale] = [.off, .x2, .x4]
        let upscaleMap: [EnhanceParams.Upscale: Int] = [.off: 0, .x2: 1, .x4: 2]
        let seg = NSSegmentedControl(labels: ["Off", "2×", "4×"],
                                     trackingMode: .selectOne,
                                     target: nil, action: nil)
        seg.selectedSegment = upscaleMap[state.enhanceDraft.upscale] ?? 0
        seg.translatesAutoresizingMaskIntoConstraints = false
        let upscaleHandler = EnhanceUpscaleHandler(state: state, order: upscaleOrder)
        seg.target = upscaleHandler
        seg.action = #selector(EnhanceUpscaleHandler.changed(_:))
        objc_setAssociatedObject(seg, &EnhanceUpscaleHandler.assocKey, upscaleHandler, .OBJC_ASSOCIATION_RETAIN)
        stack.addArrangedSubview(seg)

        // Sharpness (0–100).
        stack.addArrangedSubview(sectionHeader("Sharpness"))
        stack.addArrangedSubview(enhanceDraftSlider(
            value: Double(state.enhanceDraft.sharpness), state: state,
            apply: { state.enhanceDraft.sharpness = Int($0.rounded()) }))

        // Noise reduction (0–100).
        stack.addArrangedSubview(sectionHeader("Noise reduction"))
        stack.addArrangedSubview(enhanceDraftSlider(
            value: Double(state.enhanceDraft.noiseReduction), state: state,
            apply: { state.enhanceDraft.noiseReduction = Int($0.rounded()) }))

        // Contrast (0–100).
        stack.addArrangedSubview(sectionHeader("Contrast"))
        stack.addArrangedSubview(enhanceDraftSlider(
            value: Double(state.enhanceDraft.contrast), state: state,
            apply: { state.enhanceDraft.contrast = Int($0.rounded()) }))

        // Apply button — enabled iff draft differs from applied params or no
        // enhanced image exists yet (i.e., something has changed or we haven't run).
        let isDirty = (state.enhanceDraft != state.enhanceParams) || state.enhancedImage == nil
        let applyButton = NSButton(title: "Apply", target: nil, action: nil)
        applyButton.bezelStyle = .rounded
        applyButton.isEnabled = isDirty
        let applyHandler = EnhanceApplyHandler(state: state, onApply: onApply)
        applyButton.target = applyHandler
        applyButton.action = #selector(EnhanceApplyHandler.fire)
        objc_setAssociatedObject(applyButton, &EnhanceApplyHandler.assocKey, applyHandler, .OBJC_ASSOCIATION_RETAIN)
        stack.addArrangedSubview(applyButton)

        // While a run is in flight the whole panel goes inert — changing
        // params or re-toggling mid-run has no defined meaning; the overlay's
        // Cancel is the one live affordance. The sidebar observes
        // `enhanceRunning`, so completion/cancel rebuilds it enabled.
        if state.enhanceRunning { disableControls(in: stack) }

        return stack
    }

    /// Recursively disable every NSControl in a built panel.
    private static func disableControls(in view: NSView) {
        for sub in view.subviews {
            (sub as? NSControl)?.isEnabled = false
            disableControls(in: sub)
        }
    }

    // MARK: Workflow controls (Favorite + Status)

    /// Builds the Workflow subsection: a ★ Favorite checkbox + a 3-segment
    /// New/Reviewed/Archived picker. Each control writes through to
    /// `SealMetadataStore.setWorkflow` and posts `.captureMetadataDidChange`
    /// so the Library index reflects the change immediately.
    // MARK: Crop

    /// Stable mapping between popup item index and aspect-ratio value
    /// (W/H). nil = Free. Order matches the popup item titles below.
    private static let cropAspects: [CGFloat?] = [nil, 1.0, 16.0 / 9.0, 4.0 / 3.0]
    private static let cropAspectTitles = ["Free", "1:1", "16:9", "4:3"]

    private static func makeCrop(
        state: EditorState,
        onCommitCrop: @escaping () -> Void,
        onCopyCrop: @escaping () -> Void,
        onCutCrop: @escaping () -> Void,
        onSoftCrop: @escaping () -> Void
    ) -> NSView {
        let stack = verticalStack()

        // ── Aspect ratio ──────────────────────────────────────────────────────
        stack.addArrangedSubview(sectionHeader("Aspect ratio"))
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: cropAspectTitles)
        popup.selectItem(at: currentAspectIndex(for: state))
        let aspectHandler = AspectHandler(state: state)
        popup.target = aspectHandler
        popup.action = #selector(AspectHandler.popupChanged(_:))
        objc_setAssociatedObject(popup, &AspectHandler.assocKey, aspectHandler, .OBJC_ASSOCIATION_RETAIN)
        stack.addArrangedSubview(popup)

        let sep = NSBox()
        sep.boxType = .separator
        stack.addArrangedSubview(sep)
        stack.setCustomSpacing(16, after: sep)

        // ── Action rows: Cut / Copy / Soft Crop / Crop ────────────────────────
        let initially = state.pendingCrop != nil

        let (cutRow, cutBtn, cutShortLbl, cutDescLbl) = makeCropActionRow(
            title: "Cut", shortcut: "⌘X",
            subtitle: "Remove the selection to the clipboard (leaves a transparent hole)",
            enabled: initially, onClick: onCutCrop)

        let (copyRow, copyBtn, copyShortLbl, copyDescLbl) = makeCropActionRow(
            title: "Copy", shortcut: "⌘C",
            subtitle: "Copy the selection to the clipboard",
            enabled: initially, onClick: onCopyCrop)

        let (softRow, softBtn, softShortLbl, softDescLbl) = makeCropActionRow(
            title: "Soft Crop", shortcut: "⌘↩",
            subtitle: "Lift the selection into a movable object (removes the original)",
            enabled: initially, onClick: onSoftCrop)

        let (cropRow, cropBtn, cropShortLbl, cropDescLbl) = makeCropActionRow(
            title: "Crop", shortcut: "↩",
            subtitle: "Trim the image to the selection",
            enabled: initially, onClick: onCommitCrop)

        stack.addArrangedSubview(cutRow)
        stack.addArrangedSubview(copyRow)
        stack.addArrangedSubview(softRow)
        stack.addArrangedSubview(cropRow)

        // Breathing room between each action section (button + its description).
        for row in [cutRow, copyRow, softRow] { stack.setCustomSpacing(12, after: row) }

        // ── Confirmation checkmark flash (click OR shortcut) ──────────────────
        // Only Copy needs it: Cut/Soft/Crop already change the image visibly, but
        // Copy has no on-canvas effect. Flashes "✓ Copied" on the Copy button.
        let flashHandler = CropActionFlashHandler(state: state) { [weak copyBtn] action in
            guard action == .copy else { return }
            flashCropCheckmark(on: copyBtn, title: "Copy", flashTitle: "Copied")
        }
        objc_setAssociatedObject(stack, &CropActionFlashHandler.assocKey, flashHandler, .OBJC_ASSOCIATION_RETAIN)

        // ── Shared pendingCrop observer ───────────────────────────────────────
        // ConfirmCropHandler owns the withObservationTracking loop.
        // Retain it on the stack (not on a button) so it lives as long as the panel.
        let cropHandler = ConfirmCropHandler(state: state, onCommit: onCommitCrop)
        objc_setAssociatedObject(stack, &ConfirmCropHandler.assocKey, cropHandler, .OBJC_ASSOCIATION_RETAIN)
        cropHandler.startObserving { [
            weak cutBtn, weak cutShortLbl, weak cutDescLbl,
            weak copyBtn, weak copyShortLbl, weak copyDescLbl,
            weak softBtn, weak softShortLbl, weak softDescLbl,
            weak cropBtn, weak cropShortLbl, weak cropDescLbl
        ] in
            let on = state.pendingCrop != nil
            for btn in [cutBtn, copyBtn, softBtn, cropBtn] { btn?.isEnabled = on }
            let secondary: NSColor = on ? .secondaryLabelColor : .tertiaryLabelColor
            let hint: NSColor      = on ? .labelColor          : .tertiaryLabelColor
            for lbl in [cutShortLbl, copyShortLbl, softShortLbl, cropShortLbl] { lbl?.textColor = hint }
            for lbl in [cutDescLbl, copyDescLbl, softDescLbl, cropDescLbl] { lbl?.textColor = secondary }
        }

        return stack
    }

    /// Per-button flash sequence key (so a re-flash supersedes a stale revert).
    private static var cropFlashSeqKey: UInt8 = 0

    /// Briefly show a green checkmark + `flashTitle` on a crop button to confirm
    /// the action fired (click OR shortcut), then revert to `title` after ~1s. A
    /// re-flash within that window wins via the seq guard.
    private static func flashCropCheckmark(on button: NSButton?, title: String, flashTitle: String) {
        guard let button else { return }
        let font = button.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let flashed = NSMutableAttributedString(
            string: "✓ ", attributes: [.foregroundColor: NSColor.systemGreen, .font: font])
        flashed.append(NSAttributedString(string: flashTitle,
                                          attributes: [.foregroundColor: NSColor.systemGreen, .font: font]))
        button.attributedTitle = flashed
        let seq = ((objc_getAssociatedObject(button, &cropFlashSeqKey) as? Int) ?? 0) + 1
        objc_setAssociatedObject(button, &cropFlashSeqKey, seq, .OBJC_ASSOCIATION_RETAIN)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak button] in
            guard let button, (objc_getAssociatedObject(button, &cropFlashSeqKey) as? Int) == seq else { return }
            button.attributedTitle = NSAttributedString(string: title, attributes: [.font: font])
        }
    }

    /// Builds one crop-action row: a `[button(title) | shortcut]` row above a
    /// wrapping description caption. Returns the outer view plus the three
    /// sub-components the caller needs to wire into the shared enablement observer.
    private static func makeCropActionRow(
        title: String,
        shortcut: String,
        subtitle: String,
        enabled: Bool,
        onClick: @escaping () -> Void
    ) -> (row: NSView, button: ClosureButton, shortcutLabel: NSTextField, descLabel: NSTextField) {
        let btn = ClosureButton(title: title, onClick: onClick)
        btn.isEnabled = enabled
        btn.setContentHuggingPriority(.defaultLow, for: .horizontal)
        btn.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Space each key glyph apart so multi-key shortcuts (⌘ X) read as
        // distinct keys; larger + darker so the shortcut stands out.
        let spacedShortcut = shortcut.map(String.init).joined(separator: " ")
        let shortLbl = NSTextField(labelWithString: spacedShortcut)
        shortLbl.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .semibold)
        shortLbl.textColor = enabled ? .labelColor : .tertiaryLabelColor
        shortLbl.setContentHuggingPriority(.required, for: .horizontal)
        shortLbl.setContentCompressionResistancePriority(.required, for: .horizontal)
        shortLbl.translatesAutoresizingMaskIntoConstraints = false

        let buttonRow = NSStackView(views: [btn, shortLbl])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.distribution = .fill
        buttonRow.spacing = 6
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        // WrappingLabel (defined below in this file) updates preferredMaxLayoutWidth
        // in layout() so the description reflows correctly as the sidebar resizes.
        let descLbl = WrappingLabel(string: subtitle)
        descLbl.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        descLbl.textColor = enabled ? .secondaryLabelColor : .tertiaryLabelColor

        let vStack = NSStackView(views: [buttonRow, descLbl])
        vStack.orientation = .vertical
        vStack.alignment = .leading
        vStack.spacing = 3
        vStack.translatesAutoresizingMaskIntoConstraints = false

        // Allow description to fill the available width so wrapping works.
        descLbl.widthAnchor.constraint(equalTo: vStack.widthAnchor).isActive = true

        return (vStack, btn, shortLbl, descLbl)
    }

    private static func currentAspectIndex(for state: EditorState) -> Int {
        guard let current = state.cropAspectRatio else { return 0 }
        if let idx = cropAspects.firstIndex(where: {
            guard let v = $0 else { return false }
            return abs(v - current) < 0.001
        }) {
            return idx
        }
        return 0
    }

    // MARK: Arrow + Rectangle (added in Task 7)

    private static func makeArrow(state: EditorState) -> NSView {
        let stack = verticalStack()
        addStrokeToolDefaults(to: stack, state: state)
        addArrowCapDefaults(to: stack, state: state)
        addArrowShaftDefault(to: stack, state: state)
        addDashDefault(to: stack, state: state)
        stack.addArrangedSubview(sectionHeader("Effects"))
        stack.addArrangedSubview(shadowRow(
            read: { state.shadowDefault(for: .arrow) },
            write: { s in state.setShadowDefault(s, for: .arrow) }))
        return stack
    }

    /// Display order + titles for the cap and dash pickers, shared by the
    /// creation panels and the selected-object panel.
    static let arrowCapOrder: [ArrowCap] = [.none, .filled, .open, .dot, .bar]
    private static let arrowCapTitles = ["None", "Filled", "Open", "Dot", "Bar"]
    static let dashOrder: [DashStyle] = [.solid, .dashed, .dotted, .sparseDotted]
    private static let dashTitles = ["Solid", "Dashed", "Dotted", "Sparse dotted"]

    /// A small line-art swatch of `cap` drawn on one end of a short shaft.
    /// Template image so it tints to the menu's text color in light & dark mode.
    private static func capSampleImage(_ cap: ArrowCap, atStart: Bool) -> NSImage {
        sampleImage(width: 46) { s, e in
            drawConnector(from: s, to: e, width: 2, color: .black, dash: .solid,
                          startCap: atStart ? cap : .none, endCap: atStart ? .none : cap)
        }
    }
    /// A short shaft drawn in `style` (solid/dashed/dotted/sparse).
    private static func dashSampleImage(_ style: DashStyle) -> NSImage {
        sampleImage(width: 54) { s, e in
            drawConnector(from: s, to: e, width: 2, color: .black, dash: style,
                          startCap: .none, endCap: .none)
        }
    }
    private static func sampleImage(width: CGFloat, _ draw: (CGPoint, CGPoint) -> Void) -> NSImage {
        let size = NSSize(width: width, height: 16)
        let img = NSImage(size: size)
        img.lockFocus()
        let mid = size.height / 2
        draw(CGPoint(x: 9, y: mid), CGPoint(x: width - 9, y: mid))
        img.unlockFocus()
        img.isTemplate = true
        return img
    }
    private static func setItemImages(_ popup: NSPopUpButton, _ images: [NSImage]) {
        for (i, image) in images.enumerated() { popup.item(at: i)?.image = image }
    }

    /// Start and End arrowhead pickers, on their own rows, each option showing a
    /// sample swatch. Bound to the arrow creation defaults.
    private static func addArrowCapDefaults(to stack: NSStackView, state: EditorState) {
        toolSection(stack, "Arrowheads")

        let startPopup = popUp(titles: arrowCapTitles,
                               selectedIndex: arrowCapOrder.firstIndex(of: state.arrowStartCap) ?? 0) { idx in
            state.arrowStartCap = arrowCapOrder[idx]
        }
        setItemImages(startPopup, arrowCapOrder.map { capSampleImage($0, atStart: true) })
        stack.addArrangedSubview(labeledColumn("Start", startPopup))

        let endPopup = popUp(titles: arrowCapTitles,
                             selectedIndex: arrowCapOrder.firstIndex(of: state.arrowEndCap) ?? 0) { idx in
            state.arrowEndCap = arrowCapOrder[idx]
        }
        setItemImages(endPopup, arrowCapOrder.map { capSampleImage($0, atStart: false) })
        stack.addArrangedSubview(labeledColumn("End", endPopup))
    }

    /// Shaft profile picker — Uniform vs Tapered — bound to the straight
    /// arrow's creation default. Deliberately absent from the pen-arrow panel:
    /// freehand arrows always render uniform.
    private static func addArrowShaftDefault(to stack: NSStackView, state: EditorState) {
        toolSection(stack, "Shaft")
        let styles: [ShaftStyle] = [.tapered, .uniform]
        let p = popUp(titles: ["Tapered", "Uniform"],
                      selectedIndex: styles.firstIndex(of: state.arrowShaftStyle) ?? 0) { idx in
            state.arrowShaftStyle = styles[idx]
        }
        stack.addArrangedSubview(labeledColumn("Profile", p))
    }

    /// Shaft dash-style picker (with sample swatches) bound to the active tool's
    /// creation default.
    private static func addDashDefault(to stack: NSStackView, state: EditorState) {
        toolSection(stack, "Line style")
        let p = popUp(titles: dashTitles,
                      selectedIndex: dashOrder.firstIndex(of: state.dashStyle) ?? 0) { idx in
            state.dashStyle = dashOrder[idx]
        }
        setItemImages(p, dashOrder.map { dashSampleImage($0) })
        stack.addArrangedSubview(p)
    }

    /// Tool-default controls for arrow/line, mirroring the selected-object
    /// panel: Stroke color, Stroke width (2–16), Opacity. Bound to creation
    /// defaults on `state`.
    private static func addStrokeToolDefaults(to stack: NSStackView, state: EditorState) {
        toolSection(stack, "Color")
        let strokeChip = colorField(
            initial: state.selectedColor, allowsNoColor: false,
            onPick: { color in if let color = color { state.selectedColor = opaqueSRGB(color) } })
        stack.addArrangedSubview(colorColumnsRow([
            ("Stroke", strokeChip), ("Outline", outlineChip(state: state))]))

        toolSection(stack, "Stroke width")
        stack.addArrangedSubview(defaultSlider(value: Double(state.strokeWidth), min: 1, max: 50, unit: "pt") {
            state.strokeWidth = CGFloat($0)
        })

        toolSection(stack, "Outline width")
        stack.addArrangedSubview(defaultSlider(value: Double(state.outlineWidth), min: 1, max: 20, unit: "pt") {
            state.outlineWidth = CGFloat($0)
        })

        addOpacityDefault(to: stack, state: state)
    }

    /// Shared "Opacity" header + slider bound to the cross-tool creation
    /// opacity, matching every object panel's Opacity control (10–100).
    private static func addOpacityDefault(to stack: NSStackView, state: EditorState) {
        toolSection(stack, "Opacity")
        stack.addArrangedSubview(defaultSlider(value: state.creationOpacity * 100, min: 10, max: 100, unit: "%") {
            state.creationOpacity = $0 / 100.0
        })
    }

    private static func makeRectangle(state: EditorState) -> NSView {
        let stack = verticalStack()
        addShapeDefaults(to: stack, state: state, cornerRadius: true)
        toolSection(stack, "Effects")
        stack.addArrangedSubview(shadowRow(
            read: { state.shadowDefault(for: .rectangle) },
            write: { s in state.setShadowDefault(s, for: .rectangle) }))
        return stack
    }

    private static func makeEllipse(state: EditorState) -> NSView {
        let stack = verticalStack()
        addShapeDefaults(to: stack, state: state, cornerRadius: false)
        toolSection(stack, "Effects")
        stack.addArrangedSubview(shadowRow(
            read: { state.shadowDefault(for: .ellipse) },
            write: { s in state.setShadowDefault(s, for: .ellipse) }))
        return stack
    }

    /// Tool-default controls for rectangle/ellipse, mirroring the
    /// selected-object panel (`makeObject`) so the panel reads the same with or
    /// without a selection. Each control edits the creation default on `state`
    /// instead of a selected annotation's style.
    private static func addShapeDefaults(to stack: NSStackView, state: EditorState, cornerRadius: Bool) {
        toolSection(stack, "Color")
        stack.addArrangedSubview(shapeColorRow(state: state))

        toolSection(stack, "Stroke width")
        stack.addArrangedSubview(defaultSlider(value: Double(state.strokeWidth), min: 0, max: 50, unit: "pt") {
            state.strokeWidth = CGFloat($0)
        })

        toolSection(stack, "Outline width")
        stack.addArrangedSubview(defaultSlider(value: Double(state.outlineWidth), min: 1, max: 20, unit: "pt") {
            state.outlineWidth = CGFloat($0)
        })

        addOpacityDefault(to: stack, state: state)

        if cornerRadius {
            toolSection(stack, "Corner radius")
            stack.addArrangedSubview(defaultSlider(value: Double(state.shapeCornerRadius), min: 0, max: 40) {
                state.shapeCornerRadius = CGFloat($0)
            })
        }
    }

    private static func makeLine(state: EditorState) -> NSView {
        let stack = verticalStack()
        addStrokeToolDefaults(to: stack, state: state)
        addDashDefault(to: stack, state: state)
        toolSection(stack, "Effects")
        stack.addArrangedSubview(shadowRow(
            read: { state.shadowDefault(for: .line) },
            write: { s in state.setShadowDefault(s, for: .line) }))
        return stack
    }

    private static func makePen(state: EditorState) -> NSView {
        let stack = verticalStack()
        addStrokeToolDefaults(to: stack, state: state)
        toolSection(stack, "Effects")
        stack.addArrangedSubview(shadowRow(
            read: { state.shadowDefault(for: .pen) },
            write: { s in state.setShadowDefault(s, for: .pen) }))
        return stack
    }

    /// Free-draw arrow: pen's stroke controls + the same Start/End arrowhead
    /// pickers as the straight arrow (shared `arrowStartCap`/`arrowEndCap`
    /// defaults). No dash — the freehand shaft renders solid.
    private static func makePenArrow(state: EditorState) -> NSView {
        let stack = verticalStack()
        addStrokeToolDefaults(to: stack, state: state)
        addArrowCapDefaults(to: stack, state: state)
        toolSection(stack, "Effects")
        stack.addArrangedSubview(shadowRow(
            read: { state.shadowDefault(for: .penArrow) },
            write: { s in state.setShadowDefault(s, for: .penArrow) }))
        return stack
    }

    /// Tool-default controls for the badge ("count") tool, mirroring the badge
    /// object panel: Fill, Number color, Opacity. Bound to creation defaults.
    private static func makeBadge(state: EditorState) -> NSView {
        let stack = verticalStack()

        toolSection(stack, "Color")
        let numChip = colorField(
            initial: state.badgeNumberColor, allowsNoColor: false,
            onPick: { color in if let color = color { state.badgeNumberColor = opaqueSRGB(color) } })
        let fillChip = colorField(
            initial: state.badgeFillColor, allowsNoColor: false,
            onPick: { color in if let color = color { state.badgeFillColor = opaqueSRGB(color) } })
        stack.addArrangedSubview(colorColumnsRow([("Number", numChip), ("Fill", fillChip),
                                                  ("Outline", outlineChip(state: state))]))

        toolSection(stack, "Size")
        stack.addArrangedSubview(defaultSlider(value: Double(state.badgeRadius), min: 8, max: 60) {
            state.badgeRadius = CGFloat($0)
        })

        toolSection(stack, "Outline width")
        stack.addArrangedSubview(defaultSlider(value: Double(state.outlineWidth), min: 1, max: 20, unit: "pt") {
            state.outlineWidth = CGFloat($0)
        })

        addOpacityDefault(to: stack, state: state)

        toolSection(stack, "Effects")
        stack.addArrangedSubview(shadowRow(
            read: { state.shadowDefault(for: .badge) },
            write: { s in state.setShadowDefault(s, for: .badge) }))
        return stack
    }

    // MARK: Blur

    /// Region-shape segment order; index ↔ `BlurRegionShape`. SF Symbols shown
    /// in place of text (rectangle / ellipse / freehand brush).
    private static let blurShapeOrder: [BlurRegionShape] = [.rect, .ellipse, .freehand]
    private static let blurShapeIcons: [(symbol: String, tip: String)] = [
        ("rectangle", "Rectangle"),
        ("circle", "Ellipse"),
        ("paintbrush.pointed.fill", "Brush"),
    ]

    /// Effect-mode order; index ↔ `BlurMode`. Pixelate/Mosaic are temporarily
    /// retired from the picker (the enum keeps them for existing annotations).
    private static let blurModeOrder: [BlurMode] = [.gaussian, .solid]
    private static let blurModeTitles = ["Gaussian", "Solid"]

    /// Tool-default controls for the Blur tool: region shape, effect mode,
    /// strength, and brush width (used by the freehand shape). Bound to the
    /// creation defaults on `state`.
    private static func makeBlur(state: EditorState) -> NSView {
        let stack = verticalStack()

        toolSection(stack, "Region shape")
        stack.addArrangedSubview(iconSegmentedControl(
            icons: blurShapeIcons,
            selectedIndex: blurShapeOrder.firstIndex(of: state.blurRegionShape) ?? 0
        ) { idx in state.blurRegionShape = blurShapeOrder[idx] })

        toolSection(stack, "Effect")
        stack.addArrangedSubview(popUp(
            titles: blurModeTitles,
            selectedIndex: blurModeOrder.firstIndex(of: state.blurMode) ?? 0
        ) { idx in state.blurMode = blurModeOrder[idx] })

        // Solid color only matters for the Solid block-out effect.
        if state.blurMode == .solid {
            toolSection(stack, "Solid color")
            stack.addArrangedSubview(colorField(
                initial: state.blurSolidColor, allowsNoColor: false,
                onPick: { color in if let color = color { state.blurSolidColor = opaqueSRGB(color) } }))
        }

        // Solid is a flat block-out, so its slider sets the fill's opacity (its
        // own default, full); the sampling effects scale intensity ("strength").
        if state.blurMode == .solid {
            toolSection(stack, "Opacity")
            stack.addArrangedSubview(defaultSlider(value: state.blurSolidOpacity * 100, min: 0, max: 100) {
                state.blurSolidOpacity = $0 / 100.0
            })
        } else {
            toolSection(stack, "Strength")
            stack.addArrangedSubview(defaultSlider(value: state.blurStrength * 100, min: 0, max: 100) {
                state.blurStrength = $0 / 100.0
            })
        }

        // Brush width only applies to the freehand brush; hidden for the
        // rectangle/ellipse region shapes.
        if state.blurRegionShape == .freehand {
            toolSection(stack, "Brush width")
            stack.addArrangedSubview(defaultSlider(value: Double(state.blurBrushWidth), min: 8, max: 120) {
                state.blurBrushWidth = CGFloat($0)
            })
        }

        return stack
    }

    /// Selected-blur object panel: effect mode + strength, editing the
    /// annotation's style live with an undo checkpoint per change. (Freehand
    /// brush width is set at draw time and isn't re-editable here.)
    private static func makeBlurObjectControls(
        state: EditorState, id: UUID, style: Style, region: BlurRegion
    ) -> NSView {
        let stack = verticalStack()

        toolSection(stack, "Effect")
        stack.addArrangedSubview(popUp(
            titles: blurModeTitles,
            selectedIndex: blurModeOrder.firstIndex(of: style.blurMode) ?? 0
        ) { idx in
            state.recordUndoCheckpoint(action: "Change Style")
            state.updateStyle(id: id) { $0.blurMode = blurModeOrder[idx] }
        })

        // Solid color only matters for the Solid block-out effect.
        if style.blurMode == .solid {
            toolSection(stack, "Solid color")
            let solidApplier = StyleColorApplier(state: state, id: id) { style, color in
                if let color = color { style.fillColor = SerializableColor(opaqueSRGB(color)) }
            }
            let solidChip = colorField(
                initial: (style.fillColor?.nsColor ?? BlurRenderer.defaultSolidColor), allowsNoColor: false,
                onSessionStart: { solidApplier.begin() },
                onPick: { solidApplier.pick($0) })
            objc_setAssociatedObject(solidChip, &Self.applierKey, solidApplier, .OBJC_ASSOCIATION_RETAIN)
            stack.addArrangedSubview(solidChip)
        }

        toolSection(stack, style.blurMode == .solid ? "Opacity" : "Strength")
        stack.addArrangedSubview(styleSlider(
            state: state, id: id, value: style.blurStrength * 100, min: 0, max: 100
        ) { $0.blurStrength = $1 / 100.0 })

        return stack
    }

    /// A closure-bound dropdown — used where a segmented control would be too
    /// wide for the sidebar (e.g. the 4 blur effects).
    private static func popUp(
        titles: [String], selectedIndex: Int, onChange: @escaping (Int) -> Void
    ) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: titles)
        popup.selectItem(at: max(0, min(selectedIndex, titles.count - 1)))
        let handler = ClosurePopupHandler(onChange: onChange)
        popup.target = handler
        popup.action = #selector(ClosurePopupHandler.changed(_:))
        objc_setAssociatedObject(popup, &ClosurePopupHandler.assocKey, handler, .OBJC_ASSOCIATION_RETAIN)
        popup.translatesAutoresizingMaskIntoConstraints = false
        return popup
    }

    /// An icon variant of `segmentedControl`: each segment shows an SF Symbol
    /// with a tooltip (which also serves as the accessibility description).
    private static func iconSegmentedControl(
        icons: [(symbol: String, tip: String)], selectedIndex: Int, onChange: @escaping (Int) -> Void
    ) -> NSSegmentedControl {
        let seg = NSSegmentedControl()
        seg.segmentCount = icons.count
        seg.trackingMode = .selectOne
        seg.segmentStyle = .texturedRounded
        for (i, icon) in icons.enumerated() {
            seg.setImage(NSImage(systemSymbolName: icon.symbol, accessibilityDescription: icon.tip), forSegment: i)
            seg.setToolTip(icon.tip, forSegment: i)
        }
        seg.selectedSegment = selectedIndex
        let handler = ClosureSegmentedHandler(onChange: onChange)
        seg.target = handler
        seg.action = #selector(ClosureSegmentedHandler.changed(_:))
        objc_setAssociatedObject(seg, &ClosureSegmentedHandler.assocKey, handler, .OBJC_ASSOCIATION_RETAIN)
        seg.translatesAutoresizingMaskIntoConstraints = false
        return seg
    }

    // MARK: Text tool defaults

    /// The Text-tool default panel (Text tool selected, nothing selected/edited).
    /// Mirrors the selected-text-object panel (`makeObjectControls` text branch)
    /// so the controls read identically with or without a selection; every field
    /// writes an `EditorState` creation default that seeds the next new text box.
    private static func makeText(state: EditorState) -> NSView {
        let stack = verticalStack()
        let al = state.textAlignment
        let alignIdx = al == .center ? 1 : (al == .right ? 2 : 0)
        let va = state.textVerticalAlignment
        let vIdx = va == .middle ? 1 : (va == .bottom ? 2 : 0)

        // Emphasis control built first so the Weight slider can clear Bold.
        let emphasis = emphasisGroup(
            bold: state.textIsBold, italic: state.textIsItalic,
            underline: state.textUnderline, strike: state.textStrikethrough) { [weak state] b, i, u, s in
                state?.textIsBold = b; state?.textIsItalic = i; state?.textUnderline = u; state?.textStrikethrough = s
            }

        // — Font —
        toolSection(stack, "Font")
        stack.addArrangedSubview(fieldRow("Family", fontFamilyPopup(current: state.textFontFamily) { [weak state] fam in
            state?.textFontFamily = fam
            AnnotationTextFont.remembered = fam
        }))
        stack.addArrangedSubview(fieldRow("Weight", weightSlider(current: state.textWeight,
            onDragStart: {}, onDragEnd: {},
            onChange: { [weak state] w in
                state?.textWeight = w
                // Weight owns the weight axis now — clear the Bold emphasis toggle.
                if state?.textIsBold == true { state?.textIsBold = false; emphasis.setSelected(false, forSegment: 0) }
            })))
        stack.addArrangedSubview(fieldRow("Size", runValueSlider(
            value: Double(state.textFontSize), min: 10, max: 200,
            onDragStart: {}, onDragEnd: {},
            onChange: { [weak state] v in state?.textFontSize = CGFloat(v) })))

        // — Emphasis —
        toolSection(stack, "Emphasis")
        stack.addArrangedSubview(fieldRow("Style", emphasis))

        // — Color — three chips in one row, caption above each.
        toolSection(stack, "Color")
        let colorChip = colorField(
            initial: state.selectedColor, allowsNoColor: false,
            onPick: { [weak state] c in if let c = c { state?.selectedColor = opaqueSRGB(c) } })
        let highlightChip = colorField(
            initial: state.textHighlight, allowsNoColor: true,
            onPick: { [weak state] c in state?.textHighlight = c.map { opaqueSRGB($0) } })
        let outlineChip = colorField(
            initial: state.textOutlineColor, allowsNoColor: true,
            onPick: { [weak state] c in state?.textOutlineColor = c.map { opaqueSRGB($0) } })
        let colorRow = NSStackView(views: [chipColumn("Text", colorChip),
                                           chipColumn("Highlight", highlightChip),
                                           chipColumn("Outline", outlineChip)])
        colorRow.orientation = .horizontal
        colorRow.spacing = 18
        colorRow.alignment = .top
        // Default gravity distribution (not .equalSpacing) keeps the three chips
        // left-packed with a fixed gap so spacing doesn't shift as chip widths
        // change (Highlight/Outline toggling no-color) while clicking around.
        stack.addArrangedSubview(colorRow)
        stack.addArrangedSubview(fieldRow("Outline w", runValueSlider(
            value: Double(state.textOutlineWidth), min: 1, max: 20, unit: "%",
            onDragStart: {}, onDragEnd: {},
            onChange: { [weak state] v in state?.textOutlineWidth = CGFloat(v) })))

        // — Paragraph —
        toolSection(stack, "Paragraph")
        stack.addArrangedSubview(fieldRow("Align", iconChoice(
            ["text.alignleft", "text.aligncenter", "text.alignright"], selected: alignIdx) { [weak state] idx in
                state?.textAlignment = idx == 1 ? .center : (idx == 2 ? .right : .left)
            }))
        stack.addArrangedSubview(fieldRow("Vertical", iconChoice(
            ["arrow.up.to.line", "arrow.up.and.down", "arrow.down.to.line"], selected: vIdx) { [weak state] idx in
                state?.textVerticalAlignment = idx == 1 ? .middle : (idx == 2 ? .bottom : .top)
            }))
        stack.addArrangedSubview(fieldRow("Line sp.", runValueSlider(
            value: Double(state.textLineSpacing), min: 0, max: 40,
            onDragStart: {}, onDragEnd: {},
            onChange: { [weak state] v in state?.textLineSpacing = CGFloat(v) })))

        // — Opacity — (same runValueSlider layout as the inline / object text
        // panels, so the three read identically when rotating states)
        toolSection(stack, "Opacity")
        stack.addArrangedSubview(runValueSlider(
            value: state.creationOpacity * 100, min: 10, max: 100, unit: "%",
            onDragStart: {}, onDragEnd: {},
            onChange: { [weak state] v in state?.creationOpacity = v / 100.0 }))

        toolSection(stack, "Effects")
        stack.addArrangedSubview(shadowRow(
            read: { state.shadowDefault(for: .text) },
            write: { s in state.setShadowDefault(s, for: .text) }))

        return stack
    }

    // MARK: Color row + stroke slider helpers

    private static func colorRow(state: EditorState) -> NSView {
        let chip = colorField(
            initial: state.selectedColor, allowsNoColor: false,
            onPick: { color in if let color = color { state.selectedColor = opaqueSRGB(color) } })
        let row = NSStackView(views: [label("Color", secondary: true), chip])
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY
        return row
    }

    /// A horizontal row of captioned color chips (e.g. Stroke + Fill, or
    /// Number + Fill), laid out shoulder-to-shoulder. The single layout used by
    /// every multi-color panel so they read identically across tools.
    static func colorColumnsRow(_ columns: [(title: String, chip: NSView)]) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 18
        row.alignment = .top
        // `chipColumn` centers each caption over its color chip (vs the leading
        // `labeledColumn`), so Stroke / Fill / Outline sit centered on their wells.
        for c in columns { row.addArrangedSubview(chipColumn(c.title, c.chip)) }
        return row
    }

    /// Side-by-side Stroke + Fill chips for the rectangle/ellipse tool
    /// defaults, mirroring the selected-object panel's layout so the Fill
    /// control reads identically with or without a selection. Stroke seeds
    /// `selectedColor`; Fill seeds `shapeFillColor` (allows "no fill").
    private static func shapeColorRow(state: EditorState) -> NSView {
        let strokeChip = colorField(
            initial: state.selectedColor, allowsNoColor: false,
            onPick: { color in if let color = color { state.selectedColor = opaqueSRGB(color) } })
        let fillChip = colorField(
            initial: state.shapeFillColor, allowsNoColor: true,
            onPick: { color in state.shapeFillColor = color.map { opaqueSRGB($0) } })
        return colorColumnsRow([("Stroke", strokeChip), ("Fill", fillChip),
                                ("Outline", outlineChip(state: state))])
    }


    /// Drag-aware 0–100 slider for Enhance panel draft params (no undo checkpoint).
    /// Uses `StyleEditSlider` so mid-drag pauses don't trigger a sidebar rebuild.
    private static func enhanceDraftSlider(
        value: Double, state: EditorState,
        apply: @escaping (Double) -> Void
    ) -> NSView {
        let handler = ClosureSliderHandler(apply: apply)
        let slider = StyleEditSlider(value: value, minValue: 0, maxValue: 100,
                                     target: handler, action: #selector(ClosureSliderHandler.changed(_:)))
        slider.onDragStart = { [weak state] in state?.beginStyleEdit() }
        slider.onDragEnd = { [weak state] in state?.endStyleEdit() }
        slider.isContinuous = true
        slider.translatesAutoresizingMaskIntoConstraints = false
        objc_setAssociatedObject(slider, &ClosureSliderHandler.assocKey, handler, .OBJC_ASSOCIATION_RETAIN)
        return sliderWithInput(slider, min: 0, max: 100, unit: "", commit: apply)
    }

    /// A continuous slider styled like the object panel's `styleSlider` (no
    /// tick marks, ≥160pt wide) that writes a creation default via `apply`.
    /// No undo checkpoint — editing a default isn't an annotation edit.
    /// Wraps the slider in a `sliderWithInput` row (field + stepper + unit label).
    private static func defaultSlider(
        value: Double, min: Double, max: Double, unit: String = "",
        apply: @escaping (Double) -> Void
    ) -> NSView {
        let handler = ClosureSliderHandler(apply: apply)
        let slider = NSSlider(value: value, minValue: min, maxValue: max,
                              target: handler, action: #selector(ClosureSliderHandler.changed(_:)))
        slider.isContinuous = true
        slider.translatesAutoresizingMaskIntoConstraints = false
        objc_setAssociatedObject(slider, &ClosureSliderHandler.assocKey, handler, .OBJC_ASSOCIATION_RETAIN)
        return sliderWithInput(slider, min: min, max: max, unit: unit, commit: apply)
    }

    /// Wrap `slider` into a row: [slider | field + stepper + unit label].
    /// The slider must already have its own target/action for drag-apply.
    /// `commit` is called only for typed or stepper edits (not on drag).
    private static func sliderWithInput(
        _ slider: NSSlider, min: Double, max: Double, unit: String,
        commit: @escaping (Double) -> Void
    ) -> NSView {
        // Capture existing drag handler so the binder can forward slider drags.
        let originalTarget = slider.target
        let originalAction = slider.action

        let field = NSTextField(string: "")
        field.alignment = .right
        field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 36).isActive = true
        (field.cell as? NSTextFieldCell)?.sendsActionOnEndEditing = true

        let stepper = NSStepper()
        stepper.minValue = min; stepper.maxValue = max; stepper.increment = 1
        stepper.valueWraps = false
        stepper.autorepeat = false
        stepper.translatesAutoresizingMaskIntoConstraints = false

        let binder = SliderInputBinder(
            slider: slider, field: field, stepper: stepper, min: min, max: max,
            commit: commit,
            sliderForward: { s in
                if let originalAction, let originalTarget {
                    _ = (originalTarget as AnyObject).perform(originalAction, with: s)
                }
            })
        // Redirect the slider's action to the binder (it forwards then mirrors).
        slider.target = binder
        slider.action = #selector(SliderInputBinder.sliderChanged(_:))
        field.target = binder
        field.action = #selector(SliderInputBinder.fieldCommitted(_:))
        stepper.target = binder
        stepper.action = #selector(SliderInputBinder.fieldCommitted(_:))
        // Retain the binder on the slider so it lives as long as the slider.
        objc_setAssociatedObject(slider, &SliderInputBinder.assocKey, binder, .OBJC_ASSOCIATION_RETAIN)

        var views: [NSView] = [slider, field, stepper]
        if !unit.isEmpty {
            let u = label(unit, secondary: true)
            u.translatesAutoresizingMaskIntoConstraints = false
            views.append(u)
        }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 6
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        slider.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        return row
    }

    // MARK: Shadow row (Effects section)

    /// A clickable "Shadow" row that shows the current shadow state as a
    /// subtitle and opens a `ShadowPopoverController` on click.
    ///
    /// - Parameters:
    ///   - read: Returns the live `ShadowStyle` to display and use as the
    ///     baseline when the user edits one field inside the popover.
    ///   - write: Called on every change inside the popover; owns
    ///     persistence and (for object controls) undo.
    private static func shadowRow(
        read: @escaping () -> ShadowStyle,
        write: @escaping (ShadowStyle) -> Void,
        onEditBegin: @escaping () -> Void = { },
        onEditEnd: @escaping () -> Void = { },
        onSessionBegin: @escaping () -> Void = { },
        onSessionEnd: @escaping () -> Void = { }
    ) -> NSView {
        ShadowRowView(read: read, write: write,
                      onEditBegin: onEditBegin, onEditEnd: onEditEnd,
                      onSessionBegin: onSessionBegin, onSessionEnd: onSessionEnd)
    }

    // MARK: Shared helpers

    private static func verticalStack() -> NSStackView {
        let s = NSStackView()
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = 10
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }

    /// Thin hairline, inset from the panel edges, used to separate tool-panel
    /// sections (see `toolSection`). An `NSBox` separator so it tracks the
    /// system separator color in light and dark mode.
    private static func sectionDivider(inset: CGFloat = 4) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(box)
        NSLayoutConstraint.activate([
            box.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: inset),
            box.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -inset),
            box.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            container.heightAnchor.constraint(equalToConstant: 1),
        ])
        return container
    }

    /// Add a section header to a tool-properties `stack`, preceded by an inset
    /// hairline divider for every section AFTER the first — so the per-tool
    /// panels read as cleanly separated groups.
    private static func toolSection(_ stack: NSStackView, _ title: String) {
        if !stack.arrangedSubviews.isEmpty {
            let d = sectionDivider()
            stack.addArrangedSubview(d)
            d.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        stack.addArrangedSubview(sectionHeader(title))
    }

    private static func label(_ text: String, secondary: Bool = false) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = NSFont.systemFont(ofSize: 12, weight: secondary ? .regular : .medium)
        if secondary { l.textColor = .secondaryLabelColor }
        return l
    }

    private static func sectionHeader(_ text: String) -> SidebarSectionHeader {
        SidebarSectionHeader(text: text)
    }

    private static func divider() -> NSView {
        // NSBox separator tracks the system separator color across appearance
        // changes on its own — no static cgColor to go stale on a theme switch.
        let v = NSBox()
        v.boxType = .separator
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        return v
    }

    /// A row with an indeterminate, animating progress bar and a caption —
    /// shown while tags/summary are being generated.
    private static func progressRow(_ caption: String) -> NSView {
        let bar = NSProgressIndicator()
        bar.style = .bar
        bar.isIndeterminate = true
        bar.controlSize = .small
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.startAnimation(nil)
        let text = label(caption, secondary: true)
        let row = NSStackView(views: [bar, text])
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 4
        row.translatesAutoresizingMaskIntoConstraints = false
        bar.widthAnchor.constraint(equalToConstant: EditorSidebarView.width - 32).isActive = true
        return row
    }
}

/// Two-way binder that keeps an NSSlider, an NSTextField, and an NSStepper in
/// sync. On slider drag it forwards the event to the original handler (preserving
/// the existing apply path) then mirrors the value into the field. On a typed or
/// stepper edit it clamps, updates the slider, mirrors back, and calls `commit`.
@MainActor
private final class SliderInputBinder: NSObject {
    static var assocKey: UInt8 = 0
    private weak var slider: NSSlider?
    private weak var field: NSTextField?
    private weak var stepper: NSStepper?
    private let minV: Double, maxV: Double
    private let commit: (Double) -> Void
    /// Forwards the slider's drag to the original target/action.
    private let sliderForward: (NSSlider) -> Void

    init(slider: NSSlider, field: NSTextField, stepper: NSStepper,
         min: Double, max: Double,
         commit: @escaping (Double) -> Void,
         sliderForward: @escaping (NSSlider) -> Void) {
        self.slider = slider; self.field = field; self.stepper = stepper
        self.minV = min; self.maxV = max; self.commit = commit
        self.sliderForward = sliderForward
        super.init()
        syncFieldToSlider()
    }

    private func syncFieldToSlider() {
        guard let slider, let field, let stepper else { return }
        field.stringValue = SliderInputFormat.display(slider.doubleValue, unit: "")
        stepper.doubleValue = slider.doubleValue
    }

    /// Slider moved: forward to the original apply action, then mirror into field.
    @objc func sliderChanged(_ s: NSSlider) {
        sliderForward(s)
        syncFieldToSlider()
    }

    /// Typed value committed (Enter / focus-out) or stepper clicked.
    @objc func fieldCommitted(_ sender: Any?) {
        guard let slider, let field else { return }
        let v: Int
        if let stepperSender = sender as? NSStepper {
            v = Int(Swift.min(maxV, Swift.max(minV, stepperSender.doubleValue)).rounded())
        } else {
            v = SliderInputFormat.clamp(field.stringValue, min: minV, max: maxV,
                                        fallback: slider.doubleValue)
        }
        if Int(slider.doubleValue.rounded()) == v { syncFieldToSlider(); return }
        slider.doubleValue = Double(v)
        syncFieldToSlider()
        commit(Double(v))
    }
}

/// Applies a picked color to the selected annotation's style, recording exactly
/// one undo checkpoint per chip session (first change after the popover opens),
/// mirroring the slider drag behavior.
@MainActor
final class StyleColorApplier {
    private let state: EditorState
    private let id: UUID
    private let apply: (inout Style, NSColor?) -> Void
    private var didCheckpoint = false

    init(state: EditorState, id: UUID, apply: @escaping (inout Style, NSColor?) -> Void) {
        self.state = state
        self.id = id
        self.apply = apply
    }

    func begin() { didCheckpoint = false }

    func pick(_ color: NSColor?) {
        if !didCheckpoint { state.recordUndoCheckpoint(action: "Change Color"); didCheckpoint = true }
        state.updateStyle(id: id) { self.apply(&$0, color) }
    }
}

/// Applies a picked color uniformly to every run of the selected text box,
/// one undo checkpoint per chip session (mirrors `StyleColorApplier`).
@MainActor
final class TextRunColorApplier {
    private let state: EditorState
    private let id: UUID
    private var didCheckpoint = false
    init(state: EditorState, id: UUID) { self.state = state; self.id = id }
    func begin() { didCheckpoint = false }
    func pick(_ color: NSColor?) {
        guard let color = color else { return }
        if !didCheckpoint { state.recordUndoCheckpoint(action: "Change Color"); didCheckpoint = true }
        let c = SerializableColor(opaqueSRGB(color))
        state.updateTextRuns(id: id) { runs in for i in runs.indices { runs[i].color = c } }
    }
}

/// Sets a uniform font size on every run of the selected text box. The slider
/// checkpoints once at drag start (via `StyleEditSlider.onDragStart`).
@MainActor
private final class TextRunFontSizeHandler: NSObject {
    static var assocKey: UInt8 = 0
    let state: EditorState
    let id: UUID
    init(state: EditorState, id: UUID) { self.state = state; self.id = id }
    @objc func changed(_ s: NSSlider) {
        let size = CGFloat(s.doubleValue)
        state.updateTextRuns(id: id) { runs in for i in runs.indices { runs[i].fontSize = size } }
    }
}

/// Target for the font-family dropdown; forwards the chosen family (nil = System).
@MainActor
private final class FontFamilyPopupHandler: NSObject {
    static var assocKey: UInt8 = 0
    let onPick: (String?) -> Void
    init(onPick: @escaping (String?) -> Void) { self.onPick = onPick }
    @objc func changed(_ p: NSPopUpButton) {
        onPick(p.selectedItem?.representedObject as? String)
    }
}

/// Closure target for a labelled on/off switch.
@MainActor
private final class SwitchHandler: NSObject {
    static var assocKey: UInt8 = 0
    let onChange: (Bool) -> Void
    init(_ onChange: @escaping (Bool) -> Void) { self.onChange = onChange }
    @objc func toggled(_ s: NSSwitch) { onChange(s.state == .on) }
}

/// Target for the emphasis icon group; forwards all four toggle states.
@MainActor
private final class EmphasisHandler: NSObject {
    static var assocKey: UInt8 = 0
    let onChange: (Bool, Bool, Bool, Bool) -> Void
    init(_ onChange: @escaping (Bool, Bool, Bool, Bool) -> Void) { self.onChange = onChange }
    @objc func changed(_ s: NSSegmentedControl) {
        onChange(s.isSelected(forSegment: 0), s.isSelected(forSegment: 1),
                 s.isSelected(forSegment: 2), s.isSelected(forSegment: 3))
    }
}

/// Target for a single-select icon group; forwards the chosen segment index.
@MainActor
private final class IconChoiceHandler: NSObject {
    static var assocKey: UInt8 = 0
    let onSelect: (Int) -> Void
    init(_ onSelect: @escaping (Int) -> Void) { self.onSelect = onSelect }
    @objc func changed(_ s: NSSegmentedControl) { onSelect(s.selectedSegment) }
}

/// Sets a uniform bold weight on every run of the selected text box.
@MainActor
private final class TextRunBoldHandler: NSObject {
    static var assocKey: UInt8 = 0
    let state: EditorState
    let id: UUID
    init(state: EditorState, id: UUID) { self.state = state; self.id = id }
    @objc func toggled(_ s: NSSwitch) {
        state.recordUndoCheckpoint(action: "Bold")
        let bold = s.state == .on
        state.updateTextRuns(id: id) { runs in for i in runs.indices { runs[i].isBold = bold } }
    }
}

/// `NSButton` that invokes a stored closure on click, so the stateless
/// `EditorToolPropertiesViews` factories don't need an `@objc` target object.
@MainActor
final class ClosureButton: NSButton {
    private var onClick: (() -> Void)?
    private var baseTitle: String = ""
    private var resetWork: DispatchWorkItem?

    convenience init(title: String, onClick: @escaping () -> Void) {
        self.init(frame: .zero)
        self.title = title
        self.baseTitle = title
        self.bezelStyle = .rounded
        self.onClick = onClick
        self.target = self
        self.action = #selector(fire)
    }

    @objc private func fire() { onClick?() }

    /// Briefly replace the title with a "✓ Copied" confirmation, then restore.
    /// Used so a Live Text copy confirms on the button the user actually pressed
    /// (or that ⌘C maps to) rather than the whole-image copy button.
    func flashConfirmation(_ message: String = "✓ Copied") {
        resetWork?.cancel()
        title = message
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.title = self.baseTitle
        }
        resetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3, execute: work)
    }
}

/// Routes the crop-aspect popup's selection back into `EditorState`.
/// Kept as a separate object so the popup can retain it via
/// `objc_setAssociatedObject` (NSControl actions need an Obj-C target).
@MainActor
private final class AspectHandler: NSObject {
    static var assocKey: UInt8 = 0
    let state: EditorState
    init(state: EditorState) { self.state = state }

    @objc func popupChanged(_ sender: NSPopUpButton) {
        let idx = sender.indexOfSelectedItem
        let aspects: [CGFloat?] = [nil, 1.0, 16.0 / 9.0, 4.0 / 3.0]
        guard aspects.indices.contains(idx) else { return }
        state.cropAspectRatio = aspects[idx]
        if let ratio = aspects[idx], let pending = state.pendingCrop {
            let imgSize = state.croppedRect?.size
                ?? CGSize(width: state.sourceImage.width, height: state.sourceImage.height)
            let bounds = CGRect(origin: .zero, size: imgSize)
            state.pendingCrop = aspectConstrainedRect(pending, aspect: ratio,
                                                      anchor: pending.origin, bounds: bounds)
        }
    }
}

/// Confirm-crop button handler. Also subscribes to `state.pendingCrop`
/// changes so the button can enable/disable reactively.
@MainActor
private final class ConfirmCropHandler: NSObject {
    static var assocKey: UInt8 = 0
    let state: EditorState
    let onCommit: () -> Void
    private var refreshEnabled: (() -> Void)?

    init(state: EditorState, onCommit: @escaping () -> Void) {
        self.state = state
        self.onCommit = onCommit
    }

    func startObserving(_ refresh: @escaping () -> Void) {
        self.refreshEnabled = refresh
        observe()
    }

    private func observe() {
        withObservationTracking {
            _ = state.pendingCrop
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.refreshEnabled?()
                self?.observe()
            }
        }
    }

    @objc func clicked() {
        onCommit()
    }
}

/// Observes `EditorState.cropActionSignal` and flashes a checkmark on the crop
/// panel's matching button — so a Cut/Copy/Soft/Crop action confirms visibly
/// whether it was triggered by the button OR its keyboard shortcut.
@MainActor
private final class CropActionFlashHandler: NSObject {
    static var assocKey: UInt8 = 0
    let state: EditorState
    private var lastSeq: Int
    private let flash: (EditorState.CropAction) -> Void

    init(state: EditorState, flash: @escaping (EditorState.CropAction) -> Void) {
        self.state = state
        self.flash = flash
        self.lastSeq = state.cropActionSignal?.seq ?? 0
        super.init()
        observe()
    }

    private func observe() {
        withObservationTracking {
            _ = state.cropActionSignal
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if let sig = self.state.cropActionSignal, sig.seq != self.lastSeq {
                    self.lastSeq = sig.seq
                    self.flash(sig.action)
                }
                self.observe()
            }
        }
    }
}


/// Generic slider handler that forwards the value to a closure — used for
/// tool-default sliders that write creation defaults on `EditorState`.
@MainActor
private final class ClosureSliderHandler: NSObject {
    static var assocKey: UInt8 = 0
    let apply: (Double) -> Void
    init(apply: @escaping (Double) -> Void) { self.apply = apply }
    @objc func changed(_ sender: NSSlider) { apply(sender.doubleValue) }
}

private final class ClosureSegmentedHandler: NSObject {
    static var assocKey: UInt8 = 0
    let onChange: (Int) -> Void
    init(onChange: @escaping (Int) -> Void) { self.onChange = onChange }
    @objc func changed(_ sender: NSSegmentedControl) { onChange(sender.selectedSegment) }
}

private final class ClosurePopupHandler: NSObject {
    static var assocKey: UInt8 = 0
    let onChange: (Int) -> Void
    init(onChange: @escaping (Int) -> Void) { self.onChange = onChange }
    @objc func changed(_ sender: NSPopUpButton) { onChange(sender.indexOfSelectedItem) }
}

/// NSSlider that records one undo checkpoint at drag start, then reports
/// continuous values, so a slider drag is a single undo step.
final class StyleEditSlider: NSSlider {
    var onDragStart: (() -> Void)?
    var onDragEnd: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        onDragStart?()
        super.mouseDown(with: event)   // tracks the drag, firing the action continuously
        onDragEnd?()                    // returns when the mouse is released
    }
}

@MainActor
private final class StyleSliderHandler: NSObject {
    static var assocKey: UInt8 = 0
    let state: EditorState
    let id: UUID
    let apply: (inout Style, Double) -> Void
    init(state: EditorState, id: UUID, apply: @escaping (inout Style, Double) -> Void) {
        self.state = state; self.id = id; self.apply = apply
    }
    @objc func changed(_ sender: NSSlider) {
        let v = sender.doubleValue
        state.updateStyle(id: id) { self.apply(&$0, v) }
    }
}

/// Replace… button on the image object panel: picks a raster file and swaps
/// the annotation's bitmap (EditorState owns the undo step + rect re-fit).
@MainActor
private final class ReplaceImageHandler: NSObject {
    static var assocKey: UInt8 = 0
    private let state: EditorState
    private let id: UUID
    init(state: EditorState, id: UUID) { self.state = state; self.id = id }

    @objc func replace() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = EditorWindowController.overlayImageTypes
        panel.prompt = "Replace"
        guard panel.runModal() == .OK, let url = panel.urls.first,
              let image = EditorWindowController.loadOverlayImage(from: url) else { return }
        state.replaceImageAsset(annotationID: id, with: image)
    }
}

/// Drives the selected badge's radius from the object-panel "Size" slider
/// (badge size lives in the geometry, not the style).
@MainActor
private final class BadgeRadiusHandler: NSObject {
    static var assocKey: UInt8 = 0
    let state: EditorState
    let id: UUID
    init(state: EditorState, id: UUID) { self.state = state; self.id = id }
    @objc func changed(_ sender: NSSlider) {
        state.updateBadgeRadius(id: id, CGFloat(sender.doubleValue))
    }
}

@MainActor
private final class SessionFontSizeHandler: NSObject {
    static var assocKey: UInt8 = 0
    let session: TextEditingSession
    init(session: TextEditingSession) { self.session = session }
    @objc func changed(_ s: NSSlider) { session.applyFontSize(CGFloat(s.doubleValue)) }
}

@MainActor
private final class SessionBoldHandler: NSObject {
    static var assocKey: UInt8 = 0
    let session: TextEditingSession
    init(session: TextEditingSession) { self.session = session }
    @objc func toggled(_ s: NSSwitch) { session.setBold(s.state == .on) }
}

@MainActor
private final class TextFontSizeHandler: NSObject {
    static var assocKey: UInt8 = 0
    let state: EditorState
    init(state: EditorState) { self.state = state }
    @objc func changed(_ sender: NSSlider) { state.textFontSize = CGFloat(sender.doubleValue) }
}

@MainActor
private final class TextBoldDefaultHandler: NSObject {
    static var assocKey: UInt8 = 0
    let state: EditorState
    init(state: EditorState) { self.state = state }
    @objc func toggled(_ sender: NSSwitch) { state.textIsBold = (sender.state == .on) }
}

/// A wrapping, selectable label that reflows to its CURRENT width — so it re-wraps
/// (and re-heights) as the sidebar is resized, instead of wrapping at a fixed
/// width. Wraps on word boundaries (never mid-word). Pin its width to the
/// container so it has a definite, dynamic width to wrap within.
final class WrappingLabel: NSTextField {
    init(string: String) {
        super.init(frame: .zero)
        isEditable = false
        isBezeled = false
        drawsBackground = false
        isSelectable = true
        font = NSFont.systemFont(ofSize: 12, weight: .regular)
        textColor = .secondaryLabelColor
        lineBreakMode = .byWordWrapping
        maximumNumberOfLines = 0
        stringValue = string
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not implemented") }

    override func layout() {
        super.layout()
        // Wrap to the actual width and recompute height whenever it changes.
        if abs(preferredMaxLayoutWidth - bounds.width) > 0.5 {
            preferredMaxLayoutWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
    }
}

/// A determinate progress bar bound to an `EditorState` fraction (0…1), updating
/// live (without rebuilding the panel) via Observation. `value` must read the
/// observed `@Observable` property so changes re-fire; capture state weakly.
@MainActor
final class DeterminateProgressBar: NSView {
    private let bar = NSProgressIndicator()
    private let value: () -> Double?

    init(value: @escaping () -> Double?) {
        self.value = value
        super.init(frame: .zero)
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.controlSize = .small
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.topAnchor.constraint(equalTo: topAnchor),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        observe()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not implemented") }

    private func observe() {
        bar.doubleValue = value() ?? 0
        withObservationTracking {
            _ = value()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }
}

/// A read-only, word-wrapping text view that displays an attributed string and
/// auto-sizes its height to the content at its current width — reflowing as the
/// sidebar is resized. Unlike NSTextField, it keeps its attributed formatting
/// (bullets, colours, paragraph style) when clicked, and stays selectable for
/// copy. Pin its width to the container for a definite, dynamic wrap width.
class WrappingTextView: NSTextView {
    init() {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        isEditable = false
        isSelectable = true
        drawsBackground = false
        textContainerInset = .zero
        isVerticallyResizable = true
        isHorizontallyResizable = false
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.defaultHigh, for: .vertical)
        setContentCompressionResistancePriority(.defaultHigh, for: .vertical)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not implemented") }

    func setAttributed(_ s: NSAttributedString) {
        textStorage?.setAttributedString(s)
        invalidateIntrinsicContentSize()
    }

    // Drop the selection when focus leaves (e.g. clicking elsewhere), so a stale
    // highlight doesn't linger.
    override func resignFirstResponder() -> Bool {
        setSelectedRange(NSRange(location: 0, length: 0))
        return super.resignFirstResponder()
    }

    override var intrinsicContentSize: NSSize {
        guard let lm = layoutManager, let tc = textContainer else { return super.intrinsicContentSize }
        lm.ensureLayout(for: tc)
        return NSSize(width: NSView.noIntrinsicMetric, height: ceil(lm.usedRect(for: tc).height))
    }

    /// False when hosted in SwiftUI (NSViewRepresentable sizes the view via
    /// sizeThatFits): invalidating constraints from inside layout() there
    /// dirties the window's constraints mid display-flush and AppKit throws
    /// (crash: recursive _layoutSubtreeWithOldSize → NSException). In plain
    /// AppKit stacks the invalidation is what re-fits height on width change.
    var invalidatesIntrinsicSizeOnLayout = true

    override func layout() {
        super.layout()
        if invalidatesIntrinsicSizeOnLayout {
            invalidateIntrinsicContentSize()   // recompute height when width changes
        }
    }
}

/// Lays its chip subviews out left-to-right, wrapping to a new row when the next
/// chip won't fit the available width — so tags flow multiple-per-row instead of
/// one-per-row. Self-sizes its height via a constraint so it slots into the
/// Info panel's vertical stack, and re-flows on width changes (sidebar resize).
final class WrappingChipView: NSView {
    private let hSpacing: CGFloat
    private let vSpacing: CGFloat
    private var heightConstraint: NSLayoutConstraint!

    init(hSpacing: CGFloat = 6, vSpacing: CGFloat = 6) {
        self.hSpacing = hSpacing
        self.vSpacing = vSpacing
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightConstraint = heightAnchor.constraint(equalToConstant: 0)
        heightConstraint.isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not implemented") }

    /// Top-to-bottom row order.
    override var isFlipped: Bool { true }

    /// Re-flow when our width changes (the stack/host width follows the
    /// resizable sidebar).
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    func addChip(_ chip: NSView) {
        chip.translatesAutoresizingMaskIntoConstraints = true
        addSubview(chip)
        needsLayout = true
    }

    func removeChip(_ chip: NSView) {
        chip.removeFromSuperview()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let maxW = bounds.width
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for chip in subviews {
            let size = chip.fittingSize
            // Wrap to the next row when this chip won't fit (but never wrap the
            // first chip of a row, even if it alone overflows a narrow panel).
            if x > 0 && x + size.width > maxW {
                x = 0
                y += rowHeight + vSpacing
                rowHeight = 0
            }
            chip.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
            x += size.width + hSpacing
            rowHeight = max(rowHeight, size.height)
        }
        let total = subviews.isEmpty ? 0 : (y + rowHeight)
        if abs(heightConstraint.constant - total) > 0.5 {
            heightConstraint.constant = total
        }
    }
}

/// Handles the "Add tag…" text field in the Tags section of the Info panel.
/// On commit (Return / end-editing), normalizes + appends the entered tag,
/// persists it, posts `.captureMetadataDidChange`, and adds a new chip row.
/// Retained via `objc_setAssociatedObject` on the `NSTextField`.
@MainActor
final class TagAddFieldHandler: NSObject, NSTextFieldDelegate {
    static var assocKey: UInt8 = 0

    /// Standardized path of the capture whose tag field should regain focus
    /// after the next Info-panel rebuild. A tag commit posts
    /// `.captureMetadataDidChange`, which rebuilds the whole panel ~60 ms later
    /// and destroys the focused field; set on the "keep typing" commit paths
    /// (Return / dropdown pick) so the freshly-built field can steal focus back.
    /// Cleared as soon as it's consumed.
    static var pendingRefocusPath: String?

    private let url: URL
    private weak var addField: NSTextField?
    private weak var chipsContainer: WrappingChipView?
    private let buildChipRow: (String) -> NSView

    /// Live tag vocabulary for autocomplete suggestions. Starts empty and is
    /// refreshed asynchronously from the library index at construction and
    /// whenever editing begins; an empty vocabulary still allows normal tag entry.
    private var vocabulary: TagVocabulary = TagVocabulary(entries: [])

    /// Style-A suggestion dropdown anchored below the field. Immune to the
    /// sidebar NSScrollView clip because it renders as a child NSWindow.
    private let dropdown = TagSuggestionDropdown()

    init(url: URL,
         addField: NSTextField,
         chipsContainer: WrappingChipView,
         buildChipRow: @escaping (String) -> NSView) {
        self.url = url
        self.addField = addField
        self.chipsContainer = chipsContainer
        self.buildChipRow = buildChipRow
        super.init()
        dropdown.onPick = { [weak self] sugg in self?.commit(sugg.tag, keepFocus: true) }

        // If a prior commit on this capture asked to keep focus, the Info panel
        // just rebuilt and tore down the focused field — grab focus back on this
        // new one. Deferred one runloop turn so the field is mounted in the
        // window first (at init time it isn't in the view hierarchy yet).
        if Self.pendingRefocusPath == url.standardizedFileURL.path {
            Self.pendingRefocusPath = nil
            let field = addField
            DispatchQueue.main.async {
                field.window?.makeFirstResponder(field)
            }
        }
    }

    /// Refresh the vocabulary from the shared library index actor. Safe to call
    /// on every focus; degrades to an empty vocabulary when the index is locked
    /// or unavailable. `TagVocabulary` is `Sendable`, so it crosses the actor
    /// boundary back to the main actor cleanly.
    func refreshVocabulary() {
        Task { [weak self] in
            let vocab = await LibraryIndexStore.shared.vocabulary()
            self?.vocabulary = vocab
        }
    }

    /// Pure decision logic for committing a typed tag: format the input
    /// (formatting only — no singularization, no synonym substitution), dedup
    /// against existing tags, and report the tag actually added (nil when nothing
    /// new was added). The typed word is kept verbatim; singular/synonym forms
    /// are offered as suggestions, never applied on commit.
    nonisolated static func resolveCommit(input: String,
                                          existing: [String])
        -> (tags: [String], added: String?) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let formatted = TagNormalizer.format([trimmed]).first else {
            return (existing, nil)
        }
        let before = existing
        let tags = TagNormalizer.format(existing + [formatted])
        let added = tags.count > before.count ? tags.last : nil
        return (tags, added)
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        refreshVocabulary()
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        let typed = field.stringValue.trimmingCharacters(in: .whitespaces)
        let s = vocabulary.suggestions(for: typed, limit: 6)
        if typed.count >= 2 && !s.isEmpty {
            dropdown.update(suggestions: s, below: field)
        } else {
            dropdown.hide()
        }
    }

    func control(_ control: NSControl,
                 textView: NSTextView,
                 doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            guard dropdown.isVisible else { return false }
            dropdown.moveSelection(1); return true
        case #selector(NSResponder.moveUp(_:)):
            guard dropdown.isVisible else { return false }
            dropdown.moveSelection(-1); return true
        case #selector(NSResponder.insertNewline(_:)):
            if let pick = dropdown.selected {
                commit(pick.tag, keepFocus: true)
            } else {
                commit(addField?.stringValue ?? "", keepFocus: true)
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            dropdown.hide()
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        dropdown.hide()
        commit(field.stringValue)
    }

    /// Persist + chip + notification for a single tag text. No-op when the text
    /// is empty or results in a duplicate. Always clears the field and hides the
    /// dropdown. `keepFocus` (Return / dropdown pick) re-asserts first responder
    /// on the field the Info-panel rebuild will replace; the natural-resign path
    /// (clicking away) passes false so focus goes where the user clicked.
    private func commit(_ text: String, keepFocus: Bool = false) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            addField?.stringValue = ""
            dropdown.hide()
            return
        }
        var addedTag: String?
        try? SealMetadataStore.update(at: url, createIfMissing: true) { m in
            let result = Self.resolveCommit(input: text, existing: m.tags)
            m.tags = result.tags
            addedTag = result.added
        }
        if let newTag = addedTag {
            // Arm the refocus BEFORE posting: the post rebuilds the panel and
            // constructs the replacement field, whose init consumes this flag.
            if keepFocus { Self.pendingRefocusPath = url.standardizedFileURL.path }
            NotificationCenter.default.post(name: .captureMetadataDidChange, object: url)
            chipsContainer?.addChip(buildChipRow(newTag))
        }
        addField?.stringValue = ""
        dropdown.hide()
    }
}

/// Click-to-edit capture name (Info panel) — the same in-place pattern as
/// the summary: displays the FULL name wrapped (never truncated); a click
/// begins editing; ↩ or focus loss commits a non-empty CHANGED name via the
/// controller's safe rename path; Esc — or an empty/unchanged commit —
/// reverts. (The title-bar name is read-only; this is the editing surface.)
final class EditableNameView: WrappingTextView {
    private let currentName: () -> String
    private let onRename: (String) -> Void
    private var editing = false
    /// Shown after a commit until the panel rebuilds with the renamed URL.
    private var optimisticName: String?

    init(currentName: @escaping () -> String, onRename: @escaping (String) -> Void) {
        self.currentName = currentName
        self.onRename = onRename
        super.init()
        renderDisplay()
    }

    private var displayName: String { optimisticName ?? currentName() }

    private func renderDisplay() {
        isEditable = false
        setAttributed(NSAttributedString(
            string: displayName,
            attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .regular),
                         .foregroundColor: NSColor.secondaryLabelColor]))
        toolTip = displayName
    }

    override func mouseDown(with event: NSEvent) {
        guard editing else { beginEditing(); return }
        super.mouseDown(with: event)
    }

    private func beginEditing() {
        // Caret lands where the user clicked (no select-all) — matching the
        // summary's click-to-edit feel; ⌘A still selects all when wanted.
        editing = true
        isEditable = true
        font = NSFont.systemFont(ofSize: 12)
        textColor = .labelColor
        string = displayName
        window?.makeFirstResponder(self)
    }

    override func insertNewline(_ sender: Any?) {
        // A name is one logical line: ↩ commits instead of inserting a break.
        window?.makeFirstResponder(nil)   // resign → commit
    }

    override func cancelOperation(_ sender: Any?) {
        guard editing else { return }
        editing = false
        renderDisplay()
        window?.makeFirstResponder(nil)
    }

    override func resignFirstResponder() -> Bool {
        if editing { commit() }
        return super.resignFirstResponder()
    }

    private func commit() {
        editing = false
        isEditable = false
        let entered = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if !entered.isEmpty, entered != displayName {
            optimisticName = entered
            onRename(entered)
        }
        renderDisplay()
    }
}

/// Click-to-edit summary (v13): displays the effective summary (the user's
/// override wins) with keyword emphasis; a click begins an in-place plain-
/// text edit. Click-away or ⌘↩ commits — text equal to the generated summary
/// (or emptied) clears the override; Esc cancels. Right-click offers
/// "Revert to Generated Summary" while an override exists.
final class EditableSummaryView: WrappingTextView {
    private let url: URL
    private let generated: String
    private var overrideText: String?
    private let highlightTags: [String]
    private var editing = false

    init(url: URL, generated: String?, userSummary: String?, highlightTags: [String]) {
        self.url = url
        self.generated = (generated ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // Preserve the three states: nil = no override, "" = suppressed (blank
        // on purpose), text = override. Only whitespace is normalized away.
        self.overrideText = userSummary.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        self.highlightTags = highlightTags
        super.init()
        renderDisplay()
    }

    /// The text to show: the override (which may be "" = suppressed/blank) when
    /// present, else the generated summary. Mirrors CaptureMetadata.effectiveSummary.
    private var effective: String { overrideText ?? generated }

    private func renderDisplay() {
        isEditable = false
        if effective.isEmpty {
            let para = NSMutableParagraphStyle()
            para.lineHeightMultiple = 1.30
            setAttributed(NSAttributedString(
                string: "No summary yet. Click to write one.",
                attributes: [.font: NSFont.systemFont(ofSize: 12),
                             .foregroundColor: NSColor.tertiaryLabelColor,
                             .paragraphStyle: para]))
        } else {
            setAttributed(SummaryLayout.attributedSummary(
                effective, tags: highlightTags,
                font: NSFont.systemFont(ofSize: 12, weight: .regular),
                bodyColor: .secondaryLabelColor, bulletColor: .tertiaryLabelColor,
                lineHeightMultiple: 1.30))
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard editing else { beginEditing(); return }
        super.mouseDown(with: event)
    }

    private func beginEditing() {
        editing = true
        isEditable = true
        font = NSFont.systemFont(ofSize: 12)
        textColor = .labelColor
        string = effective
        window?.makeFirstResponder(self)
    }

    override func cancelOperation(_ sender: Any?) {
        guard editing else { return }
        editing = false
        renderDisplay()
        window?.makeFirstResponder(nil)
    }

    override func keyDown(with event: NSEvent) {
        // ⌘↩ commits; plain ↩ inserts a newline (summaries are multi-line).
        if editing, event.modifierFlags.contains(.command), event.keyCode == 36 {
            window?.makeFirstResponder(nil)   // resign → commit
            return
        }
        super.keyDown(with: event)
    }

    override func resignFirstResponder() -> Bool {
        if editing { commit() }
        return super.resignFirstResponder()
    }

    private func commit() {
        editing = false
        isEditable = false
        let text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        // Three outcomes:
        // - text matches the generated summary → clear the override (nil) so it
        //   reads as generated and stays regenerable (same as Revert).
        // - text emptied while a generated summary exists → SUPPRESS ("") so the
        //   deletion sticks instead of snapping back to the generated text.
        // - otherwise → store the edited text.
        let newOverride: String?
        if text == generated {
            newOverride = nil
        } else if text.isEmpty {
            newOverride = generated.isEmpty ? nil : ""
        } else {
            newOverride = text
        }
        if newOverride != overrideText {
            overrideText = newOverride
            try? SealMetadataStore.update(at: url, createIfMissing: true) {
                $0.userSummary = newOverride
            }
            NotificationCenter.default.post(name: .captureMetadataDidChange, object: url)
        }
        renderDisplay()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        if overrideText != nil, !generated.isEmpty {
            let item = NSMenuItem(title: "Revert to Generated Summary",
                                  action: #selector(revertToGenerated), keyEquivalent: "")
            item.target = self
            menu.insertItem(item, at: 0)
            menu.insertItem(.separator(), at: 1)
        }
        return menu
    }

    @objc private func revertToGenerated() {
        overrideText = nil
        try? SealMetadataStore.update(at: url, createIfMissing: true) { $0.userSummary = nil }
        NotificationCenter.default.post(name: .captureMetadataDidChange, object: url)
        renderDisplay()
    }
}

/// Arrange buttons on the object panel — routes to reorderSelected (which
/// owns undo + no-op suppression).
@MainActor
private final class ZOrderButtonsHandler: NSObject {
    static var assocKey: UInt8 = 0
    private let state: EditorState
    init(state: EditorState) { self.state = state }
    @objc func toFront() { state.reorderSelected(.toFront) }
    @objc func forward() { state.reorderSelected(.forward) }
    @objc func backward() { state.reorderSelected(.backward) }
    @objc func toBack() { state.reorderSelected(.toBack) }
}

/// Transform controls on the object panel. setRotation/flipSelected own
/// undo + no-op suppression; the handler just keeps field and stepper in
/// sync with each other.
@MainActor
private final class TransformControlsHandler: NSObject {
    static var assocKey: UInt8 = 0
    private let state: EditorState
    private let id: UUID
    weak var field: NSTextField?
    weak var stepper: NSStepper?
    init(state: EditorState, id: UUID) { self.state = state; self.id = id }

    @objc func angleEntered(_ sender: NSTextField) {
        let degrees = normalizedDegrees(CGFloat(sender.doubleValue))
        state.setRotation(annotationID: id, degrees: degrees)
        sender.stringValue = "\(Int(degrees.rounded()))"
        stepper?.integerValue = Int(degrees.rounded())
    }
    @objc func stepperChanged(_ sender: NSStepper) {
        state.setRotation(annotationID: id, degrees: CGFloat(sender.integerValue))
        field?.stringValue = "\(sender.integerValue)"
    }
    @objc func flipH() { state.selectedAnnotationID = id; state.flipSelected(horizontal: true) }
    @objc func flipV() { state.selectedAnnotationID = id; state.flipSelected(horizontal: false) }
}

/// Non-interactive rounded-rect color preview for the Shadow row.
/// Hit-testing is disabled so mouse events fall through to the parent row.
@MainActor
private final class ShadowColorSwatchView: NSView {
    private var color: NSColor
    private var enabled: Bool

    init(color: NSColor, enabled: Bool) {
        self.color = color
        self.enabled = enabled
        super.init(frame: NSRect(x: 0, y: 0, width: 24, height: 18))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 24).isActive = true
        heightAnchor.constraint(equalToConstant: 18).isActive = true
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)
        let alpha: CGFloat = enabled ? 1.0 : 0.35
        color.withAlphaComponent(alpha).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.25).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    /// Prevent this view from capturing mouse events; let the parent row handle clicks.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Clickable row in the tool-properties panel that shows the current shadow
/// state and opens a `ShadowPopoverController` in a transient popover on click.
/// Holds the popover as an instance var so it is not prematurely deallocated.
@MainActor
private final class ShadowRowView: NSView {

    private let read: () -> ShadowStyle
    private let write: (ShadowStyle) -> Void
    private let onEditBegin: () -> Void
    private let onEditEnd: () -> Void
    // Session callbacks: beginStyleEdit held for the entire time the popover is
    // open (object path only) so that mid-session annotation changes do not
    // trigger a panel rebuild that would close the popover.
    private let onSessionBegin: () -> Void
    private let onSessionEnd: () -> Void
    private var popover: NSPopover?

    init(read: @escaping () -> ShadowStyle, write: @escaping (ShadowStyle) -> Void,
         onEditBegin: @escaping () -> Void = { }, onEditEnd: @escaping () -> Void = { },
         onSessionBegin: @escaping () -> Void = { }, onSessionEnd: @escaping () -> Void = { }) {
        self.read = read
        self.write = write
        self.onEditBegin = onEditBegin
        self.onEditEnd = onEditEnd
        self.onSessionBegin = onSessionBegin
        self.onSessionEnd = onSessionEnd
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        buildLayout(shadow: read())
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func buildLayout(shadow: ShadowStyle) {
        let titleLabel = NSTextField(labelWithString: "Shadow")
        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)

        let sub = shadow.enabled
            ? "Drop · \(Int(shadow.blur))px · \(Int(shadow.opacity * 100))%"
            : "Off"
        let subtitleLabel = NSTextField(labelWithString: sub)
        subtitleLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        subtitleLabel.textColor = .secondaryLabelColor

        let leftStack = NSStackView(views: [titleLabel, subtitleLabel])
        leftStack.orientation = .vertical
        leftStack.alignment = .leading
        leftStack.spacing = 2
        leftStack.translatesAutoresizingMaskIntoConstraints = false

        let cfg = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
        let chevron = NSImageView()
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.image = NSImage(systemSymbolName: "chevron.right",
                                accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        chevron.contentTintColor = .tertiaryLabelColor

        let swatch = ShadowColorSwatchView(color: shadow.color.nsColor, enabled: shadow.enabled)

        let row = NSStackView(views: [swatch, leftStack, chevron])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        row.translatesAutoresizingMaskIntoConstraints = false

        // Keep chevron at its natural size; let the label group expand.
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        chevron.setContentCompressionResistancePriority(.required, for: .horizontal)

        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        heightAnchor.constraint(greaterThanOrEqualToConstant: 38).isActive = true
    }

    // Draw a light rounded border so the row reads as a tappable item.
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        // Second click while the popover is open → toggle it closed.
        if let pop = popover, pop.isShown {
            pop.close()
            return
        }
        // Begin style-edit session (object path only; tool-default is a no-op).
        onSessionBegin()
        let controller = ShadowPopoverController(read: read, write: write)
        controller.onEditBegin = onEditBegin
        controller.onEditEnd = onEditEnd
        let pop = NSPopover()
        pop.behavior = .transient
        pop.delegate = self
        pop.contentViewController = controller
        pop.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
        popover = pop
    }

    /// Route all clicks to self so child labels and the swatch do not absorb
    /// mouse events — the entire row is one click target.
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override var isFlipped: Bool { true }
}

extension ShadowRowView: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        onSessionEnd()
        popover = nil
    }
}
/// Keep the Enhance panel's Enabled switch in sync with `state.showingEnhanced`
/// when it changes underneath (undo/redo, base exclusivity). Re-arms per change;
/// the observation dies with the switch (weak).
@MainActor
private func mirrorEnhanceSwitch(_ sw: NSSwitch, state: EditorState) {
    withObservationTracking {
        _ = state.showingEnhanced
    } onChange: { [weak sw, weak state] in
        Task { @MainActor in
            guard let sw, let state else { return }
            let desired: NSControl.StateValue = state.showingEnhanced ? .on : .off
            if sw.state != desired { sw.state = desired }
            mirrorEnhanceSwitch(sw, state: state)
        }
    }
}

// MARK: - Enhance panel handlers

/// Handles the Enabled `NSSwitch` in the Enhance panel. Sets `showingEnhanced`;
/// if turned on with no existing enhanced image, fires `onApply` to auto-run.
@MainActor
private final class EnhanceToggleHandler: NSObject {
    static var assocKey: UInt8 = 0
    private let state: EditorState
    private let onApply: () -> Void
    private let onCancel: () -> Void

    init(state: EditorState, onApply: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.state = state
        self.onApply = onApply
        self.onCancel = onCancel
    }

    @objc func toggled(_ sw: NSSwitch) {
        let on = sw.state == .on
        // ⌘Z step: checkpoint BEFORE any mutation — including the first
        // enable, whose auto-run Apply used to checkpoint AFTER the flag was
        // already flipped (undo then "restored" an on-state: the reported
        // no-op). A failed/cancelled enhance discards the step (controller).
        let firstEnable = on && state.enhancedImage == nil
        state.recordUndoCheckpoint(
            action: firstEnable ? "Enhance" : (on ? "Show Enhanced" : "Show Original"))
        state.showingEnhanced = on
        if on && state.enhancedImage == nil {
            // No enhanced image yet — auto-run Apply so the user doesn't have
            // to hit Apply manually after enabling for the first time.
            onApply()
        } else if !on {
            // Cancel any in-flight enhance run when the user turns the switch off.
            onCancel()
        }
        state.markDirty()
    }
}

/// Handles the Upscale `NSSegmentedControl` in the Enhance panel.
/// Writes the chosen scale into `state.enhanceDraft.upscale`.
@MainActor
private final class EnhanceUpscaleHandler: NSObject {
    static var assocKey: UInt8 = 0
    private let state: EditorState
    private let order: [EnhanceParams.Upscale]

    init(state: EditorState, order: [EnhanceParams.Upscale]) {
        self.state = state
        self.order = order
    }

    @objc func changed(_ seg: NSSegmentedControl) {
        let idx = seg.selectedSegment
        guard order.indices.contains(idx) else { return }
        state.enhanceDraft.upscale = order[idx]
    }
}

/// Forwards the Apply button's tap to the `onApply` closure wired by the
/// sidebar's `onEnhanceApply` → `EditorController.runEnhanceApply()`.
@MainActor
private final class EnhanceApplyHandler: NSObject {
    static var assocKey: UInt8 = 0
    private let state: EditorState
    private let onApply: () -> Void

    init(state: EditorState, onApply: @escaping () -> Void) {
        self.state = state
        self.onApply = onApply
    }

    @objc func fire() {
        // ⌘Z step recorded at the GESTURE (pre-mutation); a failed/cancelled
        // run discards it (controller).
        state.recordUndoCheckpoint(action: "Enhance")
        onApply()
    }
}
