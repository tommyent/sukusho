//
//  RecordingStudioInspector.swift
//  Screendrop
//
//  The Recording Studio trailing inspector and its helper controls.
//

import AppKit
import SwiftUI
import Translation
import UniformTypeIdentifiers

// MARK: - Inspector

extension ZoomAnchorMode {
    var inspectorTitle: String {
        switch self {
        case .pointerAnchor: "Pointer"
        case .smartAnchor: "Smart"
        case .pinnedAnchor: "Fixed"
        }
    }
}

private enum StudioTranscriptTab: CaseIterable, Identifiable {
    case captions
    case edit

    var id: Self { self }

    var title: String {
        switch self {
        case .captions: "Captions"
        case .edit: "Edit Video"
        }
    }
}

private enum StudioInspectorContent: Hashable {
    case main
    case audio(UUID)
}

struct StudioInspector: View {
    /// Whole-number playback rates offered for a clip, within
    /// `RecordingClipSegment`'s 1...8 range.
    private static let clipSpeedPresets: [Double] = [1, 2, 3, 4, 6, 8]

    @Bindable var model: RecordingStudioModel
    @State private var wallpaperStore = AnnotationWallpaperStore.shared
    @State private var stylePresetStore = RecordingStudioStylePresetStore.shared
    @State private var transcriptTab: StudioTranscriptTab = .captions
    /// The translated captions the list shows; nil for the original.
    @State private var captionLanguage: String?
    @State private var isTranslationPickerPresented = false
    @State private var isAudioExportOptionsPresented = false
    @State private var isMusicPickerPresented = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FloatingGlassChrome private var floatingChrome

    private var inspectorContent: StudioInspectorContent {
        if let clip = model.selectedAudioClip { return .audio(clip.id) }
        return .main
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                switch inspectorContent {
                case .audio:
                    if let clip = model.selectedAudioClip {
                        selectedAudioPage(for: clip)
                    }
                case .main:
                    mainInspectorSections
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            // The Revert To bar keeps clear of the preview peek pill itself;
            // without the bar (a plain movie), the end of the list must.
            .padding(.top, floatingChrome ? -6 : 0)
            .padding(.bottom, model.isProject ? 12 : PreviewPeekTab.pillHeight * 1.1)
            }
            .id(inspectorContent)
            .scrollContentBackground(.hidden)
            .scrollEdgeEffectStyle(.soft, for: .all)
            .clipped()

            VStack(spacing: 0) {
                Rectangle()
                    .fill(Palette.hairline)
                    .frame(height: 0.5)
                    .accessibilityHidden(true)

                Group {
                    if model.isExportingAgentPrompt, case .exporting(let progress) = model.exportState {
                        HStack(spacing: 6) {
                            StudioProgressRing(progress: progress, size: 12, tint: CardMark.green)
                            Text("Exporting Bug Report \(Int((progress * 100).rounded()))%")
                                .font(.inspectorValue.monospacedDigit())
                                .contentTransition(.numericText())
                        }
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .inspectorField()
                        .foregroundStyle(Color.primary.opacity(0.85))
                    } else if model.showsAgentPromptSaved {
                        HStack(spacing: 6) {
                            BouncingCheck()
                                .font(.system(size: 12, weight: .semibold))
                            Text("Prompt Copied")
                                .font(.inspectorValue)
                        }
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .inspectorField()
                        .foregroundStyle(CardMark.green)
                        .transition(.opacity)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Bug Reports & Guides")
                                .font(.inspectorSectionHeader)
                                .foregroundStyle(InspectorControlPalette.label)
                            InspectorActionButton("Bug Report", systemImage: "ladybug") {
                                model.exportAgentPrompt()
                            }
                            .help("Copies a prompt for your coding agent and shows the bug report to send to a person in Finder.")
                            if model.session != nil {
                                InspectorActionButton("How-To Guide", systemImage: "list.number", isBusy: model.isExportingGuide) {
                                    model.exportGuide()
                                }
                                .help("Saves a step-by-step guide to your export folder, copies it as Markdown and shows it in Finder.")
                            }
                        }
                        .disabled(!model.isLoaded || model.hasRunningWork || model.hasUnreadableDraft || model.transcriptionState.isTranscribing)
                    }
                }
                .motion(.fade, value: model.showsAgentPromptSaved)
                .padding(.horizontal, InspectorMetrics.horizontalPadding)
                .padding(.vertical, 10)

                if model.isProject {
                    InspectorRevertBar(background: sidebarBackground) {
                        RecordingStudioRevertItems(studio: model)
                    }
                    .disabled(!model.canRevert)
                }
            }
        }
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
        .task {
            await wallpaperStore.reload()
        }
    }

    // MARK: Main inspector & audio clip page

    @ViewBuilder
    private var mainInspectorSections: some View {
        // Timeline selections edit at the top, where attention lands
        // after clicking a zoom or clip, instead of pushing the
        // sections below around mid-panel.
        if let selected = model.selectedCue {
            InspectorSection(
                title: "Selected Zoom",
                accessory: {
                    InspectorToggle(
                        "Use this zoom",
                        isOn: Binding(
                            get: { selected.isEnabled },
                            set: { isEnabled in
                                var updated = selected
                                updated.isEnabled = isEnabled
                                model.updateZoomCue(updated)
                            }
                        )
                    )
                }
            ) {
                if model.zoomEnabled {
                    selectedZoomControls(for: selected)
                } else {
                    InspectorHint("Zooms are off. Turn on Zoom & Clicks to change this one.")
                }
            }
            InspectorSectionDivider()
        } else if let selectedClip = model.selectedClip {
            InspectorSection("Selected Clip") {
                selectedClipControls(for: selectedClip)
            }
            InspectorSectionDivider()
        }

        // The look, as the image editor lays it out: Styles, then
        // Background (upstream v0.35's Canvas and Frame).
        RecordingStudioStyleStrip(model: model, presetStore: stylePresetStore)

        InspectorSection(
            "Background",
            accessory: {
                if model.style.background != .none {
                    InspectorClearButton(help: "Remove background") {
                        model.style.background = .none
                    }
                }
            }
        ) {
            backgroundControls
        }

        // The video's own edge, a heading of its own as the image editor's Screenshot is.
        InspectorSection(
            "Video",
            accessory: {
                if !usesDefaultLayout {
                    InspectorResetButton(help: "Reset padding, corners and shadow") {
                        model.style.padding = 0.06
                        model.style.cornerRadius = 0.02
                        model.style.shadow = 0.45
                    }
                }
            }
        ) {
            videoControls
        }

        InspectorGroupBreak()

        // As in the image editor: a section that can be off has a switch and shows its
        // options while on; the rest are always open. No chevrons (Fable pass 3, #4).
        InspectorSection("Redactions") {
            RecordingRedactionControls(model: model)
        }

        InspectorSection("Zoom & Clicks", isOn: $model.zoomEnabled, toggleTitle: "Enable zooms") {
            zoomControls
        }

        if model.pointerIsSynthesized {
            InspectorSection(
                "Cursor",
                isOn: Binding(
                    get: { !model.style.hidesCursor },
                    set: { model.style.hidesCursor = !$0 }
                ),
                toggleTitle: "Show mouse pointer",
                accessory: {
                    if !model.style.hidesCursor,
                       model.style.cursorScale != RecordingStudioStyle.defaultCursorScale {
                        InspectorResetButton(help: "Reset cursor size") {
                            model.style.cursorScale = RecordingStudioStyle.defaultCursorScale
                        }
                    }
                }
            ) {
                cursorControls
            }
        }

        if model.hasKeystrokes {
            InspectorSection("Keystrokes", isOn: $model.showsKeystrokes, toggleTitle: "Show keystrokes") {
                keystrokeControls
            }
        }

        if model.hasInk {
            InspectorSection("Drawings", isOn: $model.showsInk, toggleTitle: "Show drawings") {
                inkControls
            }
        }

        if model.canTranscribe || model.hasSubtitles {
            // A switch once there are subtitles to show; until then the section holds
            // what makes them.
            InspectorSection(
                "Transcription",
                isOn: model.hasSubtitles && !model.transcriptionState.isTranscribing
                    ? $model.showsSubtitles : nil,
                toggleTitle: "Show subtitles",
                accessory: {
                    if model.transcriptionState.isTranscribing {
                        ProgressView()
                            .controlSize(.mini)
                            .frame(width: 24, height: 24)
                    }
                }
            ) {
                transcriptionControls
            }
        }

        if model.isProject {
            InspectorSection("Chapters") {
                chapterControls
            }
        }

        if model.hasCameraVideo {
            InspectorSection("Camera", isOn: $model.style.camera.isVisible, toggleTitle: "Show camera") {
                cameraControls
            }
        }

        InspectorSection(
            "Audio",
            accessory: {
                if model.hasReplacementAudio {
                    if model.hasRecordedAudio {
                        InspectorResetButton(help: "Use the recorded audio again") {
                            model.removeReplacementAudio()
                        }
                    } else {
                        InspectorClearButton(help: "Remove this audio") {
                            model.removeReplacementAudio()
                        }
                    }
                }
            }
        ) {
            audioControls
        }
    }

    private func selectedAudioPage(for clip: RecordingAudioClip) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Button {
                        model.selectedAudioClipID = nil
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 10.5, weight: .semibold))
                            Text("Inspector")
                                .font(.inspectorLabel)
                        }
                        .foregroundStyle(Palette.secondaryLabel)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Back to Inspector")

                    Spacer(minLength: 0)

                    if model.selectedAudioClipIDs.count > 1 {
                        Text("\(model.selectedAudioClipIDs.count) selected")
                            .font(.inspectorLabel.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        model.removeAudioClip(id: clip.id)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Remove Audio")
                    .accessibilityLabel("Remove Audio")
                }

                HStack(spacing: 6) {
                    Image(systemName: clip.source == .file ? "music.note" : "waveform")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(nsColor: .systemIndigo))
                    Text(clip.displayName)
                        .font(.inspectorSectionHeader)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.horizontal, InspectorMetrics.horizontalPadding)
            .padding(.top, 10)
            .padding(.bottom, 10)

            InspectorSectionDivider()

            StudioAudioClipInspectorControls(model: model, clip: clip)
                .padding(.horizontal, InspectorMetrics.horizontalPadding)
                .padding(.vertical, 12)
        }
    }

    // MARK: Background

    /// The fill as one row whose picker previews a fill on the video while
    /// the pointer rests on it, then the canvas shape.
    private var backgroundControls: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            InspectorBackgroundRow(
                style: $model.style.background,
                wallpaperStore: wallpaperStore,
                onPickWallpaper: pickWallpaper,
                onPreview: { model.previewBackground($0, isHovering: $1) },
                onEndPreview: { model.previewBackground = nil }
            )

            InspectorSegmented(
                options: ExportAspectPreset.allCases,
                isSelected: { $0 == model.exportAspect },
                onTap: { aspect in
                    withAnimation(.canvasMoveIfAllowed) { model.exportAspect = aspect }
                },
                label: { preset in
                    Text(preset.title)
                        .font(.inspectorSegment)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .help(preset.help)
                }
            )

            if model.exportAspect != .original {
                InspectorSegmented(
                    options: ExportAspectContentMode.allCases,
                    isSelected: { $0 == model.exportAspectMode },
                    onTap: { mode in
                        withAnimation(.canvasMoveIfAllowed) { model.exportAspectMode = mode }
                    },
                    label: { mode in
                        Text(mode.title)
                            .font(.inspectorSegment)
                            .help(mode.help)
                    }
                )
            }

        }
    }

    /// Padding, corners and shadow shape the video on the background.
    private var videoControls: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            InspectorFieldPair {
                InspectorSlider(
                    "Padding",
                    value: $model.style.padding,
                    range: 0...0.18,
                    format: .percent()
                )
            } trailing: {
                InspectorSlider(
                    "Corners",
                    value: $model.style.cornerRadius,
                    range: 0...0.08,
                    format: .percent()
                )
            }
            // Without a background the video fills the canvas, as a screenshot with none does.
            .disabled(model.style.background == .none)
            .opacity(model.style.background == .none ? 0.4 : 1)

            // The shadow falls on the background; with none there is nothing for it to fall
            // on, and neither preview nor export draws one.
            if model.style.background == .none {
                InspectorHint("Choose a background to add a shadow.")
            } else {
                InspectorSlider(
                    "Shadow",
                    value: $model.style.shadow,
                    range: 0...1,
                    format: .percent()
                )
            }
        }
    }

    private func pickWallpaper() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = AnnotationWallpaperStore.supportedContentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.title = "Choose Video Background Wallpaper"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                let file: URL
                if let imported = try? await wallpaperStore.importWallpaper(from: url) {
                    file = imported
                } else {
                    wallpaperStore.addRecentWallpaper(url)
                    file = url
                }
                model.style.background = .customWallpaper(AnnotationCustomWallpaper(url: file))
            }
        }
    }

    // MARK: Zoom

    private var zoomControls: some View {
        let pressCount = model.recordedPressTimes.count
        return VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            HStack(spacing: InspectorMetrics.rowSpacing) {
                InspectorActionButton("Auto Zoom", systemImage: "pointer.arrow.rays") {
                    model.resynthesizeZoomCues()
                }
                .disabled(pressCount == 0)
                .help(
                    pressCount == 0
                        ? "No clicks were recorded"
                        : "Turn the \(pressCount == 1 ? "recorded click" : "\(pressCount) recorded clicks") into smooth camera moves"
                )

                InspectorActionButton("Add Zoom", systemImage: "plus.magnifyingglass") {
                    model.addZoomCue(at: model.currentTime)
                }
                .help("Add a zoom at the playhead, or drag across the zoom lane")
            }

            if model.zoomCues.isEmpty {
                InspectorHint(
                    pressCount > 0
                        ? "Auto Zoom turns your recorded clicks into camera moves."
                        : "Drag across the zoom lane on the timeline to add a zoom."
                )
            }
        }
    }

    private func selectedZoomControls(for selected: ZoomCue) -> some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            VStack(alignment: .leading, spacing: InspectorMetrics.groupLabelSpacing) {
                InspectorGroupLabel("Camera focus")

                InspectorSegmented(
                    options: ZoomAnchorMode.allCases,
                    isSelected: { $0 == selected.anchorMode },
                    onTap: { anchorMode in
                        var updated = selected
                        updated.anchorMode = anchorMode
                        if anchorMode == .pinnedAnchor,
                           let pointer = model.pointerLocation(at: model.currentTime) {
                            updated.pinnedPoint = pointer
                        }
                        model.updateZoomCue(updated)
                    },
                    label: { Text($0.inspectorTitle).font(.inspectorSegment) }
                )
            }

            if selected.anchorMode == .pinnedAnchor {
                zoomAmountSlider(for: selected)

                VStack(alignment: .leading, spacing: InspectorMetrics.groupLabelSpacing) {
                    HStack(spacing: 8) {
                        InspectorGroupLabel("Target position")
                        Spacer(minLength: 0)
                        Text(zoomTargetPositionText(selected.pinnedPoint))
                            .font(.inspectorNumeric)
                            .foregroundStyle(.tertiary)
                    }

                    RecordingZoomFocusPad(
                        position: Binding(
                            get: { selected.pinnedPoint },
                            set: { target in
                                var updated = selected
                                updated.pinnedPoint = target
                                model.updateZoomCue(updated)
                            }
                        ),
                        magnification: selected.zoom
                    )
                }
            } else {
                InspectorFieldPair {
                    zoomAmountSlider(for: selected)
                } trailing: {
                    InspectorSlider(
                        "Edge",
                        value: Binding(
                            get: { CGFloat(selected.boundsBias) },
                            set: { boundsBias in
                                var updated = selected
                                updated.boundsBias = Double(boundsBias)
                                model.updateZoomCue(updated)
                            }
                        ),
                        range: 0...1,
                        format: .percent()
                    )
                    .help("How much of the frame's edge stays in view while zoomed")
                }
            }

            HStack(spacing: InspectorMetrics.rowSpacing) {
                if selected.anchorMode == .pinnedAnchor {
                    InspectorActionButton("Target Pointer", systemImage: "scope") {
                        guard let pointer = model.pointerLocation(at: model.currentTime) else { return }
                        var updated = selected
                        updated.pinnedPoint = pointer
                        model.updateZoomCue(updated)
                    }
                    .help("Aim the zoom at the pointer's position under the playhead")
                }

                InspectorActionButton("Remove", systemImage: "trash", role: .destructive) {
                    model.removeZoomCue(id: selected.id)
                }
                .help("Remove the selected zoom")
            }
        }
    }

    private func zoomAmountSlider(for selected: ZoomCue) -> some View {
        InspectorSlider(
            "Zoom",
            value: Binding(
                get: { CGFloat(selected.zoom) },
                set: { newValue in
                    var updated = selected
                    updated.zoom = Double(newValue)
                    model.updateZoomCue(updated)
                }
            ),
            range: 1.1...3,
            format: .magnification(fractionDigits: 1)
        )
    }

    private func zoomTargetPositionText(_ position: CGPoint) -> String {
        let x = Int((position.x * 100).rounded())
        let y = Int((position.y * 100).rounded())
        return "\(x), \(y)"
    }

    // MARK: Selected clip

    private func selectedClipControls(for clip: RecordingClipSegment) -> some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            VStack(alignment: .leading, spacing: InspectorMetrics.groupLabelSpacing) {
                InspectorGroupLabel("Speed")

                InspectorSegmented(
                    options: Self.clipSpeedPresets,
                    isSelected: { abs($0 - clip.speed) < 0.001 },
                    onTap: { model.setClipSpeed($0, forClipID: clip.id) },
                    label: { speed in
                        Text(InspectorValueFormat.magnification(fractionDigits: 0).displayString(for: speed))
                            .font(.inspectorSegment)
                    }
                )
                .help("Audio speeds up with the clip")
            }

            if model.hasRecordedAudio || model.replacementAudio != nil {
                InspectorFieldPair {
                    InspectorSlider(
                        "Volume",
                        value: Binding(
                            get: { CGFloat(clip.volume) },
                            set: { model.setClipVolume(Double($0), forClipID: clip.id) }
                        ),
                        range: CGFloat(RecordingClipSegment.volumeRange.lowerBound)...CGFloat(RecordingClipSegment.volumeRange.upperBound),
                        format: .percent()
                    )
                    .disabled(clip.isMuted)
                } trailing: {
                    InspectorActionButton(
                        clip.isMuted ? "Unmute" : "Mute",
                        systemImage: clip.isMuted ? "speaker.slash.fill" : "speaker.wave.2"
                    ) {
                        model.toggleClipMuted(id: clip.id)
                    }
                    .help("Silence this clip's own sound")
                }

                if model.canDetachAudio(fromClipID: clip.id) {
                    InspectorActionButton("Detach Audio", systemImage: "waveform.badge.minus") {
                        model.detachAudio(fromClipID: clip.id)
                    }
                    .help("Move this clip's sound onto an audio lane")
                }
            }

            if model.canDeleteSelectedClip {
                InspectorActionButton("Delete Clip", systemImage: "trash", role: .destructive) {
                    model.deleteSelectedClip()
                }
                .help("Remove this part of the video")
            }
        }
    }

    // MARK: Cursor

    private var cursorControls: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            InspectorSlider(
                "Size",
                value: $model.style.cursorScale,
                range: 1...4,
                format: .magnification(fractionDigits: 1)
            )

            if model.canShowPressEffects {
                InspectorToggleRow("Click highlights", isOn: $model.showsClickEffects)
            }
        }
    }

    // MARK: Keystrokes

    private var keystrokeControls: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            InspectorRow("Top") {
                keystrokePlacementRow([.topLeft, .topCenter, .topRight])
            }
            InspectorRow("Bottom") {
                keystrokePlacementRow([.bottomLeft, .bottomCenter, .bottomRight])
            }
        }
        .help("Shortcuts you pressed while recording appear as a caption")
    }

    private var inkControls: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            ForEach(model.inkStrokes) { stroke in
                let number = model.inkStrokeNumber(stroke.id)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Button {
                        model.jumpToInkStroke(stroke)
                    } label: {
                        HStack {
                            Text("Drawing \(number)")
                            Spacer()
                            if let time = model.editorTime(forSourceTime: stroke.startTime) {
                                Text(studioTimecode(time))
                                    .monospacedDigit()
                            } else {
                                Text("Cut")
                            }
                            if stroke.id == model.selectedInkStrokeID { Image(systemName: "checkmark") }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Jump to drawing \(number)")
                    Button("Delete drawing", systemImage: "trash", role: .destructive) {
                        model.deleteInkStroke(stroke.id)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .accessibilityLabel("Delete drawing \(number)")
                }
                .font(.inspectorValue)
            }
            InspectorHint("Drawn with the pen while recording. A deleted drawing leaves the preview and exports; Undo brings it back.")
        }
        .disabled(model.hasRunningWork)
    }

    private func keystrokePlacementRow(
        _ options: [RecordingKeystrokePlacement]
    ) -> some View {
        InspectorSegmented(
            options: options,
            isSelected: { $0 == model.keystrokePlacement },
            onTap: { model.keystrokePlacement = $0 },
            label: { Text($0.title).font(.inspectorSegment) }
        )
    }

    private var chapterControls: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            InspectorActionButton("Add at Playhead", systemImage: "plus") {
                model.addChapterAtPlayhead()
            }
            if model.hasSubtitles {
                InspectorActionButton("Suggest Chapters", systemImage: "list.bullet") {
                    model.suggestChapters()
                }
                .help("Suggest breaks at narration pauses")

                if !model.visibleChapters.isEmpty {
                    if let reason = model.textModelUnavailableReason {
                        InspectorHint(reason)
                    } else {
                        InspectorActionButton("Name Chapters", systemImage: "sparkles", isBusy: model.isNamingChapters) {
                            model.nameChapters()
                        }
                        .help("Apple Intelligence titles each chapter from its narration, on this Mac")
                    }
                }
            } else {
                InspectorHint("Transcribe the narration to suggest and name chapters.")
            }

            InspectorHint("Chapters save immediately. Undo restores changes.")
            if let error = model.chapterError {
                InspectorHint(error, tint: .orange)
            }
            ForEach(model.visibleChapters) { chapter in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Button {
                        model.jumpToChapter(chapter)
                    } label: {
                        Text(studioTimecode(chapter.start))
                            .monospacedDigit()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Jump to \(chapter.title)")
                    StudioChapterNameField(model: model, chapter: chapter)
                    Button("Remove chapter", systemImage: "trash", role: .destructive) {
                        model.removeChapter(id: chapter.id)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(chapter.title)")
                }
                .font(.inspectorValue)
            }
            if !model.openingSentenceTitle.isEmpty {
                InspectorActionButton("Use Opening Sentence as Title", systemImage: "textformat") {
                    model.rename(to: model.openingSentenceTitle)
                }
            }
        }
    }

    // MARK: Transcription

    @ViewBuilder
    private var transcriptionControls: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            switch model.transcriptionState {
            case .transcribing:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    InspectorHint("Transcribing narration…")
                }
            case .failed(let message):
                InspectorHint(message, tint: .orange)

                InspectorActionButton("Try Again", systemImage: "waveform") {
                    model.transcribe()
                }
            case .idle:
                if model.hasSubtitles {
                    subtitleEditor
                    transcriptionActions
                    if model.isProject {
                        summaryControls
                    }
                } else {
                    InspectorActionButton("Transcribe Narration", systemImage: "waveform") {
                        model.transcribe()
                    }
                    .help("Turn your microphone narration into subtitles, transcribed on this Mac")
                }
            }
        }
    }

    private var transcriptionActions: some View {
        HStack(spacing: InspectorMetrics.rowSpacing) {
            if model.canTranscribe {
                InspectorActionButton("Transcribe Again", systemImage: "arrow.clockwise") {
                    model.transcribe()
                }
            }

            InspectorActionButton("Remove", systemImage: "trash", role: .destructive) {
                model.removeTranscription()
            }
            .help("Remove the subtitles")
        }
    }

    private var subtitleEditor: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            InspectorSegmented(
                options: StudioTranscriptTab.allCases,
                isSelected: { $0 == transcriptTab },
                onTap: { transcriptTab = $0 },
                label: { tab in
                    Text(tab.title)
                        .font(.inspectorSegment)
                        .lineLimit(1)
                }
            )

            switch transcriptTab {
            case .captions:
                captionControls
                if model.isProject {
                    translationControls
                }
            case .edit:
                transcriptEditControls
            }
        }
    }

    private var captionControls: some View {
        let verticalRange = SubtitleBarStyle.verticalRange
        let fontScaleRange = SubtitleBarStyle.fontScaleRange
        return VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            InspectorFieldPair {
                InspectorSlider(
                    "Position",
                    value: Binding(
                        get: { CGFloat(model.subtitleStyle.verticalPosition) },
                        set: { model.subtitleStyle.verticalPosition = Double($0) }
                    ),
                    range: CGFloat(verticalRange.lowerBound)...CGFloat(verticalRange.upperBound),
                    format: .percent()
                )
            } trailing: {
                InspectorSlider(
                    "Size",
                    value: Binding(
                        get: { CGFloat(model.subtitleStyle.fontScale) },
                        set: { model.subtitleStyle.fontScale = Double($0) }
                    ),
                    range: CGFloat(fontScaleRange.lowerBound)...CGFloat(fontScaleRange.upperBound),
                    format: .magnification(fractionDigits: 1)
                )
            }

            if model.hasTranscriptWords {
                InspectorToggleRow(
                    "Highlight spoken word",
                    isOn: $model.subtitleStyle.highlightsSpokenWord
                )
            }

            if let track = shownTranslation {
                translatedCueList(track)
                    .help("Click a timestamp to jump there. Edit any line to fix the translation.")
            } else {
                subtitleList
                    .help("Click a timestamp to jump there. Edit any line to fix the transcription.")
            }
        }
        .disabled(!model.showsSubtitles)
        .opacity(model.showsSubtitles ? 1 : 0.48)
    }

    // MARK: Summary and translations

    private var summaryControls: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.groupLabelSpacing) {
            InspectorGroupLabel("Summary")
            if let summary = model.summary {
                StudioSummaryField(model: model, summary: summary)
                HStack(spacing: InspectorMetrics.rowSpacing) {
                    if model.textModelUnavailableReason == nil {
                        InspectorActionButton("Summarize Again", systemImage: "sparkles", isBusy: model.isSummarizing) {
                            model.summarize()
                        }
                    }
                    InspectorActionButton("Remove", systemImage: "trash", role: .destructive) {
                        model.setSummary(nil)
                    }
                    .help("Remove the summary")
                }
            } else if model.textModelUnavailableReason == nil {
                InspectorActionButton("Summarize", systemImage: "sparkles", isBusy: model.isSummarizing) {
                    model.summarize()
                }
                .help("Apple Intelligence writes a short summary from the narration, on this Mac. The share page shows it.")
            }
            if let reason = model.textModelUnavailableReason {
                InspectorHint(reason)
            } else if let note = model.summaryNote {
                InspectorHint(note, tint: .orange)
            }
        }
    }

    /// The translation the caption list shows, or nil for the original.
    private var shownTranslation: RecordingCaptionTrack? {
        captionLanguage.flatMap { lang in model.captionTracks.first { $0.lang == lang } }
    }

    private var translationControls: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            if !model.captionTracks.isEmpty {
                InspectorRow("Showing") {
                    HStack(spacing: 8) {
                        Picker("Showing", selection: $captionLanguage) {
                            Text("Original").tag(String?.none)
                            ForEach(model.captionTracks) { track in
                                Text(track.label).tag(Optional(track.lang))
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        // Beside its menu, apart from the transcription's own Remove below.
                        if let track = shownTranslation {
                            Button("Remove the \(track.label) captions", systemImage: "trash", role: .destructive) {
                                captionLanguage = nil
                                model.removeCaptionTrack(lang: track.lang)
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.red.opacity(0.88))
                            .help("Remove the \(track.label) captions")
                        }
                    }
                }
            }
            Group {
                if model.isTranslating {
                    InspectorActionButton("Stop Translating", systemImage: "stop.circle") {
                        model.cancelTranslation()
                    }
                } else {
                    InspectorActionButton("Translate Captions…", systemImage: "translate") {
                        isTranslationPickerPresented = true
                    }
                    .help("Translate the captions on this Mac, keeping their times. The share page offers each language.")
                }
            }
            .popover(isPresented: $isTranslationPickerPresented, arrowEdge: .leading) {
                StudioTranslationPicker(model: model) { isTranslationPickerPresented = false }
            }
            if model.isTranslating {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    InspectorHint("Translating captions…")
                }
            }
            if let note = model.translationNote {
                InspectorHint(note, tint: .orange)
            }
        }
    }

    private func translatedCueList(_ track: RecordingCaptionTrack) -> some View {
        let shape = RoundedRectangle(cornerRadius: InspectorMetrics.listRadius, style: .continuous)
        return ScrollView(.vertical) {
            VStack(spacing: 0) {
                ForEach(Array(track.cues.enumerated()), id: \.element.id) { index, cue in
                    StudioTranslatedCueRow(model: model, lang: track.lang, cue: cue)
                    if index < track.cues.count - 1 {
                        Divider()
                            .padding(.leading, 10)
                            .opacity(0.6)
                    }
                }
            }
        }
        .frame(maxHeight: 300)
        .background(shape.fill(InspectorControlPalette.trackFill(for: colorScheme)))
        .clipShape(shape)
    }

    @ViewBuilder
    private var transcriptEditControls: some View {
        if model.hasTranscriptWords {
            StudioTranscriptEditPanel(model: model)

            StudioCleanupControls(model: model)

            InspectorHint("Click a word to jump there. Shift-click to select a passage, then cut it.")
        } else {
            InspectorHint("This transcription predates editing by text. Transcribe again to cut the video from its transcript.")
        }
    }

    private var subtitleList: some View {
        let shape = RoundedRectangle(cornerRadius: InspectorMetrics.listRadius, style: .continuous)
        return ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    let cues = model.subtitleCues
                    ForEach(Array(cues.enumerated()), id: \.element.id) { index, cue in
                        StudioSubtitleRow(
                            model: model,
                            cue: cue,
                            isActive: model.activeSubtitleCueID == cue.id
                        )
                        .id(cue.id)

                        if index < cues.count - 1 {
                            Divider()
                                .padding(.leading, 10)
                                .opacity(0.6)
                        }
                    }
                }
            }
            .frame(maxHeight: 300)
            .background(shape.fill(InspectorControlPalette.trackFill(for: colorScheme)))
            .clipShape(shape)
            .onChange(of: model.activeSubtitleCueID) { _, activeID in
                // Follow playback through the list, but never yank the list
                // around while the user is scrubbing or editing.
                guard let activeID, model.isPlaying else { return }
                withAnimation(reduceMotion ? nil : .fade) {
                    proxy.scrollTo(activeID, anchor: .center)
                }
            }
        }
    }

    // MARK: Camera

    private var cameraControls: some View {
        InspectorFieldPair {
            InspectorSlider(
                "Size",
                value: $model.style.camera.size,
                range: 0.12...0.45,
                format: .percent()
            )
        } trailing: {
            InspectorSlider(
                "Rounding",
                value: $model.style.camera.roundness,
                range: 0.05...0.5,
                format: .percent()
            )
        }
        .help("Drag the camera directly on the canvas to place it")
    }

    // MARK: Audio

    /// The round trip around tools that clean up speech but offer no API:
    /// write the cut's soundtrack out, run it through the tool, bring the
    /// result back in as the project's audio. Two buttons and a file chip -
    /// the explaining is left to tooltips.
    private var audioControls: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            // The soundtrack in use comes first: the levels and actions below act on it.
            if let replacement = model.replacementAudio {
                replacementChip(for: replacement)
            }

            // A silent recording has nothing to send out, but it can still
            // be given a soundtrack - so only the export half is withheld.
            if model.replacementAudio != nil {
                InspectorFieldPair {
                    InspectorSlider("Volume", value: $model.audioVolume, range: 0...2, format: .percent())
                } trailing: {
                    StudioSoundtrackSyncSlider(model: model)
                }
            } else if model.hasRecordedAudio {
                InspectorSlider("Volume", value: $model.audioVolume, range: 0...2, format: .percent())
            }

            if model.canIsolateVoice {
                if model.hasReplacementAudio {
                    InspectorHint("Reset to recorded audio to use voice isolation.")
                } else {
                    InspectorToggleRow("Isolate voice", isOn: $model.isolateVoice)
                        .help("Reduce background noise in the source microphone track")
                    if let progress = model.voiceIsolationProgress {
                        ProgressView("Isolating voice…", value: progress)
                    }
                }
            }
            if let message = model.voiceIsolationError {
                InspectorHint(message, tint: .orange)
            }

            HStack(spacing: InspectorMetrics.rowSpacing) {
                if model.hasAudio {
                    audioExportButton
                }

                InspectorActionButton(
                    model.hasRecordedAudio ? "Replace" : "Add",
                    systemImage: "waveform.badge.plus"
                ) {
                    pickReplacementAudio()
                }
                .help(
                    model.hasRecordedAudio
                        ? "Swap in an audio file for the video's sound, lined up with the cut as it stands"
                        : "Lay an audio file over this silent recording"
                )
            }

            if model.replacementAudio != nil, model.replacementAudioDrift != nil {
                InspectorHint("It was made for a different cut. Export the audio again after your edits for a full-length replacement.")
            }

            if !model.audioClipsPastEnd.isEmpty {
                HStack(spacing: InspectorMetrics.rowSpacing) {
                    InspectorHint(
                        model.audioClipsPastEnd.count == 1
                            ? "1 audio clip starts after the video ends."
                            : "\(model.audioClipsPastEnd.count) audio clips start after the video ends.",
                        tint: .orange
                    )
                    InspectorActionButton("Remove", systemImage: "trash") {
                        model.removeAudioClipsPastEnd()
                    }
                }
            }

            if let message = model.replacementAudioError {
                InspectorHint(message, tint: .orange)
            }

            StudioBackgroundMusicControls(model: model) { isMusicPickerPresented = true }
                .sheet(isPresented: $isMusicPickerPresented) {
                    FreeToUseMusicPicker(setBackgroundMusic: model.setBackgroundMusic)
                }
        }
        .disabled(model.isRestoringDocument)
    }

    /// One button carrying the whole export state, so progress and results
    /// never cost the section an extra row. The format is asked for at export
    /// time, the same way video export asks for its options.
    @ViewBuilder
    private var audioExportButton: some View {
        switch model.audioExportState {
        case .idle:
            InspectorActionButton("Export…", systemImage: "arrow.down.circle") {
                isAudioExportOptionsPresented = true
            }
            .help("Export just the soundtrack of the current cut")
            .disabled(model.isIsolatingVoice || model.hasUnreadableDraft)
            .popover(isPresented: $isAudioExportOptionsPresented, arrowEdge: .bottom) {
                StudioAudioExportOptions(
                    format: $model.audioExportFormat,
                    includesAddedAudio: model.audioClips.isEmpty ? nil : $model.audioExportIncludesClips
                ) {
                    isAudioExportOptionsPresented = false
                    model.exportAudio()
                }
            }
        case .exporting(let progress):
            audioExportChrome(help: "Cancel") {
                model.cancelAudioExport()
            } label: {
                StudioProgressRing(progress: progress, size: 12)
                Text("\(Int((progress * 100).rounded()))%")
                    .font(.inspectorValue.monospacedDigit())
                    .contentTransition(.numericText())
            }
        case .finished(let url):
            audioExportChrome(help: "Reveal \(url.lastPathComponent) in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.green)
                Text("Reveal")
                    .font(.inspectorValue)
            }
        case .failed(let message):
            audioExportChrome(help: message) {
                model.exportAudio()
            } label: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.orange)
                Text("Retry")
                    .font(.inspectorValue)
            }
        }
    }

    /// Matches `InspectorActionButton`'s chrome for the export button's
    /// non-idle states, which carry richer content than a symbol and a title.
    private func audioExportChrome<Label: View>(
        help: String,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                label()
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .inspectorField()
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func replacementChip(for replacement: RecordingReplacementAudio) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "waveform")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.accentColor)

            Text(replacement.displayName)
                .font(.inspectorValue)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 4)

            if let drift = model.replacementAudioDrift {
                Image(systemName: "info.circle")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .help(
                        drift > 0
                            ? "Runs \(Self.spanText(drift)) longer than the cut - the tail is dropped"
                            : "Runs \(Self.spanText(-drift)) shorter than the cut - the end plays silent"
                    )
            }

            Text(studioClock(replacement.duration))
                .font(.inspectorLabel.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .inspectorField()
        .help(replacement.displayName)
    }

    private func pickReplacementAudio() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = RecordingAudioFormat.importContentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.title = "Choose Replacement Audio"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            model.replaceAudio(with: url)
        }
    }

    /// Short spans read better in seconds than as 0:00 timecode.
    private static func spanText(_ seconds: TimeInterval) -> String {
        let value = max(0, seconds)
        return value < 60 ? String(format: "%.1fs", value) : studioClock(value)
    }

    // MARK: Helpers

    private var usesDefaultLayout: Bool {
        abs(model.style.padding - 0.06) < 0.0001
            && abs(model.style.cornerRadius - 0.02) < 0.0001
            && abs(model.style.shadow - 0.45) < 0.0001
    }

    private var sidebarBackground: Color {
        floatingChrome ? .clear : InspectorControlPalette.panelBackground(for: colorScheme)
    }
}

/// Asks for the soundtrack format at export time.
private struct StudioAudioExportOptions: View {
    @Binding var format: RecordingAudioFormat
    var includesAddedAudio: Binding<Bool>? = nil
    let onExport: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            Text("Export Audio")
                .font(.inspectorSectionHeader)
                .padding(.bottom, 2)

            InspectorSegmented(
                options: RecordingAudioFormat.allCases,
                isSelected: { $0 == format },
                onTap: { format = $0 },
                label: { Text($0.title).font(.inspectorSegment) }
            )

            InspectorHint(
                format == .m4a
                    ? "Compact AAC audio, accepted by most enhancement tools."
                    : "Uncompressed, for tools that accept nothing else."
            )

            if let includesAddedAudio {
                InspectorToggleRow("Include audio clips", isOn: includesAddedAudio)
                    .help("Mix audio lane clips into the exported file")
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Export", action: onExport)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
            .padding(.top, 4)
        }
        .padding(InspectorMetrics.horizontalPadding)
        .frame(width: 240)
        .presentationBackground(InspectorControlPalette.panelBackground(for: colorScheme))
    }
}

// MARK: - Inspector Helpers

struct StudioChapterNameDraft {
    var text: String?

    mutating func storedTitleChanged() {
        text = nil
    }

    mutating func commit(model: RecordingStudioModel, chapter: RecordingChapter) {
        guard let text else { return }
        if text != chapter.title { model.renameChapter(id: chapter.id, title: text) }
        model.finishChapterRename()
        if model.chapterError == nil { self.text = nil }
    }
}

/// A chapter's name. It saves a moment after typing stops (clicking the
/// video doesn't end editing, and a quit would lose the rename) and when
/// editing ends, as one undo step.
private struct StudioChapterNameField: View {
    let model: RecordingStudioModel
    let chapter: RecordingChapter
    @State private var draft = StudioChapterNameDraft()
    @State private var pendingSave: Task<Void, Never>?
    @FocusState private var isEditing: Bool

    var body: some View {
        TextField("Chapter name", text: Binding(
            get: { draft.text ?? chapter.title },
            set: { draft.text = $0 }
        ))
        .textFieldStyle(.plain)
        .focused($isEditing)
        .onSubmit(commit)
        .onChange(of: isEditing) { _, editing in
            if !editing { commit() }
        }
        .onChange(of: draft.text) { _, text in
            pendingSave?.cancel()
            guard let text else { return }
            pendingSave = Task {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, text != chapter.title else { return }
                model.renameChapter(id: chapter.id, title: text)
            }
        }
        // A saved title never replaces the text being typed.
        .onChange(of: chapter.title) {
            if !isEditing { draft.storedTitleChanged() }
        }
    }

    private func commit() {
        pendingSave?.cancel()
        draft.commit(model: model, chapter: chapter)
    }
}

/// The recording's summary, edited in place. It saves a moment after typing
/// stops (clicking the video doesn't end editing) and when editing ends;
/// clearing it removes it once editing ends.
private struct StudioSummaryField: View {
    let model: RecordingStudioModel
    let summary: String
    @State private var draft: String?
    @State private var pendingSave: Task<Void, Never>?
    @FocusState private var isEditing: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        TextField("Summary", text: Binding(get: { draft ?? summary }, set: { draft = $0 }), axis: .vertical)
            .textFieldStyle(.plain)
            .font(.inspectorValue)
            .lineLimit(3...12)
            .focused($isEditing)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: InspectorMetrics.listRadius, style: .continuous)
                .fill(InspectorControlPalette.trackFill(for: colorScheme)))
            .onSubmit(commit)
            .onChange(of: isEditing) { _, editing in
                if !editing { commit() }
            }
            .onChange(of: draft) { _, text in
                pendingSave?.cancel()
                // An empty field only deletes the summary once editing ends.
                guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                pendingSave = Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled else { return }
                    model.setSummary(text)
                }
            }
            // A new summary from the model replaces what's shown, but never the text being typed.
            .onChange(of: summary) { if !isEditing { draft = nil } }
            .accessibilityLabel("Summary")
    }

    private func commit() {
        pendingSave?.cancel()
        guard let draft else { return }
        model.setSummary(draft)
        self.draft = nil
    }
}

/// One translated line: its timestamp and text, edited like the original's.
/// It saves a moment after typing stops and when editing ends.
private struct StudioTranslatedCueRow: View {
    let model: RecordingStudioModel
    let lang: String
    let cue: RecordingSubtitleCue
    @State private var draft: String?
    @State private var pendingSave: Task<Void, Never>?
    @FocusState private var isEditing: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button {
                model.seekToSubtitle(cue)
            } label: {
                Text(timestamp ?? "–:––")
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(editorTime == nil)

            TextField("Translation", text: Binding(get: { draft ?? cue.text }, set: { draft = $0 }), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.inspectorValue)
                .focused($isEditing)
                .onSubmit(commit)
                .onChange(of: isEditing) { _, editing in
                    if editing { model.seekToSubtitle(cue) } else { commit() }
                }
                .onChange(of: draft) { _, text in
                    pendingSave?.cancel()
                    guard let text else { return }
                    pendingSave = Task {
                        try? await Task.sleep(for: .milliseconds(500))
                        guard !Task.isCancelled else { return }
                        model.updateTranslatedCue(lang: lang, id: cue.id, text: text)
                    }
                }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .opacity(editorTime == nil ? 0.5 : 1)
    }

    private func commit() {
        pendingSave?.cancel()
        guard let draft else { return }
        model.updateTranslatedCue(lang: lang, id: cue.id, text: draft)
        self.draft = nil
    }

    private var editorTime: TimeInterval? {
        model.editorTime(forSourceTime: cue.start) ?? model.editorTime(forSourceTime: (cue.start + cue.end) / 2)
    }

    private var timestamp: String? {
        editorTime.map(studioTimecode)
    }
}

/// Translate Captions…: the languages Translation offers from the captions' own.
private struct StudioTranslationPicker: View {
    let model: RecordingStudioModel
    let done: () -> Void
    @State private var languages: [Locale.Language]?
    @State private var chosen: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Translate Captions")
                .font(.headline)
            Text("Translated on this Mac, keeping each caption’s time. macOS may ask to download a language first.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let languages {
                List(languages, id: \.minimalIdentifier) { language in
                    let tag = RecordingCaptionTranslation.tag(language)
                    Toggle(Self.name(language), isOn: Binding(
                        get: { chosen.contains(tag) },
                        set: { if $0 { chosen.insert(tag) } else { chosen.remove(tag) } }
                    ))
                    .disabled(!chosen.contains(tag) && !model.captionTracks.contains { $0.lang == tag } && isFull)
                }
                .frame(height: 260)
                if isFull {
                    Text("Up to \(RecordingCaptionTranslation.maximumTracks) languages; remove one to add another.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 60)
            }
            HStack {
                Spacer()
                Button("Cancel", action: done)
                    .keyboardShortcut(.cancelAction)
                Button("Translate") {
                    model.translateCaptions(to: (languages ?? []).filter { chosen.contains(RecordingCaptionTranslation.tag($0)) })
                    done()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 300)
        .task {
            let source = model.captionSourceLanguage
            let availability = LanguageAvailability()
            var offered: [Locale.Language] = []
            for language in await availability.supportedLanguages where language.languageCode != source?.languageCode {
                if let source, await availability.status(from: source, to: language) == .unsupported { continue }
                offered.append(language)
            }
            languages = offered.sorted { Self.name($0).localizedStandardCompare(Self.name($1)) == .orderedAscending }
        }
    }

    /// Existing tracks a new choice would join (re-translating one replaces it).
    private var isFull: Bool {
        chosen.union(model.captionTracks.map(\.lang)).count >= RecordingCaptionTranslation.maximumTracks
    }

    private static func name(_ language: Locale.Language) -> String {
        let tag = RecordingCaptionTranslation.tag(language)
        return Locale.current.localizedString(forIdentifier: tag) ?? tag
    }
}

/// One editable subtitle line: a timestamp plus the cue text as a free-form
/// field. Hovering a row skims the preview to that cue, clicking or editing
/// commits the playhead there (paused), and the row under the playhead is
/// highlighted so the list follows the video.
private struct StudioSubtitleRow: View {
    @Bindable var model: RecordingStudioModel
    let cue: RecordingSubtitleCue
    let isActive: Bool

    @FocusState private var isEditing: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button {
                model.seekToSubtitle(cue)
            } label: {
                Text(timestamp ?? "–:––")
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(editorTime == nil)
            .help(editorTime == nil ? "This subtitle's audio was cut out" : "Jump to this subtitle")

            TextField(
                "Subtitle",
                text: Binding(
                    get: { cue.text },
                    set: { model.updateSubtitleText(id: cue.id, text: $0) }
                ),
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(.inspectorValue)
            .focused($isEditing)
            .onChange(of: isEditing) { _, editing in
                // Starting to edit parks the paused preview on this cue so
                // the correction is visible in context while typing.
                if editing {
                    model.seekToSubtitle(cue)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(isActive ? Color.accentColor.opacity(0.14) : .clear)
        .contentShape(Rectangle())
        .opacity(editorTime == nil ? 0.5 : 1)
        .onTapGesture {
            model.seekToSubtitle(cue)
        }
        .onHover { hovering in
            // Hover skims the paused preview like the timeline strip does;
            // leaving hands the frame back to the real playhead.
            guard !model.isPlaying, let editorTime else { return }
            if hovering {
                model.hoverPreviewTime = editorTime
            } else if model.hoverPreviewTime == editorTime {
                model.hoverPreviewTime = nil
            }
        }
    }

    /// Where this cue lands on the edited timeline; nil when its audio was
    /// cut out entirely.
    private var editorTime: TimeInterval? {
        model.editorTime(forSourceTime: cue.start)
            ?? model.editorTime(forSourceTime: (cue.start + cue.end) / 2)
    }

    private var timestamp: String? {
        editorTime.map(studioTimecode)
    }
}

/// Descript-style transcript editing: the narration as flowing words.
/// Clicking a word jumps the playhead there, shift-clicking selects a
/// passage, and cutting the selection removes that stretch of the video.
/// Words whose footage is already cut render struck-through; filler words
/// carry a dotted underline so the bulk action's targets are visible.
private struct StudioTranscriptEditPanel: View {
    @Bindable var model: RecordingStudioModel

    @State private var selection: ClosedRange<Int>?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    transcriptFlow
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(maxHeight: 260)
                .background(
                    RoundedRectangle(cornerRadius: InspectorMetrics.listRadius, style: .continuous)
                        .fill(InspectorControlPalette.trackFill(for: colorScheme))
                )
                .clipShape(RoundedRectangle(cornerRadius: InspectorMetrics.listRadius, style: .continuous))
                .onChange(of: model.activeTranscriptWordIndex) { _, activeIndex in
                    // Follow playback through the transcript, but never yank
                    // it around while the user is selecting a passage.
                    guard let activeIndex, model.isPlaying, selection == nil else { return }
                    withAnimation(reduceMotion ? nil : .fade) {
                        proxy.scrollTo(activeIndex, anchor: .center)
                    }
                }
            }

            if let selection {
                cutSelectionRow(selection)
            }
        }
        .onDeleteCommand(perform: cutSelection)
        .onExitCommand { selection = nil }
    }

    private var transcriptFlow: some View {
        let activeIndex = model.activeTranscriptWordIndex
        return TranscriptFlowLayout() {
            ForEach(model.transcriptWords.indices, id: \.self) { index in
                StudioTranscriptWordView(
                    text: model.transcriptWords[index].displayText,
                    isSelected: selection?.contains(index) ?? false,
                    isActive: index == activeIndex,
                    isCut: !model.transcriptWordSurvives(index),
                    isFiller: model.isFillerWord(index),
                    previewsCut: model.previewsFillerWords
                ) {
                    handleTap(on: index)
                }
                .id(index)
            }
        }
    }

    private func cutSelectionRow(_ selection: ClosedRange<Int>) -> some View {
        HStack(spacing: 6) {
            InspectorActionButton(
                selection.count == 1 ? "Cut Word" : "Cut \(selection.count) Words",
                systemImage: "scissors",
                role: .destructive,
                action: cutSelection
            )

            InspectorClearButton(help: "Clear selection") {
                self.selection = nil
            }
        }
    }

    private func handleTap(on index: Int) {
        let shiftHeld = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
        if shiftHeld, let selection {
            self.selection = min(selection.lowerBound, index)...max(selection.upperBound, index)
        } else {
            selection = index...index
            model.seekToTranscriptWord(at: index)
        }
    }

    private func cutSelection() {
        guard let selection else { return }
        model.cutTranscriptWords(in: selection)
        self.selection = nil
    }
}

/// One word in the transcript editor, drawn so the flow reads as a plain
/// paragraph: the chip's side padding doubles as the inter-word space
/// (layout spacing is zero), which also makes a multi-word selection's
/// highlight contiguous like real text selection. The font weight never
/// changes with state - a width change would reflow the whole paragraph
/// on every playback tick. Kept to plain stored values so ticks only
/// re-render the words whose state actually changed.
private struct StudioTranscriptWordView: View {
    let text: String
    let isSelected: Bool
    let isActive: Bool
    let isCut: Bool
    let isFiller: Bool
    /// Remove Filler Words' preview: fillers show as they'd look once cut.
    var previewsCut = false
    let action: () -> Void

    private var isPreviewedCut: Bool { previewsCut && isFiller && !isCut }

    var body: some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(foreground)
            .strikethrough(isCut || isPreviewedCut, color: isPreviewedCut ? .orange : .secondary.opacity(0.6))
            .padding(.horizontal, 1.5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(background)
            )
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
    }

    private var foreground: Color {
        isCut ? Color.secondary.opacity(0.45) : Color.primary
    }

    private var background: Color {
        if isSelected {
            Color.accentColor.opacity(isCut ? 0.12 : 0.24)
        } else if isActive, !isCut {
            Color.accentColor.opacity(0.2)
        } else if isFiller, !isCut {
            Color.orange.opacity(isPreviewedCut ? 0.32 : 0.16)
        } else {
            Color.clear
        }
    }
}

/// Minimal left-aligned wrapping layout for the transcript's word chips.
/// Horizontal spacing lives inside the chips (see StudioTranscriptWordView),
/// so the layout only separates lines.
private struct TranscriptFlowLayout: Layout {
    var spacingX: CGFloat = 0
    var spacingY: CGFloat = 3

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 240
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacingY
                rowHeight = 0
            }
            x += size.width + spacingX
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacingY
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacingX
            rowHeight = max(rowHeight, size.height)
        }
    }
}

