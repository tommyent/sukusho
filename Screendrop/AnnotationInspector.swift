//
//  AnnotationInspector.swift
//  Screendrop
//

import AppKit
import SwiftUI

// MARK: - Inspector

enum AnnotationEditorFocusedField: Hashable {
    case watermarkText
}

struct AnnotationEditorInspector: View {
    @Bindable var model: AnnotationEditorModel
    @Bindable var wallpaperStore: AnnotationWallpaperStore
    @Bindable var backgroundPresetStore: AnnotationBackgroundPresetStore
    let focusedField: FocusState<AnnotationEditorFocusedField?>.Binding
    let onEditorAction: () -> Void
    let onPickWallpaper: () -> Void
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(PixelProbe.self) private var probe: PixelProbe?
    @FloatingGlassChrome private var floatingChrome

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // One slot for the tool's options, under its name, pinned above the
            // scrolling sections and the same height for every tool, so it never
            // scrolls away and nothing below it moves (Fable #1).
            InspectorSection(toolSlot.heading) {
                VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
                    if toolSlot == .crop {
                        AnnotationCropControls(model: model, onEditorAction: onEditorAction)
                            .help(toolSlot.line)
                    }
                    if showsStyleControls {
                        styleControls
                    }
                    if showsSlotLine {
                        Text(toolSlot.line)
                            .font(.inspectorLabel)
                            .foregroundStyle(InspectorControlPalette.label)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(
                    maxWidth: .infinity,
                    minHeight: InspectorMetrics.toolOptionsHeight,
                    alignment: .topLeading
                )
            }

            // While cropping, Crop's options are all there is to set.
            if !model.isCropping {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        AnnotationStyleStrip(
                            model: model,
                            presetStore: backgroundPresetStore,
                            onEditorAction: onEditorAction
                        )

                        InspectorSection(
                            "Background",
                            accessory: {
                                if !usesDefaultPlacement {
                                    InspectorResetButton(help: "Reset padding and alignment") {
                                        onEditorAction()
                                        withAnimation(sectionAnimation) {
                                            let defaults = AnnotationBackgroundSettings()
                                            model.backgroundSettings.padding = defaults.padding
                                            model.backgroundSettings.alignment = defaults.alignment
                                        }
                                    }
                                }
                                if model.backgroundSettings.style != .none {
                                    InspectorClearButton(help: "Remove background") {
                                        onEditorAction()
                                        model.backgroundSettings.style = .none
                                    }
                                }
                            }
                        ) {
                            AnnotationBackgroundInspector(
                                settings: backgroundBinding,
                                wallpaperStore: wallpaperStore,
                                onEditorAction: onEditorAction,
                                onPickWallpaper: onPickWallpaper,
                                onPreview: { model.previewBackground($0, isHovering: $1) },
                                onEndPreview: { model.previewBackground = nil },
                                onTurnCameraOff: {
                                    onEditorAction()
                                    withAnimation(sectionAnimation) { model.setCameraOn(false) }
                                }
                            )
                        }

                        // The screenshot's edge: corners, shadow and border all draw on it.
                        InspectorSection(
                            "Screenshot",
                            accessory: {
                                if !usesDefaultEdge {
                                    sectionResetButton("Reset corners, shadow and border") {
                                        let defaults = AnnotationBackgroundSettings()
                                        model.backgroundSettings.cornerRadius = defaults.cornerRadius
                                        model.backgroundSettings.shadow = defaults.shadow
                                        model.backgroundSettings.shadowStyle = defaults.shadowStyle
                                        model.backgroundSettings.border = AnnotationScreenshotBorderSettings(
                                            isEnabled: model.backgroundSettings.border.isEnabled
                                        )
                                    }
                                }
                            }
                        ) {
                            // Corners and shadow need a canvas; Border works without one.
                            if model.backgroundSettings.requiresCanvasLayout {
                                AnnotationScreenshotEdgeInspector(
                                    settings: backgroundBinding,
                                    onEditorAction: onEditorAction
                                )
                            }

                            InspectorToggleRow("Border", isOn: Binding(
                                get: { model.backgroundSettings.border.isEnabled },
                                set: { value in
                                    onEditorAction()
                                    withAnimation(sectionAnimation) {
                                        model.backgroundSettings.border.isEnabled = value
                                    }
                                }
                            ))

                            if model.backgroundSettings.border.isEnabled {
                                AnnotationScreenshotBorderInspector(
                                    settings: Binding(
                                        get: { model.backgroundSettings.border },
                                        set: { model.backgroundSettings.border = $0 }
                                    ),
                                    onEditorAction: onEditorAction
                                )
                                .transition(.opacity)
                            }
                        }

                        InspectorGroupBreak()

                        InspectorSection(
                            "Camera",
                            isOn: Binding(
                                get: { model.isCameraOn },
                                set: { value in
                                    onEditorAction()
                                    model.setCameraOn(value)
                                }
                            ),
                            toggleTitle: "Enable camera",
                            accessory: {
                                if model.isCameraOn, model.backgroundSettings.camera != .gentleTilt {
                                    sectionResetButton("Reset camera") {
                                        model.backgroundSettings.camera = .gentleTilt
                                    }
                                }
                            }
                        ) {
                            AnnotationCameraInspector(
                                settings: Binding(
                                    get: { model.backgroundSettings.camera },
                                    set: { model.backgroundSettings.camera = $0 }
                                ),
                                onEditorAction: onEditorAction
                            )
                        }

                        InspectorSection(
                            "Progressive Blur",
                            summary: AnnotationInspectorSummary.progressiveBlur(model.backgroundSettings.progressiveBlur),
                            isOn: featureBinding(\.progressiveBlur.isEnabled),
                            toggleTitle: "Enable progressive blur",
                            accessory: {
                                if model.backgroundSettings.progressiveBlur.isEnabled,
                                   model.backgroundSettings.progressiveBlur != AnnotationProgressiveBlurSettings(isEnabled: true) {
                                    sectionResetButton("Reset progressive blur") {
                                        model.backgroundSettings.progressiveBlur = AnnotationProgressiveBlurSettings(isEnabled: true)
                                    }
                                }
                            }
                        ) {
                            AnnotationProgressiveBlurInspector(
                                settings: Binding(
                                    get: { model.backgroundSettings.progressiveBlur },
                                    set: { model.backgroundSettings.progressiveBlur = $0 }
                                ),
                                onEditorAction: onEditorAction
                            )
                        }

                        InspectorSection(
                            "Watermark",
                            summary: AnnotationInspectorSummary.watermark(model.backgroundSettings.watermark),
                            isOn: featureBinding(\.watermark.isEnabled),
                            toggleTitle: "Enable watermark",
                            accessory: {
                                if model.backgroundSettings.watermark.isEnabled,
                                   model.backgroundSettings.watermark != AnnotationWatermarkSettings(isEnabled: true) {
                                    sectionResetButton("Reset watermark") {
                                        model.backgroundSettings.watermark = AnnotationWatermarkSettings(isEnabled: true)
                                    }
                                }
                            }
                        ) {
                            AnnotationWatermarkInspector(
                                settings: Binding(
                                    get: { model.backgroundSettings.watermark },
                                    set: { model.backgroundSettings.watermark = $0 }
                                ),
                                focusedField: focusedField,
                                onFocusCleared: onEditorAction
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    // The Revert To bar keeps clear of the floating preview peek pill
                    // itself; without the bar, the end of the list must.
                    .padding(.bottom, showsRevertBar ? 12 : PreviewPeekTab.pillHeight * 1.1)
                }
                .scrollContentBackground(.hidden)
                // A soft edge under the pinned slot shows there is more above.
                .scrollEdgeEffectStyle(.soft, for: .all)
            } else {
                Spacer(minLength: 0)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if showsRevertBar, !model.isCropping {
                InspectorRevertBar(background: sidebarBackground) {
                    AnnotationEditorRevertItems(editor: model)
                }
            }
        }
        .environment(\.annotationEditorHistory, model)
        .background(sidebarBackground)
        .inspectorColumnWidth(
            min: InspectorMetrics.columnMinWidth,
            ideal: InspectorMetrics.columnIdealWidth,
            max: InspectorMetrics.columnMaxWidth
        )
        .frame(
            minWidth: InspectorMetrics.columnMinWidth,
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .topLeading
        )
    }

    private var sidebarBackground: Color { floatingChrome ? .clear : WorkspaceChrome.background }

    /// Revert To applies to History captures, which keep their original.
    private var showsRevertBar: Bool {
        model.sourceURL.map(ScreenshotHistoryStore.shared.isHistoryURL) ?? false
    }

    private var backgroundBinding: Binding<AnnotationBackgroundSettings> {
        Binding(
            get: { model.backgroundSettings },
            set: { model.backgroundSettings = $0 }
        )
    }

    private var usesDefaultPlacement: Bool {
        let settings = model.backgroundSettings
        let defaults = AnnotationBackgroundSettings()
        return settings.padding == defaults.padding && settings.alignment == defaults.alignment
    }

    private var usesDefaultEdge: Bool {
        let settings = model.backgroundSettings
        let defaults = AnnotationBackgroundSettings()
        return settings.cornerRadius == defaults.cornerRadius
            && settings.shadow == defaults.shadow
            && settings.shadowStyle == defaults.shadowStyle
            && settings.border == AnnotationScreenshotBorderSettings(isEnabled: settings.border.isEnabled)
    }

    private var sectionAnimation: Animation? {
        accessibilityReduceMotion ? nil : .morph
    }

    /// A feature switch in a section header. The section folds with it.
    private func featureBinding(
        _ keyPath: WritableKeyPath<AnnotationBackgroundSettings, Bool>
    ) -> Binding<Bool> {
        Binding(
            get: { model.backgroundSettings[keyPath: keyPath] },
            set: { value in
                onEditorAction()
                model.backgroundSettings[keyPath: keyPath] = value
            }
        )
    }

    /// Restores a section's defaults without switching it off.
    private func sectionResetButton(_ help: String, reset: @escaping () -> Void) -> some View {
        InspectorResetButton(help: help) {
            onEditorAction()
            withAnimation(sectionAnimation) { reset() }
        }
        .transition(.blurPop)
    }

    // MARK: Tools & style

    private func smartRedactionRow(tool: AnnotationTool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            InspectorActionButton(
                "Find sensitive text…",
                systemImage: "text.viewfinder",
                isBusy: model.isSmartRedacting
            ) {
                onEditorAction()
                model.smartRedact(using: tool)
            }
            .help("Find sensitive text and \(tool == .blur ? "blur" : "pixelate") it")

            // The button shows the scan in progress; the slot has room for two rows.
            if !model.isSmartRedacting, let message = model.smartRedactionMessage {
                Text(message)
                    .font(.inspectorLabel)
                    .foregroundStyle(InspectorControlPalette.label)
            }
        }
    }

    private var toolSlot: AnnotationToolSlot {
        .current(
            tool: model.inspectedTool,
            selectionCount: model.selectionCount,
            isCropping: model.isCropping,
            isPickingColor: probe?.isPicking == true,
            isMeasuring: probe?.isMeasuringTool == true
        )
    }

    /// A mode (Crop, Pick Color, Measure) has the slot to itself.
    private var showsStyleControls: Bool {
        switch toolSlot {
        case .tool, .annotations: model.hasInspectorStyleControls
        case .crop, .pickColor, .measure: false
        }
    }

    /// The help line fills the slot's free row: always for Pick Color, Measure or a tool with no
    /// options, and under the one row of Hand-drawn or the magnifier's Zoom. Crop's controls fill it.
    private var showsSlotLine: Bool {
        if toolSlot == .crop { return false }
        guard showsStyleControls else { return true }
        guard case .tool(let tool) = toolSlot else { return false }
        return [.line, .arrow, .magnifier].contains(tool)
    }

    @ViewBuilder
    private var styleControls: some View {
        if model.hasInspectorStyleControls {
            if model.isTextStyleAvailable {
                AnnotationTextStyleControls(model: model)
            } else {
                if model.inspectedTool == .magnifier {
                    // The shapes drawn, not named, so they fit beside Zoom.
                    HStack(spacing: InspectorMetrics.rowSpacing) {
                        InspectorSlider("Zoom", value: Binding(
                            get: { model.magnifierZoom },
                            set: { onEditorAction(); model.setMagnifierZoom($0) }
                        ), range: 1...8, format: .magnification(fractionDigits: 1))

                        InspectorSegmented(
                            options: MagnifierShape.allCases,
                            isSelected: { $0 == model.magnifierShape },
                            onTap: {
                                onEditorAction()
                                model.setMagnifierShape($0)
                            },
                            label: { MagnifierShapeIcon(shape: $0) },
                            height: InspectorMetrics.controlHeight,
                            name: { $0.label }
                        )
                        .frame(width: InspectorMetrics.controlHeight * 3 + InspectorMetrics.controlInset * 2)
                    }
                }
                if model.isFillStyleAvailable {
                    InspectorRow("Fill") {
                        InspectorSegmented(
                            options: AnnoFillStyle.allCases,
                            isSelected: { $0 == model.geoFill },
                            onTap: {
                                onEditorAction()
                                model.setGeoFill($0)
                            },
                            label: { Text($0.label) },
                            height: InspectorMetrics.controlHeight
                        )
                    }
                }

                // Colour and width live in the tool dock's colour pill.

                if model.isHandDrawnStyleAvailable {
                    InspectorToggleRow("Hand-drawn", isOn: Binding(
                        get: { model.handDrawn },
                        set: { onEditorAction(); model.setHandDrawn($0) }
                    ))
                }

                if model.isRedactionStyleAvailable {
                    InspectorSlider(
                        "Strength",
                        value: Binding(
                            get: { model.redactionDensity },
                            set: {
                                onEditorAction()
                                model.setRedactionDensity($0)
                            }
                        ),
                        range: 0.15...1,
                        format: .percent()
                    )
                    if let tool = model.inspectedTool, tool.isRedactionTool {
                        smartRedactionRow(tool: tool)
                    }
                }
            }
        }
    }
}

/// Crop's options in the tool slot (Fable #5): the aspect ratio and Reset, then Cancel and Crop.
/// Return and Escape do the same from the keyboard (`AnnotationKeyCommandHandler`).
private struct AnnotationCropControls: View {
    let model: AnnotationEditorModel
    let onEditorAction: () -> Void

    var body: some View {
        VStack(spacing: InspectorMetrics.rowSpacing) {
            HStack(spacing: 6) {
                Menu {
                    Picker("Aspect Ratio", selection: Binding(
                        get: { model.cropAspect },
                        set: { aspect in
                            onEditorAction()
                            withAnimation(.snappy(duration: 0.18)) { model.setCropAspect(aspect) }
                        }
                    )) {
                        ForEach(CropAspectRatio.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "aspectratio")
                            .font(.system(size: 11, weight: .medium))
                        Text(model.cropAspect.title)
                            .font(.inspectorValue)
                            .lineLimit(1)
                            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .foregroundStyle(.primary.opacity(0.85))
                    .padding(.horizontal, InspectorMetrics.fieldInset)
                    .inspectorField()
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .help("Aspect ratio")

                InspectorActionButton("Reset", systemImage: "arrow.counterclockwise") {
                    onEditorAction()
                    withAnimation(.snappy(duration: 0.18)) { model.resetCrop() }
                }
                .help("Reset the selection to the whole image")
            }

            HStack(spacing: 6) {
                InspectorActionButton("Cancel", systemImage: "xmark") {
                    onEditorAction()
                    withAnimation(.snappy(duration: 0.22)) { model.cancelCrop() }
                }
                .help("Leave Crop without cropping (Escape)")

                Button {
                    onEditorAction()
                    withAnimation(.snappy(duration: 0.22)) { model.applyCrop() }
                } label: {
                    Label("Crop", systemImage: "crop")
                        .font(.inspectorValue.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: InspectorMetrics.controlHeight)
                        .background(Capsule().fill(Color.accentColor))
                        .foregroundStyle(.white)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Crop to the selection (Return)")
            }
        }
    }
}

/// A magnifier shape drawn as a small outline, in the segment's own colour so it
/// follows the selected and hover states.
private struct MagnifierShapeIcon: View {
    let shape: MagnifierShape

    var body: some View {
        switch shape {
        case .roundedSquare:
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(lineWidth: 1.5)
                .frame(width: 14, height: 14)
        case .circle:
            Circle()
                .strokeBorder(lineWidth: 1.5)
                .frame(width: 14, height: 14)
        case .rectangle:
            Rectangle()
                .strokeBorder(lineWidth: 1.5)
                .frame(width: 16, height: 11)
        }
    }
}

// MARK: - Section summaries

/// One-line readouts for collapsed section headers. `nil` means the section
/// has nothing active worth announcing.
private enum AnnotationInspectorSummary {
    static func progressiveBlur(_ settings: AnnotationProgressiveBlurSettings) -> String? {
        guard settings.isEnabled else { return nil }
        return "\(settings.mode.title) · \(Int(settings.strength.rounded()))"
    }

    static func watermark(_ settings: AnnotationWatermarkSettings) -> String? {
        let text = settings.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard settings.isEnabled, !text.isEmpty else { return nil }
        return "“\(text)”"
    }
}
