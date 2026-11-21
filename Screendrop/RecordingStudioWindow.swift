//
//  RecordingStudioWindow.swift
//  Screendrop
//
//  The recording studio: a Screen Studio-style editor for screen recordings.
//  Left/center is the composited live preview (background, padded rounded
//  card, zoom-follow-pointer, draggable camera bubble) over a timeline with
//  editable zoom cues; the trailing inspector uses the annotation
//  editor's design system.
//

import AppKit
import AVFoundation
import SwiftUI
import Translation
import UniformTypeIdentifiers

struct RecordingStudioWindow: View {
    @Binding var url: URL?

    @State private var model: RecordingStudioModel?

    var body: some View {
        Group {
            if let model {
                RecordingStudioContent(model: model)
            } else {
                ProgressView()
                    .frame(minWidth: 900, minHeight: 600)
            }
        }
        .modifier(CaptureLibraryEditorRegistration(url: url))
        .task(id: url) {
            guard let url else { return }
            model?.teardown()
            let newModel = RecordingStudioModel(url: url)
            model = newModel
            await newModel.load()
            guard !Task.isCancelled else {
                newModel.teardown()
                return
            }
            if model === newModel, newModel.isLoaded {
                ScreenshotPreviewStack.shared.dismissVideo(for: newModel.sessionURL)
            }
        }
        .onDisappear {
            model?.teardown()
            model = nil
        }
    }
}

private struct RecordingStudioContent: View {
    private static let minimumWidth: CGFloat = 980

    @Bindable var model: RecordingStudioModel
    @State private var isInspectorPresented = true
    @State private var closeGuard = EditorCloseGuard()
    @State private var confirmsSharedLinkDeletion = false
    @FloatingGlassChrome private var floatingChrome
    @State private var studioWindow: NSWindow?
    @State private var glassMetrics = GlassWindowButtonMetrics.fallback

    var body: some View {
        VStack(spacing: 0) {
            if let loadError = model.loadError {
                ContentUnavailableView(
                    "Couldn't open recording",
                    systemImage: "exclamationmark.triangle",
                    description: Text(loadError)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if model.hasUnreadableDraft {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("The latest edits couldn't be read, so Studio opened the last save. Export and upload stay off until you discard them.")
                        Button("Discard Unreadable Edits", role: .destructive) { model.discardUnreadableDraft() }
                    }
                    .font(.callout)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.12))
                }
                if model.needsSharedVideoReplacement {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("This recording is shared; the link still shows the unredacted version")
                        HStack {
                            Button("Delete link", role: .destructive) { confirmsSharedLinkDeletion = true }
                            Button("Replace shared video") { model.replaceSharedVideo() }
                        }
                        .disabled(!model.canManageSharedVideo)
                        if let error = model.sharedVideoError { Text(error).foregroundStyle(.orange) }
                    }
                    .font(.callout)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.12))
                }
                StudioCanvas(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background {
                        if !floatingChrome {
                            AnnotationEditorWorkspaceBackground()
                        }
                    }

                StudioTimelineEditor(model: model)
            }
        }
        .background {
            if floatingChrome {
                AnnotationEditorWorkspaceBackground()
                    .backgroundExtensionEffect()
                    .ignoresSafeArea()
            }
        }
        .frame(minWidth: Self.minimumWidth - InspectorMetrics.columnMinWidth, minHeight: 720)
        // One language at a time; the system asks first if it needs to download one.
        .translationTask(model.translationConfiguration) { session in
            await model.translate(using: session)
        }
        .confirmationDialog("Delete this shared link?", isPresented: $confirmsSharedLinkDeletion) {
            Button("Delete link", role: .destructive) { model.deleteSharedLink() }
        } message: {
            Text("The link and its cloud files will be deleted. The local recording stays in your Library.")
        }
        .toolbarBackgroundVisibility(floatingChrome ? .hidden : .visible, for: .windowToolbar)
        .toolbar(removing: .title)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                AnnotationEditorTitle(
                    title: windowTitle,
                    status: windowSubtitle,
                    customName: model.customName,
                    defaultName: model.modelTitle ?? model.defaultName,
                    // A bare movie has no project to keep a name in.
                    onRename: model.isProject ? { model.rename(to: $0) } : nil
                )
                .id(model.sessionURL)
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarSpacer(.flexible, placement: .primaryAction)
            ToolbarItemGroup(placement: .primaryAction) {
                if model.isSelectingRedaction {
                    Button("Cancel") { model.cancelRedaction() }
                    Button("Add Redaction") { model.addRedaction() }
                } else if model.isCroppingVideo {
                    videoCropActions
                } else {
                    if model.canShareToCloud {
                        shareStatus
                    }

                    exportStatus

                    if !floatingChrome || !isInspectorPresented {
                        inspectorToggleButton
                    }
                }
            }
            // Bare icons, as in the Library and the editor: no glass capsule.
            .sharedBackgroundVisibility(.hidden)
        }
        .inspector(isPresented: $isInspectorPresented) {
            StudioInspector(model: model)
                .glassInspectorToolbar(enabled: floatingChrome)
        }
        .frame(minWidth: Self.minimumWidth)
        .glassInspectorToggleOverlay(
            enabled: floatingChrome && isInspectorPresented && !model.isSelectingRedaction && !model.isCroppingVideo,
            isPresented: $isInspectorPresented,
            metrics: glassMetrics
        )
        .environment(\.backgroundDestination, .editors)
            .glassWindowChrome(
            window: studioWindow,
            hasSidebar: false,
            sidebarVisible: false,
            inspectorVisible: isInspectorPresented,
            metrics: $glassMetrics
        )
        .navigationTitle(windowTitle)
        .navigationSubtitle(windowSubtitle)
        .onWindowChange { window in
            studioWindow = window
            guard let window else {
                closeGuard.detach()
                return
            }
            configureCloseGuard()
            closeGuard.attach(to: window)
            // Left out of Sukusho's own screenshots like every other Sukusho window (Astra E2).
            PreviewWindowCaptureExclusion.shared.register(window: window)
        }
        // Saves on leaving the window or the app, as the image editor does.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignMainNotification)) { note in
            if let window = note.object as? NSWindow, window.delegate === closeGuard { model.autosave() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            model.autosave()
        }
        .focusedSceneValue(\.recordingStudio, model)
        .background {
            StudioKeyCommands(model: model)
        }
        .onDeleteCommand {
            if let selectedCueID = model.selectedCueID {
                model.removeZoomCue(id: selectedCueID)
            } else if model.selectedClipID != nil {
                model.deleteSelectedClip()
            }
        }
        .onAppear {
            AppActivationPolicy.enter(hidePreview: true)
        }
        .onDisappear {
            closeGuard.detach()
            AppActivationPolicy.leave(restorePreview: true)
        }
    }

    private var inspectorToggleButton: some View {
        Button {
            isInspectorPresented.toggle()
        } label: {
            Label(isInspectorPresented ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.right")
                .labelStyle(.iconOnly)
        }
        .help(isInspectorPresented ? "Hide Inspector" : "Show Inspector")
    }

    /// The name the recording's Library card shows; a bare movie's is its file name.
    /// The package name ("Sukusho_…") was suggested before.
    private var shareSuggestedTitle: String {
        model.session == nil ? model.projectDisplayName : windowTitle
    }

    /// Draft message writes from the summary and chapters as they stand.
    private var shareMessageSource: ShareMessageSource {
        ShareMessageSource(summary: model.summary, chapters: model.visibleChapters.map(\.title), isVideo: true)
    }

    @ViewBuilder
    private var videoCropActions: some View {
        Menu {
            Picker("Aspect Ratio", selection: videoCropAspectBinding) {
                ForEach(CropAspectRatio.allCases) { aspect in
                    Text(aspect.title).tag(aspect)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Label(model.videoCropAspect.title, systemImage: "aspectratio")
                .labelStyle(.titleAndIcon)
        }
        .help("Crop aspect ratio")

        Button("Reset") {
            withAnimation(.canvasMoveIfAllowed) {
                model.resetVideoCrop()
            }
        }
        .help("Reset the selection to the whole video")

        Button("Cancel") {
            withAnimation(.canvasMoveIfAllowed) {
                model.cancelVideoCrop()
            }
        }
        .keyboardShortcut(.cancelAction)

        Button("Crop") {
            withAnimation(.canvasMoveIfAllowed) {
                model.applyVideoCrop()
            }
        }
        .keyboardShortcut(.defaultAction)
    }

    private var videoCropAspectBinding: Binding<CropAspectRatio> {
        Binding(
            get: { model.videoCropAspect },
            set: { aspect in
                withAnimation(.canvasMoveIfAllowed) {
                    model.setVideoCropAspect(aspect)
                }
            }
        )
    }

    /// No "Edited" here and no close-button dot, as in the image editor: the
    /// subtitle says it, and with autosave Apple's HIG says a dot implies
    /// people must act to keep their work.
    private var windowTitle: String {
        // A rename in the Library reloads the project store; reading it here
        // re-reads the name then.
        _ = RecordingProjectStore.shared.projects
        // As on its Library card: yours, else Apple Intelligence's, else the date.
        return model.customName ?? model.modelTitle ?? model.defaultName
    }

    /// The save status, then the length of the edited cut and the source
    /// resolution.
    private var windowSubtitle: String {
        guard model.isLoaded else { return "" }
        let size = model.videoSize
        return [model.saveStatus, "\(studioClock(model.duration)) · \(Int(size.width)) × \(Int(size.height))"]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private func configureCloseGuard() {
        closeGuard.savesWithoutAsking = { [weak model] in model?.isProject ?? false }
        closeGuard.hasRunningWork = { [weak model] in model?.hasRunningWork ?? false }
        closeGuard.hasUnsavedChanges = { [weak model] in model?.hasUnsavedChanges ?? false }
        closeGuard.offersSave = { [weak model] in model?.isProject ?? true }
        closeGuard.projectName = { [weak model] in model?.projectDisplayName ?? "this recording" }
        closeGuard.onDecision = { [weak model] decision, done in
            guard let model else { return }
            switch decision {
            case .save:
                done(model.saveProject())
            case .discard:
                Task {
                    await model.discardChanges()
                    done(true)
                }
            case .cancel:
                break
            }
        }
    }

    /// Share pipeline in one toolbar slot: render → upload → link copied.
    /// The upload leg reads the uploader's live progress so the pill keeps
    /// moving through both stages.
    @ViewBuilder
    private var shareStatus: some View {
        switch model.shareState {
        case .idle:
            CloudUploadButton(suggestedTitle: shareSuggestedTitle, encryptionUnavailable: CloudShareSeal.unavailableNote,
                              messageSource: shareMessageSource, onUpload: { model.shareToCloud(options: $0) }) {
                Label("Upload", systemImage: "icloud.and.arrow.up")
                    .labelStyle(.titleAndIcon)
            }
            .disabled(!model.isLoaded || model.hasRunningWork || model.needsSharedVideoReplacement || model.hasUnreadableDraft)
            .help("Upload this recording and copy the share link")
        case .rendering(let progress):
            SharePill(stage: "Rendering", progress: progress) {
                model.cancelShare()
            }
        case .uploading:
            SharePill(
                stage: "Uploading",
                progress: model.shareItemID.flatMap {
                    CloudUploader.shared.uploadProgress[$0]
                } ?? 0
            ) {
                model.cancelShare()
            }
        case .finished(let url):
            // As in the image editor: Upload comes back with the next edit.
            Button {
                CloudShareLinks.copy([url])
            } label: {
                Label("Link Copied", systemImage: "checkmark.icloud")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.green)
            }
            .help("Copy the share link again")
        case .failed(let message):
            HStack(spacing: 6) {
                Label("Upload Failed", systemImage: "exclamationmark.triangle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.orange)
                    .help(message)

                CloudUploadButton(suggestedTitle: shareSuggestedTitle, encryptionUnavailable: CloudShareSeal.unavailableNote,
                                  messageSource: shareMessageSource, onUpload: { model.shareToCloud(options: $0) }) {
                    Text("Retry")
                }
                .disabled(model.hasRunningWork || model.needsSharedVideoReplacement)
            }
        }
    }

    @ViewBuilder
    private var exportStatus: some View {
        switch model.exportState {
        case .idle:
            RecordingExportButton(
                currentSettings: model.exportSettings,
                hasAudio: model.hasAudio,
                onExport: model.export(settings:)
            ) {
                Label("Export", systemImage: "arrow.down.circle")
                    .labelStyle(.titleAndIcon)
            }
            .disabled(!model.isLoaded || model.shareState.isBusy || model.isIsolatingVoice || model.hasUnreadableDraft)
        case .exporting(let progress):
            SharePill(stage: "Exporting", progress: progress, cancelLabel: "Cancel Export",
                      tint: model.isExportingAgentPrompt ? CardMark.green : .accentColor) {
                model.cancelExport()
            }
        case .finished(let url):
            HStack(spacing: 6) {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                .help("Reveal exported recording in Finder")

                RecordingExportButton(
                    currentSettings: model.exportSettings,
                    hasAudio: model.hasAudio,
                    onExport: model.export(settings:)
                ) {
                    Image(systemName: "arrow.down.circle")
                }
                .help("Export Again")
            }
        case .failed(let message):
            HStack(spacing: 6) {
                Label("Export Failed", systemImage: "exclamationmark.triangle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.orange)
                    .help(message)

                RecordingExportButton(
                    currentSettings: model.exportSettings,
                    hasAudio: model.hasAudio,
                    onExport: model.export(settings:)
                ) {
                    Text("Retry")
                }
            }
        }
    }
}

/// The determinate ring shared by every Studio progress affordance, so the
/// toolbar pills and the inspector's export button read as one control.
/// The Library's cards use it too.
struct StudioProgressRing: View {
    let progress: Double

    var size: CGFloat = 14
    /// Agent Prompt's rings are green; the others keep the accent colour.
    var tint: Color = .accentColor
    var lineWidth: CGFloat = 2

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.15), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.03, min(1, progress)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .motion(.fade, value: progress)
    }
}

/// A green tick that bounces once as it appears; with Reduce Motion it just appears.
private struct BouncingCheck: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bounces = 0

    var body: some View {
        Image(systemName: "checkmark.circle.fill")
            .symbolEffect(.bounce, value: bounces)
            .onAppear { if !reduceMotion { bounces += 1 } }
    }
}

/// Progress pill for the share pipeline: same ring treatment as the
/// export pill, with the stage name so render and upload read distinctly.
/// One pill for a running share or export: a ring showing percent complete,
/// the number itself, and a way to stop the work.
private struct SharePill: View {
    let stage: String
    let progress: Double
    var cancelLabel = "Cancel Upload"
    var tint: Color = .accentColor
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            StudioProgressRing(progress: progress, tint: tint)

            Text("\(stage) \(Int((progress * 100).rounded()))%")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.primary.opacity(0.85))
                .fixedSize()
                .contentTransition(.numericText())

            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(cancelLabel)
            .accessibilityLabel(cancelLabel)
        }
        .padding(.leading, 12)
    }
}

extension FocusedValues {
    /// The key Studio window's model, for menu commands.
    @Entry var recordingStudio: RecordingStudioModel?
}

/// File › Save for the key Studio window, disabled when clean. Only there
/// for a recording project while Studio is focused, as with the image
/// editor's Save. It is also a new recording's first save; after that the
/// project saves at a pause.
struct RecordingStudioSaveCommand: View {
    @FocusedValue(\.recordingStudio) private var studio

    var body: some View {
        if let studio, studio.isProject {
            Button("Save") { studio.saveProject() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!studio.hasUnsavedChanges)
        }
    }
}

struct RecordingStudioAgentPromptCommand: View {
    @FocusedValue(\.recordingStudio) private var studio

    var body: some View {
        if let studio {
            Group {
                Button("Export Bug Report") { studio.exportAgentPrompt() }
                if studio.session != nil {
                    Button("Export How-To Guide") { studio.exportGuide() }
                }
            }
            .disabled(!studio.isLoaded || studio.hasRunningWork || studio.hasUnreadableDraft || studio.transcriptionState.isTranscribing)
        }
    }
}

/// File › Revert To for the key Studio project. Each is one step Undo
/// takes back; the project then saves as after any edit.
struct RecordingStudioRevertCommand: View {
    @FocusedValue(\.recordingStudio) private var studio

    var body: some View {
        if let studio, studio.isProject {
            Menu("Revert To") {
                RecordingStudioRevertItems(studio: studio)
            }
            .disabled(!studio.canRevert)
        }
    }
}

// MARK: - Canvas

private struct StudioCanvas: View {
    @Bindable var model: RecordingStudioModel

    /// A play/pause glyph that blooms in the middle of the canvas after a
    /// click toggles playback, then fades.
    private struct PlaybackFlash: Equatable {
        let id = UUID()
        let systemImage: String
    }

    @State private var playbackFlash: PlaybackFlash?
    @Environment(\.colorScheme) private var colorScheme

    /// The Crop button's corner of the workspace: inset, button and a gap.
    private static let cropCorner: CGFloat = 12 + 34 + 6

    var body: some View {
        GeometryReader { proxy in
            // The picture keeps clear of the Crop button by giving up width
            // or height, whichever costs it less.
            let corner = Self.cropCorner * 2
            let canvasSize = [
                CGSize(width: proxy.size.width - corner, height: proxy.size.height - 56),
                CGSize(width: proxy.size.width - 68, height: proxy.size.height - corner),
            ]
            .map { Self.aspectFit(model.previewCanvasSize, into: CGSize(width: max($0.width, 100), height: max($0.height, 100))) }
            .max { $0.width < $1.width } ?? .zero
            let cropEditingLayout = RecordingStudioLayout.make(
                canvasSize: canvasSize,
                style: model.style,
                includeBubble: model.hasCameraVideo,
                usesUniformPadding: model.exportAspect == .original,
                contentAspect: model.sourceVideoAspect,
                contentMode: .fit
            )

            ZStack(alignment: .topLeading) {
                StudioCanvasComposition(
                    model: model,
                    canvasSize: canvasSize,
                    isEditingVideoCrop: model.isEditingSourceRegion
                )
                // Clicking the picture plays or pauses, like a player.
                // The camera bubble and zoom target keep their own drags.
                .contentShape(Rectangle())
                .gesture(
                    TapGesture().onEnded(togglePlayback),
                    including: model.isEditingSourceRegion ? .subviews : .all
                )

                if model.isEditingSourceRegion {
                    VideoCropOverlay(
                        model: model,
                        canvasSize: canvasSize,
                        videoFrame: cropEditingLayout.cardRect
                    )

                    CropResolutionBadge(size: model.videoCropPixelSize)
                        .padding(12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .allowsHitTesting(false)
                } else {
                    StudioCanvasSkimBadge(model: model)
                }

                if let notice = model.notice {
                    // What a key just did, when the change is hard to see.
                    StudioCanvasBadge(text: notice.text)
                        .padding(.top, 12)
                        .frame(width: canvasSize.width, alignment: .top)
                        .id(notice.id)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }

                if let playbackFlash {
                    StudioPlaybackFlashView(systemImage: playbackFlash.systemImage)
                        .frame(width: canvasSize.width, height: canvasSize.height)
                        .id(playbackFlash.id)
                        .allowsHitTesting(false)
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                }
            }
            .coordinateSpace(name: VideoCropOverlay.coordinateSpaceName)
            .frame(width: canvasSize.width, height: canvasSize.height)
            // Square like the exported video, lifted off the workspace by a
            // hairline and a soft shadow instead of a rounded mask that also
            // clipped the camera bubble.
            .clipped()
            .overlay {
                Rectangle()
                    .strokeBorder(canvasEdge, lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
            .background {
                Rectangle()
                    .fill(Color.black)
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.45 : 0.16), radius: 14, y: 5)
            }
            .motion(.fade, value: model.notice?.id)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        // Cropping swaps it for the crop actions in the toolbar.
        .overlay(alignment: .topTrailing) {
            if !model.isEditingSourceRegion {
                AnnotationDockButton(systemImage: "crop", title: "Crop", help: "Crop the finished video canvas") {
                    withAnimation(.canvasMoveIfAllowed) {
                        model.beginVideoCrop()
                    }
                }
                .glassEffect(.regular, in: .circle)
                .disabled(!model.isLoaded || model.exportState.isExporting)
                .padding(12)
            }
        }
    }

    private var canvasEdge: Color {
        colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.12)
    }

    private func togglePlayback() {
        guard model.isLoaded else { return }
        model.togglePlayback()
        let flash = PlaybackFlash(systemImage: model.isPlaying ? "play.fill" : "pause.fill")
        withAnimation(.hover) {
            playbackFlash = flash
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(520))
            guard playbackFlash == flash else { return }
            withAnimation(.fade) {
                playbackFlash = nil
            }
        }
    }

    private static func aspectFit(_ size: CGSize, into bounds: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
}

/// Shown over the canvas while the pointer skims away from the playhead.
/// Kept in its own view so hover moves redraw only this badge.
private struct StudioCanvasSkimBadge: View {
    let model: RecordingStudioModel

    private var skimTime: TimeInterval? {
        guard !model.isPlaying,
              let hover = model.hoverPreviewTime,
              abs(hover - model.currentTime) > 0.05 else { return nil }
        return hover
    }

    var body: some View {
        Group {
            if let skimTime {
                StudioCanvasBadge(text: "Previewing \(studioPreciseTimecode(skimTime))")
                    .padding(10)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .motion(.fade, value: skimTime == nil)
    }
}

/// Small dark capsule for transient canvas status.
private struct StudioCanvasBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.black.opacity(0.62)))
    }
}

private struct StudioPlaybackFlashView: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 22, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 60, height: 60)
            .background(Circle().fill(Color.black.opacity(0.5)))
    }
}

/// The complete canvas composition. A video crop changes only the screen card
/// layout and viewport; background, camera and captions remain in canvas space.
/// Original sizes that canvas to the visible source plus an equal border.
private struct StudioCanvasComposition: View {
    @Bindable var model: RecordingStudioModel
    let canvasSize: CGSize
    let isEditingVideoCrop: Bool

    var body: some View {
        let layout = RecordingStudioLayout.make(
            canvasSize: canvasSize,
            style: model.style,
            includeBubble: model.hasCameraVideo,
            usesUniformPadding: model.exportAspect == .original,
            contentAspect: isEditingVideoCrop ? model.sourceVideoAspect : model.previewContentAspect,
            contentMode: isEditingVideoCrop ? .fit : model.previewContentMode,
            contentCropRect: isEditingVideoCrop ? CropRectEditor.unit : model.videoCropRect
        )

        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !model.isPlaying)) { _ in
            let zoomTarget = zoomTargetCue
            // While a zoom's target is on show the frame stays unzoomed, so
            // the target reads against the whole picture.
            let state = isEditingVideoCrop || zoomTarget != nil
                ? ViewportFrame.identity
                : model.previewViewportFrame(at: model.displayTime)

            ZStack {
                StudioBackgroundView(style: model.previewBackground ?? model.style.background)
                    .frame(width: canvasSize.width, height: canvasSize.height)
                    .clipped()

                StudioPlayerLayerView(player: model.screenPlayer, gravity: .resize)
                    .opacity(model.isPreparingRedactionPreview || model.redactionPreviewError != nil ? 0 : 1)
                    .overlay {
                        if model.isPreparingRedactionPreview || model.redactionPreviewError != nil {
                            Color.black
                            Text(model.redactionPreviewError ?? "Preparing redacted preview…")
                                .foregroundStyle(.white)
                                .padding()
                        }
                    }
                    .frame(
                        width: layout.contentFillSize.width,
                        height: layout.contentFillSize.height
                    )
                    .scaleEffect(state.magnification)
                    .offset(
                        x: (0.5 - state.anchor.x) * state.magnification * layout.contentFillSize.width,
                        y: (0.5 - state.anchor.y) * state.magnification * layout.contentFillSize.height
                    )
                    .frame(width: layout.cardRect.width, height: layout.cardRect.height)
                    .overlay {
                        StudioInkOverlay(
                            frames: model.inkFrames(at: model.displayTime),
                            state: state,
                            cardSize: layout.cardRect.size,
                            contentSize: layout.contentFillSize
                        )
                    }
                    .overlay {
                        if let pointer = model.pointerFrame(at: model.displayTime) {
                            StudioCursorOverlay(
                                pointer: pointer,
                                artwork: model.artwork(id: pointer.artworkID),
                                state: state,
                                cardSize: layout.cardRect.size,
                                contentSize: layout.contentFillSize,
                                cursorScale: model.style.cursorScale,
                                showsClickEffect: model.showsPressEffects
                            )
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: layout.cardCornerRadius, style: .continuous))
                    .overlay {
                        if let caption = model.keystrokeCaption(at: model.displayTime) {
                            StudioKeystrokeCaptionView(
                                caption: caption,
                                placement: model.keystrokePlacement,
                                cardSize: layout.cardRect.size
                            )
                        }
                    }
                    .shadow(
                        color: .black.opacity(model.style.background == .none ? 0 : 0.55 * model.style.shadow),
                        radius: min(canvasSize.width, canvasSize.height) * 0.045 * model.style.shadow,
                        y: min(canvasSize.width, canvasSize.height) * 0.016 * model.style.shadow
                    )
                    .position(x: layout.cardRect.midX, y: layout.cardRect.midY)

                if model.isCameraVisible(at: model.displayTime), layout.bubbleRect.width > 0 {
                    StudioCameraBubble(model: model, layout: layout)
                }

                if let subtitle = model.subtitleText(at: model.displayTime) {
                    StudioSubtitleBarView(
                        text: subtitle,
                        karaokeLine: model.subtitleKaraokeLine(at: model.displayTime),
                        style: model.subtitleStyle,
                        canvasSize: canvasSize
                    )
                }

                if let zoomTarget {
                    StudioZoomTargetOverlay(
                        model: model,
                        cue: zoomTarget,
                        layout: layout,
                        canvasSize: canvasSize
                    )
                }
            }
            .frame(width: canvasSize.width, height: canvasSize.height)
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
    }

    /// The selected zoom, shown as a target on the paused canvas.
    private var zoomTargetCue: ZoomCue? {
        guard !isEditingVideoCrop,
              !model.isPlaying,
              model.zoomEnabled,
              let cue = model.selectedCue,
              cue.isEnabled else { return nil }
        return cue
    }
}

/// Where the selected zoom will look, drawn over the unzoomed frame with
/// everything outside it dimmed. Fixed zooms can be dragged to re-aim them;
/// pointer and smart zooms follow the pointer, so their target is shown at
/// the pointer's position under the playhead and can't be moved.
private struct StudioZoomTargetOverlay: View {
    @Bindable var model: RecordingStudioModel
    let cue: ZoomCue
    let layout: RecordingStudioLayout
    let canvasSize: CGSize

    @State private var dragStartPoint: CGPoint?
    @State private var isHovering = false

    private var isMovable: Bool {
        cue.anchorMode == .pinnedAnchor
    }

    private var target: CGPoint {
        if isMovable { return cue.pinnedPoint }
        return model.pointerLocation(at: model.displayTime) ?? CGPoint(x: 0.5, y: 0.5)
    }

    var body: some View {
        let card = layout.cardRect
        let content = layout.contentFillSize
        let magnification = max(CGFloat(cue.zoom), 1)
        let size = CGSize(width: card.width / magnification, height: card.height / magnification)
        let center = CGPoint(
            x: card.midX + content.width * (target.x - 0.5),
            y: card.midY + content.height * (target.y - 0.5)
        )
        let rect = CGRect(
            x: min(max(center.x - size.width / 2, card.minX), card.maxX - size.width),
            y: min(max(center.y - size.height / 2, card.minY), card.maxY - size.height),
            width: size.width,
            height: size.height
        )
        let isActive = isHovering || dragStartPoint != nil

        ZStack(alignment: .topLeading) {
            Path { path in
                path.addRoundedRect(
                    in: card,
                    cornerSize: CGSize(width: layout.cardCornerRadius, height: layout.cardCornerRadius),
                    style: .continuous
                )
                path.addRect(rect)
            }
            .fill(Color.black.opacity(0.38), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(
                    Color.white.opacity(isActive ? 1 : 0.9),
                    style: StrokeStyle(lineWidth: isActive ? 2.5 : 2, dash: isMovable ? [] : [6, 4])
                )
                .background(Color.white.opacity(0.001))
                .shadow(color: .black.opacity(0.35), radius: 2)
                .overlay(alignment: .topLeading) {
                    StudioCanvasBadge(
                        text: isMovable
                            ? InspectorValueFormat.magnification(fractionDigits: 1).displayString(for: magnification)
                            : "Follows pointer"
                    )
                    .padding(6)
                    .allowsHitTesting(false)
                }
                .frame(width: rect.width, height: rect.height)
                .contentShape(Rectangle())
                .onHover { isHovering = $0 && isMovable }
                .pointerStyle(isMovable ? (dragStartPoint == nil ? PointerStyle.grabIdle : .grabActive) : nil)
                .onTapGesture {}
                .gesture(moveGesture(contentSize: content), including: isMovable ? .all : .none)
                .help(isMovable ? "Drag to aim this zoom" : "Switch Camera Focus to Fixed to aim this zoom by hand")
                .offset(x: rect.minX, y: rect.minY)
        }
        .frame(width: canvasSize.width, height: canvasSize.height, alignment: .topLeading)
    }

    private func moveGesture(contentSize: CGSize) -> some Gesture {
        // Global coordinates: the target moves under the pointer, so local
        // translations would chase their own updates.
        DragGesture(coordinateSpace: .global)
            .onChanged { value in
                if dragStartPoint == nil {
                    dragStartPoint = cue.pinnedPoint
                    model.beginZoomCueEdit()
                }
                guard let start = dragStartPoint,
                      contentSize.width > 0,
                      contentSize.height > 0 else { return }
                var updated = cue
                updated.pinnedPoint = CGPoint(
                    x: min(max(start.x + value.translation.width / contentSize.width, 0), 1),
                    y: min(max(start.y + value.translation.height / contentSize.height, 0), 1)
                )
                model.updateZoomCue(updated)
            }
            .onEnded { _ in
                dragStartPoint = nil
                model.endZoomCueEdit(actionName: "Aim Zoom")
            }
    }
}

private struct VideoCropOverlay: View {
    static let coordinateSpaceName = "VideoCropSpace"

    @Bindable var model: RecordingStudioModel
    let canvasSize: CGSize
    /// The uncropped screen-video card inside the surrounding canvas.
    let videoFrame: CGRect
    @State private var moveStartCrop: CGRect?

    private var cropViewRect: CGRect {
        let crop = model.workingVideoCropRect.standardized
        return CGRect(
            x: videoFrame.minX + crop.minX * videoFrame.width,
            y: videoFrame.minY + crop.minY * videoFrame.height,
            width: crop.width * videoFrame.width,
            height: crop.height * videoFrame.height
        )
    }

    private var visibleHandles: [CropHandle] {
        model.videoCropAspect.locksAspect
            ? CropHandle.allCases.filter(\.isCorner)
            : CropHandle.allCases
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if model.isSelectingRedaction {
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .frame(width: videoFrame.width, height: videoFrame.height)
                    .position(x: videoFrame.midX, y: videoFrame.midY)
                    .gesture(DragGesture(coordinateSpace: .named(Self.coordinateSpaceName)).onChanged { value in
                        let rect = CGRect(x: min(value.startLocation.x, value.location.x),
                                          y: min(value.startLocation.y, value.location.y),
                                          width: abs(value.location.x - value.startLocation.x),
                                          height: abs(value.location.y - value.startLocation.y)).intersection(videoFrame)
                        if rect.width > 1, rect.height > 1 {
                            model.workingVideoCropRect = CGRect(x: (rect.minX - videoFrame.minX) / videoFrame.width,
                                                              y: (rect.minY - videoFrame.minY) / videoFrame.height,
                                                              width: rect.width / videoFrame.width,
                                                              height: rect.height / videoFrame.height)
                        }
                    })
                    .accessibilityHidden(true)
            }
            Path { path in
                path.addRect(videoFrame)
                path.addRect(cropViewRect)
            }
            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            Path { path in
                for index in 1...2 {
                    let x = cropViewRect.minX + cropViewRect.width * CGFloat(index) / 3
                    path.move(to: CGPoint(x: x, y: cropViewRect.minY))
                    path.addLine(to: CGPoint(x: x, y: cropViewRect.maxY))
                    let y = cropViewRect.minY + cropViewRect.height * CGFloat(index) / 3
                    path.move(to: CGPoint(x: cropViewRect.minX, y: y))
                    path.addLine(to: CGPoint(x: cropViewRect.maxX, y: y))
                }
            }
            .stroke(Color.white.opacity(0.35), lineWidth: 0.75)
            .allowsHitTesting(false)

            Rectangle()
                .strokeBorder(Color.white.opacity(0.95), lineWidth: 1.5)
                .frame(width: cropViewRect.width, height: cropViewRect.height)
                .position(x: cropViewRect.midX, y: cropViewRect.midY)
                .shadow(color: .black.opacity(0.3), radius: 1)
                .allowsHitTesting(false)

            Rectangle()
                .fill(Color.white.opacity(0.001))
                .frame(width: max(cropViewRect.width, 1), height: max(cropViewRect.height, 1))
                .position(x: cropViewRect.midX, y: cropViewRect.midY)
                .gesture(moveGesture)

            ForEach(visibleHandles, id: \.self) { handle in
                VideoCropHandleView(handle: handle)
                    .position(handlePoint(handle))
                    .gesture(handleGesture(handle))
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height, alignment: .topLeading)
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.coordinateSpaceName))
            .onChanged { value in
                let start = moveStartCrop ?? model.workingVideoCropRect.standardized
                if moveStartCrop == nil { moveStartCrop = start }
                guard videoFrame.width > 0, videoFrame.height > 0 else { return }
                model.moveVideoCrop(
                    from: start,
                    byNormalized: CGSize(
                        width: value.translation.width / videoFrame.width,
                        height: value.translation.height / videoFrame.height
                    )
                )
            }
            .onEnded { _ in moveStartCrop = nil }
    }

    private func handleGesture(_ handle: CropHandle) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.coordinateSpaceName))
            .onChanged { value in
                guard videoFrame.width > 0, videoFrame.height > 0 else { return }
                model.updateVideoCrop(
                    handle: handle,
                    toNormalized: CGPoint(
                        x: (value.location.x - videoFrame.minX) / videoFrame.width,
                        y: (value.location.y - videoFrame.minY) / videoFrame.height
                    )
                )
            }
    }

    private func handlePoint(_ handle: CropHandle) -> CGPoint {
        let unit = handle.unitPoint
        return CGPoint(
            x: cropViewRect.minX + cropViewRect.width * unit.x,
            y: cropViewRect.minY + cropViewRect.height * unit.y
        )
    }
}

private struct VideoCropHandleView: View {
    let handle: CropHandle

    var body: some View {
        ZStack {
            Color.white.opacity(0.001)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())

            if handle.isCorner {
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(Color.white)
                    .frame(width: 13, height: 13)
                    .overlay {
                        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                            .strokeBorder(Color.black.opacity(0.18), lineWidth: 0.5)
                    }
                    .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
            } else {
                let isHorizontal = handle == .top || handle == .bottom
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.white)
                    .frame(width: isHorizontal ? 26 : 7, height: isHorizontal ? 7 : 26)
                    .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
            }
        }
    }
}

/// Recorded pointer artwork, placed through the same viewport transform the
/// video card uses (see RecordingPointerTimeline for why it is reconstructed).
/// Pen strokes drawn during the take, mapped like the cursor so they stay on
/// the content under zooms, reframes and crops.
private struct StudioInkOverlay: View {
    let frames: [RecordingInkTimeline.Frame]
    let state: ViewportFrame
    let cardSize: CGSize
    let contentSize: CGSize

    var body: some View {
        Canvas { context, _ in
            let scale = contentSize.width * state.magnification
            let scaleY = contentSize.height * state.magnification
            for frame in frames {
                let points = frame.points.map {
                    CGPoint(x: cardSize.width / 2 + scale * ($0.x - state.anchor.x),
                            y: cardSize.height / 2 + scaleY * ($0.y - state.anchor.y))
                }
                context.withCGContext { cg in
                    RecordingInkPath.draw(points, oval: frame.stroke.fittedOval == true && frame.pointCount == frame.stroke.points.count,
                                      marker: frame.stroke.markerNumber, color: frame.stroke.color,
                        opacity: frame.opacity, width: frame.stroke.width * min(scale, scaleY),
                        bounds: CGRect(x: cardSize.width / 2 - scale * state.anchor.x,
                                       y: cardSize.height / 2 - scaleY * state.anchor.y, width: scale, height: scaleY), in: cg)
                }
            }
        }
        .frame(width: cardSize.width, height: cardSize.height)
        .allowsHitTesting(false)
    }
}

private struct StudioCursorOverlay: View {
    let pointer: PointerFrame
    let artwork: PointerArtwork?
    let state: ViewportFrame
    let cardSize: CGSize
    /// The video's draw size at magnification 1 - equal to the card
    /// normally, larger when a reframe aspect-fills it.
    var contentSize: CGSize?
    let cursorScale: CGFloat
    let showsClickEffect: Bool

    var body: some View {
        let content = contentSize ?? cardSize
        let tip = CGPoint(
            x: cardSize.width / 2 + content.width * state.magnification * (pointer.location.x - state.anchor.x),
            y: cardSize.height / 2 + content.height * state.magnification * (pointer.location.y - state.anchor.y)
        )

        ZStack(alignment: .topLeading) {
            if showsClickEffect, let press = pointer.press {
                let pressTip = CGPoint(
                    x: cardSize.width / 2
                        + content.width * state.magnification * (press.location.x - state.anchor.x),
                    y: cardSize.height / 2
                        + content.height * state.magnification * (press.location.y - state.anchor.y)
                )
                let effect = PointerPressEffectStyle.geometry(
                    progress: press.progress,
                    referenceHeight: content.height,
                    cursorScale: cursorScale
                )
                let accent = PointerPressEffectStyle.color
                Circle()
                    .fill(
                        Color(red: accent.red, green: accent.green, blue: accent.blue)
                            .opacity(effect.impactOpacity)
                    )
                    .frame(width: effect.impactRadius * 2, height: effect.impactRadius * 2)
                    .position(x: pressTip.x, y: pressTip.y)
                Circle()
                    .stroke(
                        Color(red: accent.red, green: accent.green, blue: accent.blue)
                            .opacity(effect.rippleOpacity),
                        lineWidth: effect.rippleLineWidth
                    )
                    .frame(width: effect.rippleRadius * 2, height: effect.rippleRadius * 2)
                    .position(x: pressTip.x, y: pressTip.y)
            }

            if let artwork,
               let image = StudioCursorImageCache.image(for: artwork) {
                let anchor = artwork.normalizedAnchor
                let height = content.height
                    * PointerArtworkMetrics.heightRatio
                    * cursorScale
                    * artwork.intrinsicScale
                let size = CGSize(
                    width: height * artwork.aspectRatio,
                    height: height
                )
                Image(nsImage: image)
                    .resizable()
                    .frame(width: size.width, height: size.height)
                    .scaleEffect(
                        CGFloat(pointer.magnification),
                        anchor: UnitPoint(x: anchor.x, y: anchor.y)
                    )
                    .rotationEffect(
                        .degrees(pointer.tiltDegrees),
                        anchor: UnitPoint(x: anchor.x, y: anchor.y)
                    )
                    .position(
                        x: tip.x + (0.5 - anchor.x) * size.width,
                        y: tip.y + (0.5 - anchor.y) * size.height
                    )
            }
        }
        .frame(width: cardSize.width, height: cardSize.height)
        .allowsHitTesting(false)
    }
}

/// The keystroke caption pill: one rounded container with the chord's
/// modifiers and key. Geometry comes from KeystrokeCaptionMetrics so the
/// exporter draws the identical pill.
private struct StudioKeystrokeCaptionView: View {
    let caption: KeystrokeCaptionFrame
    let placement: RecordingKeystrokePlacement
    let cardSize: CGSize

    var body: some View {
        let metrics = KeystrokeCaptionMetrics(cardHeight: cardSize.height)
        let (modifiers, key) = KeystrokeCaptionMetrics.text(for: caption)

        (Text(modifiers).foregroundStyle(.white.opacity(KeystrokeCaptionMetrics.modifierAlpha))
            + Text(key).foregroundStyle(.white))
            .font(.system(size: metrics.fontSize, weight: .semibold, design: .rounded))
            .lineLimit(1)
            .padding(.horizontal, metrics.paddingHorizontal)
            .padding(.vertical, metrics.paddingVertical)
            .background(
                RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
                    .fill(.black.opacity(KeystrokeCaptionMetrics.backgroundAlpha))
            )
            .scaleEffect(caption.scale)
            .opacity(caption.opacity)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: placement.alignment)
            .padding(metrics.margin)
            .frame(width: cardSize.width, height: cardSize.height)
            .allowsHitTesting(false)
    }
}

/// The narration subtitle bar: rounded black bar, white text, center-locked
/// horizontally at the style's vertical position on the full canvas
/// (background included). Geometry comes from SubtitleBarMetrics so the
/// exporter draws the identical bar.
private struct StudioSubtitleBarView: View {
    let text: String
    var karaokeLine: KaraokeTimeline.Line?
    let style: SubtitleBarStyle
    let canvasSize: CGSize

    var body: some View {
        let metrics = SubtitleBarMetrics(canvasSize: canvasSize, style: style)

        barText
            .font(.system(size: metrics.fontSize, weight: .semibold, design: .rounded))
            // Long lines wrap into centered lines on narrow canvases,
            // matching the exporter's framesetter layout; the scale
            // factor only kicks in past the shared line cap.
            .lineLimit(SubtitleBarMetrics.maximumLineCount)
            .multilineTextAlignment(.center)
            .lineSpacing(metrics.fontSize * (SubtitleBarMetrics.lineSpacingFactor - 1))
            .minimumScaleFactor(0.4)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, metrics.paddingHorizontal)
            .padding(.vertical, metrics.paddingVertical)
            .background(
                RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
                    .fill(.black.opacity(SubtitleBarMetrics.backgroundAlpha))
            )
            // Invisible width cap: constrains where the text wraps while
            // the pill above hugs the text, so the bar never spans the
            // canvas.
            .frame(
                maxWidth: metrics.maximumTextWidth(canvasWidth: canvasSize.width)
                    + metrics.paddingHorizontal * 2
            )
            .position(
                x: canvasSize.width / 2,
                y: canvasSize.height * CGFloat(style.clampedVerticalPosition)
            )
            .frame(width: canvasSize.width, height: canvasSize.height)
            .allowsHitTesting(false)
    }

    /// Plain white cue text, or karaoke-colored words matching the
    /// exporter's palette exactly (SubtitleBarMetrics.karaoke*).
    private var barText: Text {
        guard let karaokeLine, !karaokeLine.words.isEmpty else {
            return Text(text).foregroundStyle(.white)
        }
        var combined = Text(verbatim: "")
        for (index, word) in karaokeLine.words.enumerated() {
            let color: Color
            if index == karaokeLine.activeIndex {
                color = Color(cgColor: SubtitleBarMetrics.karaokeAccent)
            } else if index < karaokeLine.spokenCount {
                color = .white
            } else {
                color = .white.opacity(SubtitleBarMetrics.karaokeUpcomingAlpha)
            }
            let piece = Text(verbatim: index > 0 ? " \(word)" : word)
                .foregroundStyle(color)
            combined = combined + piece
        }
        return combined
    }
}

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

private extension RecordingKeystrokePlacement {
    var alignment: Alignment {
        switch self {
        case .topLeft: .topLeading
        case .topCenter: .top
        case .topRight: .topTrailing
        case .bottomLeft: .bottomLeading
        case .bottomCenter: .bottom
        case .bottomRight: .bottomTrailing
        }
    }
}

@MainActor
private enum StudioCursorImageCache {
    private static var capturedImages: [String: NSImage] = [:]

    static func image(for artwork: PointerArtwork) -> NSImage? {
        let cacheKey = "\(artwork.artworkID)-\(artwork.imageData.hashValue)"
        if let cached = capturedImages[cacheKey] {
            return cached
        }
        guard let image = NSImage(data: artwork.imageData) else { return nil }
        capturedImages[cacheKey] = image
        return image
    }
}

/// The draggable talking-head bubble. It snaps to the canvas corners, edge
/// midpoints and center lines (inside the same safe margin the layout keeps),
/// drawing a guide for each axis it has snapped on.
private struct StudioCameraBubble: View {
    @Bindable var model: RecordingStudioModel
    let layout: RecordingStudioLayout

    private static let snapDistance: CGFloat = 8
    private static let hoverRingPadding: CGFloat = 3

    private struct SnapGuides: Equatable {
        var x: CGFloat?
        var y: CGFloat?
    }

    /// Bubble center in canvas points when the drag began.
    @State private var dragStartCenter: CGPoint?
    @State private var guides = SnapGuides()
    @State private var isHovering = false

    var body: some View {
        let rect = layout.bubbleRect
        let canvas = layout.canvasSize
        let isActive = isHovering || dragStartCenter != nil

        ZStack(alignment: .topLeading) {
            guideLines(in: canvas)

            StudioPlayerLayerView(player: model.cameraPlayer, gravity: .resizeAspectFill)
                .frame(width: rect.width, height: rect.height)
                .clipShape(RoundedRectangle(cornerRadius: layout.bubbleCornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: layout.bubbleCornerRadius, style: .continuous)
                        .strokeBorder(.white.opacity(0.25), lineWidth: 1)
                }
                .overlay {
                    if isActive {
                        // Nested radius: the ring sits `hoverRingPadding` outside.
                        RoundedRectangle(
                            cornerRadius: layout.bubbleCornerRadius + Self.hoverRingPadding,
                            style: .continuous
                        )
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .padding(-Self.hoverRingPadding)
                        .allowsHitTesting(false)
                    }
                }
                .shadow(
                    color: .black.opacity(0.35),
                    radius: min(canvas.width, canvas.height) * 0.022,
                    y: min(canvas.width, canvas.height) * 0.009
                )
                .contentShape(RoundedRectangle(cornerRadius: layout.bubbleCornerRadius, style: .continuous))
                .onHover { isHovering = $0 }
                .pointerStyle(dragStartCenter == nil ? PointerStyle.grabIdle : .grabActive)
                // Swallow clicks so they don't toggle playback underneath.
                .onTapGesture {}
                .gesture(dragGesture(rect: rect, canvas: canvas))
                .help("Drag to place the camera")
                .offset(x: rect.minX, y: rect.minY)
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
    }

    @ViewBuilder
    private func guideLines(in canvas: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            if let x = guides.x {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 1, height: canvas.height)
                    .offset(x: x - 0.5)
            }
            if let y = guides.y {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: canvas.width, height: 1)
                    .offset(y: y - 0.5)
            }
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private func dragGesture(rect: CGRect, canvas: CGSize) -> some Gesture {
        // Global coordinates: the bubble moves under the pointer, so local
        // translations would chase their own updates.
        DragGesture(coordinateSpace: .global)
            .onChanged { value in
                if dragStartCenter == nil {
                    // Start from where the bubble is drawn, not the stored
                    // center, which the layout may have clamped.
                    dragStartCenter = CGPoint(x: rect.midX, y: rect.midY)
                }
                guard let start = dragStartCenter, canvas.width > 0, canvas.height > 0 else { return }
                let proposed = CGPoint(
                    x: start.x + value.translation.width,
                    y: start.y + value.translation.height
                )
                let margin = RecordingStudioLayout.bubbleMargin(
                    forMinDimension: min(canvas.width, canvas.height)
                )
                let (snappedX, guideX) = Self.snap(
                    proposed.x,
                    radius: rect.width / 2,
                    length: canvas.width,
                    margin: margin
                )
                let (snappedY, guideY) = Self.snap(
                    proposed.y,
                    radius: rect.height / 2,
                    length: canvas.height,
                    margin: margin
                )
                guides = SnapGuides(x: guideX, y: guideY)
                model.style.camera.center = CGPoint(
                    x: min(max(snappedX / canvas.width, 0), 1),
                    y: min(max(snappedY / canvas.height, 0), 1)
                )
            }
            .onEnded { _ in
                dragStartCenter = nil
                withAnimation(.fade) {
                    guides = SnapGuides()
                }
            }
    }

    /// Snaps one axis of the bubble center to the near edge, the middle, or
    /// the far edge. Returns the snapped center and where to draw the guide.
    private static func snap(
        _ center: CGFloat,
        radius: CGFloat,
        length: CGFloat,
        margin: CGFloat
    ) -> (CGFloat, CGFloat?) {
        let targets: [(center: CGFloat, guide: CGFloat)] = [
            (margin + radius, margin),
            (length / 2, length / 2),
            (length - margin - radius, length - margin)
        ]
        guard let nearest = targets.min(by: { abs($0.center - center) < abs($1.center - center) }),
              abs(nearest.center - center) <= snapDistance else {
            return (center, nil)
        }
        return (nearest.center, nearest.guide)
    }
}

/// Renders an AnnotationBackgroundStyle as a live SwiftUI layer.
private struct StudioBackgroundView: View {
    let style: AnnotationBackgroundStyle

    var body: some View {
        switch style {
        case .none:
            Color(white: 0.04)
        case .solid(let color):
            color.color
        case .gradient(let gradient):
            LinearGradient(
                colors: gradient.colors.map(\.color),
                startPoint: gradient.startPoint,
                endPoint: gradient.endPoint
            )
        case .customWallpaper(let wallpaper):
            if let image = NSImage(contentsOf: wallpaper.url) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color(white: 0.04)
            }
        }
    }
}

/// AVPlayerLayer host for the preview canvas.
private struct StudioPlayerLayerView: NSViewRepresentable {
    let player: AVPlayer
    let gravity: AVLayerVideoGravity

    func makeNSView(context: Context) -> StudioPlayerContainerView {
        let view = StudioPlayerContainerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = gravity
        return view
    }

    func updateNSView(_ nsView: StudioPlayerContainerView, context: Context) {
        if nsView.playerLayer.player !== player {
            nsView.playerLayer.player = player
        }
        nsView.playerLayer.videoGravity = gravity
    }
}

final class StudioPlayerContainerView: NSView {
    let playerLayer = AVPlayerLayer()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        playerLayer.frame = bounds
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}

// MARK: - Timeline

private struct StudioTimelineEditor: View {
    @Bindable var model: RecordingStudioModel

    /// Horizontal scale of the lanes, as a multiplier over "the whole
    /// recording fits the viewport". Zoom 1 is the timeline's original
    /// fixed-width layout; anything above it scrolls.
    @State private var zoom: Double = 1
    @State private var viewportWidth: CGFloat = 1
    @State private var scrollX: CGFloat = 0
    @State private var scrollPosition = ScrollPosition(edge: .leading)
    @State private var isScrubbing = false
    @State private var isResetClipsConfirmationPresented = false

    /// Step per zoom button press / keyboard shortcut.
    private static let zoomStep: Double = 1.6
    /// How close to the viewport edge the playhead may drift before the
    /// lanes scroll to keep it in sight.
    private static let followMargin: CGFloat = 48

    private var scale: StudioTimelineScale {
        StudioTimelineScale(
            viewportWidth: viewportWidth,
            duration: model.duration,
            zoom: zoom
        )
    }

    var body: some View {
        VStack(spacing: StudioTimelineMetrics.rowSpacing) {
            transport
            lanes
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.45))
                .frame(height: 0.5)
        }
    }

    private var lanes: some View {
        GeometryReader { proxy in
            // The proxy width leads the stored one by a frame, so lay the
            // lanes out from it and keep the state copy for the controls.
            let scale = StudioTimelineScale(
                viewportWidth: max(proxy.size.width, 1),
                duration: model.duration,
                zoom: zoom
            )

            VStack(spacing: StudioTimelineMetrics.rowSpacing) {
                Color.clear
                    .frame(height: StudioTimelineMetrics.playheadLaneHeight)

                StudioTimelineRuler(
                    duration: model.duration,
                    pointsPerSecond: scale.pointsPerSecond,
                    scrollX: scrollX
                )
                .frame(height: StudioTimelineMetrics.rulerHeight)

                scrollingLanes(scale: scale)
            }
            .overlay {
                StudioTimelineInkMarks(model: model, scale: scale, scrollX: scrollX)
            }
            .overlay {
                StudioTimelineChapters(
                    model: model,
                    scale: scale,
                    scrollX: scrollX,
                    isScrubbing: isScrubbing,
                    onPlayheadMove: followPlayhead(to:)
                )
            }
            .onChange(of: proxy.size.width, initial: true) { _, width in
                viewportWidth = max(width, 1)
                clampZoom()
            }
        }
        .frame(height: StudioTimelineMetrics.lanesHeight)
        .onChange(of: model.duration) { _, _ in clampZoom() }
    }

    /// The two lanes that carry real edit targets live in a horizontal scroll
    /// view sized to the zoomed timeline. The ruler, playhead and lane chrome
    /// stay viewport-sized and redraw against `scrollX` instead - a rounded
    /// rectangle or Canvas tens of thousands of points wide would be a single
    /// oversized layer, while an AppKit view only ever draws its visible rect.
    private func scrollingLanes(scale: StudioTimelineScale) -> some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: StudioTimelineMetrics.rowSpacing) {
                Color.clear
                    .frame(height: StudioTimelineMetrics.clipLaneHeight)
                StudioZoomLaneBackground(
                    showsHint: model.zoomEnabled && model.zoomTimelineBlocks.isEmpty
                )
                    .frame(height: StudioTimelineMetrics.zoomLaneHeight)
                Color.clear
                    .frame(height: StudioTimelineMetrics.scrollerGutter)
            }

            ScrollView(.horizontal) {
                VStack(spacing: StudioTimelineMetrics.rowSpacing) {
                    clipLane
                        .frame(
                            width: scale.contentWidth,
                            height: StudioTimelineMetrics.clipLaneHeight
                        )

                    StudioZoomLane(
                        model: model,
                        scale: scale,
                        visibleRange: scale.visibleRange(scrollX: scrollX),
                        onScrubbing: { isScrubbing = $0 }
                    )
                    .frame(
                        width: scale.contentWidth,
                        height: StudioTimelineMetrics.zoomLaneHeight
                    )

                    Color.clear
                        .frame(height: StudioTimelineMetrics.scrollerGutter)
                }
            }
            .scrollPosition($scrollPosition)
            // Blocks and clips land where an edit puts them, even when the
            // edit came from an animated inspector or tool-row action.
            .transaction { $0.animation = nil }
            .scrollIndicators(scale.isScrollable ? .visible : .never)
            .scrollBounceBehavior(.basedOnSize)
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.x
            } action: { _, offset in
                if abs(offset - scrollX) > 0.01 {
                    scrollX = offset
                }
            }
        }
        .frame(height: StudioTimelineMetrics.scrollingLanesHeight)
    }

    private var clipLane: some View {
        RecordingClipTimelineView(
            selectedClipID: model.selectedClipID,
            playheadTime: $model.currentTime,
            timeline: model.clipTimeline,
            sourceDuration: model.sourceDuration,
            thumbnails: model.timelineThumbnails,
            onSelect: { model.selectClip(id: $0) },
            onSeek: { time in
                model.pause()
                model.seek(to: time)
            },
            onHover: { time in
                model.hoverPreviewTime = time
            },
            onSplit: { model.splitClip(at: $0) },
            onDelete: { deleteSelection() },
            onTrim: { model.trimClip($0) },
            onZoom: { factor, anchorTime in
                applyZoom(factor: factor, anchorTime: anchorTime)
            },
            onStep: { seconds in
                model.pause()
                model.seek(to: model.currentTime + seconds)
            },
            onScrubbing: { isScrubbing = $0 }
        )
    }

    // MARK: Zoom & scroll

    /// Rescales around `anchorTime`, keeping that moment under the same
    /// screen position so pinching or ⌘-scrolling doesn't shove the edit
    /// you were aiming at out of the viewport.
    private func applyZoom(factor: Double, anchorTime: TimeInterval?) {
        let current = scale
        guard current.duration > 0, factor.isFinite, factor > 0 else { return }
        let anchor = anchorTime ?? current.time(forX: scrollX + viewportWidth / 2)
        let anchorViewportX = current.x(for: anchor) - scrollX
        let next = min(max(zoom * factor, 1), current.maxZoom)
        guard abs(next - zoom) > 0.0001 else { return }

        // A pinch arrives as dozens of small steps; let the storyboard scale
        // with the lane and resample once the gesture settles.
        model.timelineThumbnails.deferSampling()
        zoom = next
        var zoomed = current
        zoomed.zoom = next
        scroll(to: zoomed.x(for: anchor) - anchorViewportX, in: zoomed)
    }

    private func fitTimeline() {
        guard zoom > 1 else { return }
        zoom = 1
        scrollX = 0
        scrollPosition.scrollTo(edge: .leading)
    }

    /// Keeps the zoom inside range after the viewport or the edited duration
    /// changes - a cut or a wider window can leave the old scale past the cap.
    private func clampZoom() {
        let clamped = min(max(zoom, 1), scale.maxZoom)
        if abs(clamped - zoom) > 0.0001 {
            zoom = clamped
        }
    }

    private func followPlayhead(to time: TimeInterval) {
        let current = scale
        guard current.isScrollable else { return }
        let x = current.x(for: time)
        guard x < scrollX + Self.followMargin
            || x > scrollX + viewportWidth - Self.followMargin else { return }
        // While playing, land the playhead a third in so there is room to
        // watch what is coming; a seek just centers it.
        let inset = model.isPlaying ? viewportWidth / 3 : viewportWidth / 2
        scroll(to: x - inset, in: current)
    }

    private func scroll(to x: CGFloat, in scale: StudioTimelineScale) {
        let clamped = min(max(x, 0), max(0, scale.contentWidth - scale.viewportWidth))
        scrollX = clamped
        scrollPosition.scrollTo(x: clamped)
    }

    /// Zoom buttons keep the playhead pinned when it is on screen, so the
    /// scale grows around the edit point rather than the viewport middle.
    private var buttonZoomAnchor: TimeInterval {
        let x = scale.x(for: model.currentTime)
        if x >= scrollX, x <= scrollX + viewportWidth {
            return model.currentTime
        }
        return scale.time(forX: scrollX + viewportWidth / 2)
    }

    private var zoomControls: some View {
        HStack(spacing: 6) {
            StudioTransportTray {
                timelineButton("Zoom Out (⌘-)", systemImage: "minus.magnifyingglass") {
                    applyZoom(factor: 1 / Self.zoomStep, anchorTime: buttonZoomAnchor)
                }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(zoom <= 1.0001)

                timelineButton("Zoom In (⌘=)", systemImage: "plus.magnifyingglass") {
                    applyZoom(factor: Self.zoomStep, anchorTime: buttonZoomAnchor)
                }
                .keyboardShortcut("=", modifiers: .command)
                .disabled(zoom >= scale.maxZoom - 0.0001)

                timelineButton("Fit Timeline (⌘0)", systemImage: "arrow.left.and.right") {
                    fitTimeline()
                }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(zoom <= 1.0001)
            }

            if zoom > 1.0001 {
                Text(String(format: "%.1f×", zoom))
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var editControls: some View {
        HStack(spacing: 6) {
            StudioTransportTray {
                timelineButton("Split at Playhead (⌘B)", systemImage: "scissors") {
                    model.splitClip(at: model.currentTime)
                }
                .keyboardShortcut("b", modifiers: .command)

                timelineButton("Delete Selection", systemImage: "trash") {
                    deleteSelection()
                }
                .disabled(!canDeleteSelection)

                timelineButton("Reset All Clip Edits…", systemImage: "arrow.counterclockwise") {
                    isResetClipsConfirmationPresented = true
                }
                .disabled(!model.hasClipEdits)
                .confirmationDialog(
                    "Reset all clip edits?",
                    isPresented: $isResetClipsConfirmationPresented
                ) {
                    Button("Reset Clips", role: .destructive) {
                        model.resetClips()
                    }
                } message: {
                    Text("Every split, trim, deletion and speed change goes back to the original recording. You can undo this.")
                }
            }

            StudioTransportTray {
                timelineButton("Undo (⌘Z)", systemImage: "arrow.uturn.backward") {
                    model.undo()
                }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!model.canUndo)

                timelineButton("Redo (⇧⌘Z)", systemImage: "arrow.uturn.forward") {
                    model.redo()
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!model.canRedo)
            }
        }
    }

    private var playbackControls: some View {
        HStack(spacing: 12) {
            HStack(spacing: 0) {
                StudioTimecodeField(model: model)
                    .frame(width: model.duration >= 3600 ? 74 : 58, alignment: .trailing)
                Text(" / \(studioPreciseTimecode(model.duration))")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }

            HStack(spacing: 4) {
                timelineButton("Back to Start (Home)", systemImage: "backward.end.fill") {
                    model.pause()
                    model.seek(to: 0)
                }

                Button {
                    model.togglePlayback()
                } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.primary.opacity(0.9))
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color.primary.opacity(0.08)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [])
                .help(model.isPlaying ? "Pause (Space)" : "Play (Space)")
                .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
                .disabled(!model.isLoaded || model.isRestoringDocument)

                timelineButton("Skip to End (End)", systemImage: "forward.end.fill") {
                    model.pause()
                    model.seek(to: model.duration)
                }
            }

            if model.isPlaying, model.shuttleRate != 1 {
                Text(RecordingStudioModel.shuttleTitle(model.shuttleRate))
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                    .fixedSize()
            }
        }
    }

    private var transport: some View {
        ZStack {
            HStack(spacing: 0) {
                zoomControls
                Spacer(minLength: 0)
                editControls
            }

            playbackControls
        }
        .frame(height: 36)
    }

    private var canDeleteSelection: Bool {
        model.selectedCueID != nil || model.canDeleteSelectedClip
    }

    private func deleteSelection() {
        if let cueID = model.selectedCueID {
            model.removeZoomCue(id: cueID)
        } else if model.selectedClipID != nil {
            model.deleteSelectedClip()
        }
    }

    private func timelineButton(
        _ help: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 28, height: 26)
                .contentShape(RoundedRectangle(cornerRadius: StudioTransportMetrics.buttonRadius, style: .continuous))
        }
        .buttonStyle(TransportIconButtonStyle())
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A quiet filled tray grouping related transport buttons, the same
/// treatment as the annotator's tool grid.
private enum StudioTransportMetrics {
    static let buttonRadius: CGFloat = 6
    static let trayInset: CGFloat = 2
}

private struct StudioTransportTray<Content: View>: View {
    @ViewBuilder let content: () -> Content

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // Nested radius: the tray wraps buttons inset by `inset`.
        let shape = RoundedRectangle(
            cornerRadius: StudioTransportMetrics.buttonRadius + StudioTransportMetrics.trayInset,
            style: .continuous
        )
        HStack(spacing: 0) {
            content()
        }
        .padding(StudioTransportMetrics.trayInset)
        .background(shape.fill(InspectorControlPalette.trackFill(for: colorScheme)))
    }
}

private struct TransportIconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(
                .primary.opacity(
                    isEnabled ? (configuration.isPressed || isHovering ? 0.95 : 0.78) : 0.25
                )
            )
            .background {
                RoundedRectangle(cornerRadius: StudioTransportMetrics.buttonRadius, style: .continuous)
                    .fill(Color.primary.opacity(
                        isEnabled ? (configuration.isPressed ? 0.1 : isHovering ? 0.06 : 0) : 0
                    ))
            }
            .onHover { isHovering = $0 }
    }
}

private enum StudioTimelineMetrics {
    static let rowSpacing: CGFloat = 8
    static let playheadLaneHeight: CGFloat = 14
    static let rulerHeight: CGFloat = 16
    static let clipLaneHeight: CGFloat = 52
    static let zoomLaneHeight: CGFloat = 30
    /// Room under the lanes for the horizontal scroller, so it never sits on
    /// top of a zoom block.
    static let scrollerGutter: CGFloat = 8

    static let scrollingLanesHeight = clipLaneHeight + zoomLaneHeight
        + scrollerGutter + rowSpacing * 2
    static let lanesHeight = playheadLaneHeight + rulerHeight
        + scrollingLanesHeight + rowSpacing * 2
}

/// The playhead and the skim line, with the only reads of the playhead's
/// time and hover preview in the dock. Both change many times a second;
/// kept here, they redraw this layer instead of every lane.
private struct StudioPlayheadLayer: View {
    let model: RecordingStudioModel
    let chapters: [RecordingChapter]
    let scale: StudioTimelineScale
    let scrollX: CGFloat
    let isScrubbing: Bool
    /// The playhead moved, so the lanes can scroll to keep it in sight.
    let onMove: (TimeInterval) -> Void

    var body: some View {
        let hoverTime = (model.isPlaying || model.isDraggingTimelineBlock) ? nil : model.hoverPreviewTime
        StudioTimelinePlayhead(
            time: model.currentTime,
            chapters: chapters,
            scale: scale,
            scrollX: scrollX,
            skimX: hoverTime.map { scale.x(for: $0) - scrollX },
            showsSkim: hoverTime != nil,
            isScrubbing: isScrubbing,
            onScrub: { time in
                model.pause()
                model.seek(to: time)
            },
            onStep: { delta in
                model.stepFrames(delta)
            }
        )
        .transaction { $0.animation = nil }
        .onChange(of: model.currentTime) { _, time in onMove(time) }
    }
}

/// Map chapter names only when chapter/transcript edits change, not on playback ticks.
private struct StudioTimelineChapters: View {
    let model: RecordingStudioModel
    let scale: StudioTimelineScale
    let scrollX: CGFloat
    let isScrubbing: Bool
    let onPlayheadMove: (TimeInterval) -> Void

    var body: some View {
        let chapters = model.visibleChapters
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                ForEach(chapters) { chapter in
                    StudioTimelineChapterMarker(model: model, chapter: chapter, chapters: chapters,
                                                scale: scale, scrollX: scrollX, viewportWidth: proxy.size.width)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .coordinateSpace(name: StudioTimelineChapterMarker.coordinateSpace)
        .clipped()
        // The playhead stays above the marker controls, with its original, unclipped hit area.
        .overlay {
            StudioPlayheadLayer(
                model: model,
                chapters: chapters,
                scale: scale,
                scrollX: scrollX,
                isScrubbing: isScrubbing,
                onMove: onPlayheadMove
            )
        }
    }
}

/// A short red tick at the bottom of the ruler where each drawing starts.
private struct StudioTimelineInkMarks: View {
    let model: RecordingStudioModel
    let scale: StudioTimelineScale
    let scrollX: CGFloat

    private static let hitWidth: CGFloat = 10

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                ForEach(model.showsInk ? model.inkStrokes : []) { stroke in
                    if let time = model.editorTime(forSourceTime: stroke.startTime) {
                        let x = scale.x(for: time) - scrollX
                        if x >= 0, x <= proxy.size.width {
                            Button {
                                model.jumpToInkStroke(stroke)
                            } label: {
                                Capsule()
                                    .fill(Color(nsColor: .systemRed))
                                    .frame(width: 3, height: 7)
                                    .frame(width: Self.hitWidth, height: StudioTimelineMetrics.rulerHeight,
                                           alignment: .bottom)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Drawing \(model.inkStrokeNumber(stroke.id))")
                            .accessibilityLabel("Drawing \(model.inkStrokeNumber(stroke.id))")
                            .accessibilityHint("Activate to jump to it.")
                            .offset(x: x - Self.hitWidth / 2,
                                    y: StudioTimelineMetrics.playheadLaneHeight + StudioTimelineMetrics.rowSpacing)
                        }
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .clipped()
        .disabled(!model.isLoaded || model.hasRunningWork)
    }
}

private struct StudioTimelineChapterMarker: View {
    let model: RecordingStudioModel
    let chapter: RecordingChapter
    let chapters: [RecordingChapter]
    let scale: StudioTimelineScale
    let scrollX: CGFloat
    let viewportWidth: CGFloat
    @State private var draftStart: TimeInterval?
    @State private var grabOffset: CGFloat?

    private static let hitWidth: CGFloat = 12
    static let coordinateSpace = "studio.chapterMarker"

    var body: some View {
        let x = scale.x(for: draftStart ?? chapter.start) - scrollX
        let visible = x >= 0 && x <= viewportWidth
        Button {
            model.jumpToChapter(chapter)
        } label: {
            Rectangle()
                .fill(Color.orange)
                .frame(width: 1, height: StudioTimelineMetrics.rulerHeight)
                .frame(width: Self.hitWidth, height: StudioTimelineMetrics.rulerHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(chapter.title)
        .accessibilityLabel("Chapter, \(chapter.title)")
        .accessibilityValue(Text("\(chapter.start, format: .number.precision(.fractionLength(2))) seconds"))
        .accessibilityHint("Activate to jump. Adjust to move the chapter start.")
        .accessibilityAdjustableAction { direction in
            model.pause()
            switch direction {
            case .increment: model.moveChapter(id: chapter.id, to: chapter.start + 1)
            case .decrement: model.moveChapter(id: chapter.id, to: chapter.start - 1)
            @unknown default: break
            }
        }
        .highPriorityGesture(
            DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.coordinateSpace))
                .onChanged { value in
                    if grabOffset == nil {
                        grabOffset = value.startLocation.x - (scale.x(for: chapter.start) - scrollX)
                        model.pause()
                    }
                    draftStart = clampedTime(at: value.location.x)
                }
                .onEnded { value in
                    if let time = clampedTime(at: value.location.x) { model.moveChapter(id: chapter.id, to: time) }
                    draftStart = nil
                    grabOffset = nil
                }
        )
        .disabled(!model.isLoaded || model.hasRunningWork)
        .opacity(visible || grabOffset != nil ? 1 : 0)
        .allowsHitTesting(visible || grabOffset != nil)
        .offset(x: x - Self.hitWidth / 2,
                y: StudioTimelineMetrics.playheadLaneHeight + StudioTimelineMetrics.rowSpacing)
    }

    private func clampedTime(at x: CGFloat) -> TimeInterval? {
        RecordingChapterPlanner.clampedStart(id: chapter.id,
            proposed: scale.time(forX: x + scrollX - (grabOffset ?? 0)),
            chapters: chapters, duration: scale.duration)
    }
}

/// Full-height playhead drawn as one pin: a soft rounded head above the
/// ruler whose underside flows into the stem through concave fillets. At
/// rest the head is a small tab; hovered or dragged it widens into a
/// readout of the time, then folds back. At the trailing end it turns into
/// a flush flag so the inspector never clips it. The head is the only hit
/// target - everywhere else the overlay passes clicks through to the tracks
/// underneath. The pointer's skim line is drawn here too, so it runs
/// through every lane rather than just the clip strip.
private struct StudioTimelinePlayhead: View {
    let time: TimeInterval
    let chapters: [RecordingChapter]
    let scale: StudioTimelineScale
    let scrollX: CGFloat
    /// The pointer's position while skimming, in viewport points.
    let skimX: CGFloat?
    let showsSkim: Bool
    /// The playhead is being scrubbed from the clips or an empty track; the
    /// head opens into its readout as if it were dragged.
    var isScrubbing = false
    let onScrub: (TimeInterval) -> Void
    let onStep: (Int) -> Void

    @State private var isHovering = false
    @State private var isDragging = false
    @State private var grabOffset: CGFloat?
    @GestureState private var isScrubGestureActive = false

    private enum Metrics {
        static let headSize = CGSize(width: 17, height: 12)
        static let readoutSize = CGSize(width: 56, height: 17)
        static let longReadoutWidth: CGFloat = 70
        static let hitSize = CGSize(width: 28, height: StudioTimelineMetrics.playheadLaneHeight + 4)
        /// Breathing room from the timeline's 16 pt leading padding so the
        /// expanded readout stays inside the window at 0:00.
        static let leadingOverhang: CGFloat = 12
    }

    private static let coordinateSpace = "studio.playheadLane"

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let laneHeight = StudioTimelineMetrics.playheadLaneHeight
            // Viewport space: the playhead overlay never scrolls, it just
            // tracks the scrolled lanes underneath it.
            let x = scale.x(for: time) - scrollX
            let isVisible = x >= -2 && x <= width + 2
            let isExpanded = isHovering || isDragging || isScrubbing
            let head = isExpanded
                ? CGSize(
                    width: time >= 3600 ? Metrics.longReadoutWidth : Metrics.readoutSize.width,
                    height: Metrics.readoutSize.height
                )
                : Metrics.headSize
            // The stem stays on the true time. At the trailing edge the
            // inspector column would clip it, so it stops at the edge and the
            // stem slides across to its trailing side into a flag; at 0:00
            // an expanded readout nudges just enough to clear the window edge.
            let trailingMax = width - head.width / 2
            let leadingMin = min(head.width / 2 - Metrics.leadingOverhang, trailingMax)
            let headX = min(max(x, leadingMin), trailingMax)
            // The head hangs from the top of its lane, so the readout grows
            // downward toward the ruler rather than off the dock.
            let headTop = laneHeight - Metrics.headSize.height - 1

            ZStack(alignment: .topLeading) {
                if showsSkim, let skimX, !isDragging, !isScrubbing,
                   skimX >= 0, skimX <= width {
                    Rectangle()
                        .fill(Color.primary.opacity(0.32))
                        .frame(width: 1, height: max(0, proxy.size.height - laneHeight))
                        .offset(x: skimX - 0.5, y: laneHeight)
                        .allowsHitTesting(false)
                }

                if isVisible, let chapter = RecordingChapterPlanner.current(chapters, at: time, duration: scale.duration) {
                    let gap: CGFloat = 6
                    let headLeading = headX - head.width / 2
                    let headTrailing = headX + head.width / 2
                    let right = max(0, width - headTrailing - gap)
                    let left = max(0, headLeading - gap)
                    let useRight = right >= min(240, left)
                    let labelWidth = min(240, useRight ? right : left)
                    Text(chapter.title)
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(width: labelWidth, height: laneHeight,
                               alignment: useRight ? .leading : .trailing)
                        .offset(x: useRight ? headTrailing + gap : headLeading - gap - labelWidth)
                        .allowsHitTesting(false)
                }

                PlayheadPinShape(
                    headHeight: head.height,
                    stemOffset: x - headX
                )
                .fill(Palette.highlight)
                .shadow(color: .black.opacity(0.28), radius: 1.5, y: 0.5)
                .overlay {
                    if isExpanded {
                        Text(studioPreciseTimecode(time))
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.white)
                            .fixedSize()
                            .frame(width: head.width, height: head.height)
                            .frame(maxHeight: .infinity, alignment: .top)
                            .transition(AnyTransition(.blurReplace))
                    }
                }
                .frame(width: head.width, height: max(0, proxy.size.height - headTop))
                .offset(x: headX - head.width / 2, y: headTop)
                .allowsHitTesting(false)
                .opacity(isVisible ? 1 : 0)

                Color.clear
                    .frame(width: max(Metrics.hitSize.width, head.width), height: Metrics.hitSize.height)
                    .contentShape(Rectangle())
                    .onHover { isHovering = $0 }
                    .pointerStyle(.columnResize)
                    .gesture(
                        DragGesture(
                            minimumDistance: 0,
                            coordinateSpace: .named(Self.coordinateSpace)
                        )
                        .updating($isScrubGestureActive) { _, active, _ in
                            active = true
                        }
                        .onChanged { value in
                            isDragging = true
                            onScrub(scale.playheadDragTime(
                                locationX: value.location.x,
                                startX: value.startLocation.x,
                                stemX: x,
                                grabOffset: &grabOffset,
                                scrollX: scrollX
                            ))
                        }
                        .onEnded { _ in
                            endDrag()
                        }
                    )
                    .onChange(of: isScrubGestureActive) { _, active in
                        if !active { endDrag() }
                    }
                    .onDisappear { endDrag() }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Playhead")
                    .accessibilityValue(studioPreciseTimecode(time))
                    .accessibilityHint("Adjust to step frame by frame.")
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment: onStep(1)
                        case .decrement: onStep(-1)
                        @unknown default: break
                        }
                    }
                    .position(x: headX, y: Metrics.hitSize.height / 2 - 2)
                    .allowsHitTesting(isVisible)
            }
        }
        .coordinateSpace(name: Self.coordinateSpace)
        // Opening into the readout and folding back is the one spring left
        // on the timeline.
        .motion(.morphQuick, value: isHovering || isDragging || isScrubbing)
    }

    private func endDrag() {
        isDragging = false
        grabOffset = nil
    }
}

/// A playhead pin in one outline: a rounded head across the top of the
/// rect, a stem down to the bottom, and concave fillets where the head's
/// underside meets the stem so the two read as a single soft piece. The
/// stem can sit right of centre, up to the head's trailing edge; as it gets
/// there that side's corners close up, so the pin becomes a flag.
private struct PlayheadPinShape: Shape {
    var headHeight: CGFloat
    var stemOffset: CGFloat = 0
    var stemWidth: CGFloat = 2
    var cornerRadius: CGFloat = 4
    var filletRadius: CGFloat = 3.5

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(headHeight, stemOffset) }
        set {
            headHeight = newValue.first
            stemOffset = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let head = min(headHeight, rect.height)
        let corner = min(cornerRadius, head / 2, rect.width / 2)
        let halfStem = stemWidth / 2
        let stemX = min(
            max(rect.midX + stemOffset, rect.minX + corner + halfStem),
            rect.maxX - halfStem
        )
        // Head left between the stem and the trailing edge. The trailing
        // corners shrink with it, reaching square when the stem is flush.
        let trailingRoom = rect.maxX - (stemX + halfStem)
        let trailingCorner = min(corner, trailingRoom)
        // A fillet can't reach past the head's own rounded corners.
        let leadingFillet = max(0, min(
            filletRadius,
            stemX - halfStem - (rect.minX + corner),
            rect.height - head
        ))
        let trailingFillet = max(0, min(
            filletRadius,
            trailingRoom - trailingCorner,
            rect.height - head
        ))
        let headBottom = rect.minY + head

        var path = Path()
        path.move(to: CGPoint(x: rect.minX + corner, y: rect.minY))
        // Under a point of room the lip would read as a notch, so the
        // pin is already a flag.
        if trailingRoom > 1 {
            path.addArc(
                tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
                tangent2End: CGPoint(x: rect.maxX, y: headBottom),
                radius: trailingCorner
            )
            path.addArc(
                tangent1End: CGPoint(x: rect.maxX, y: headBottom),
                tangent2End: CGPoint(x: stemX + halfStem, y: headBottom),
                radius: trailingCorner
            )
            // Underside into the stem's right edge, curving down.
            path.addArc(
                tangent1End: CGPoint(x: stemX + halfStem, y: headBottom),
                tangent2End: CGPoint(x: stemX + halfStem, y: rect.maxY),
                radius: trailingFillet
            )
        } else {
            // Flush: the top edge turns straight down into the stem.
            path.addLine(to: CGPoint(x: stemX + halfStem, y: rect.minY))
        }
        path.addLine(to: CGPoint(x: stemX + halfStem, y: rect.maxY))
        path.addLine(to: CGPoint(x: stemX - halfStem, y: rect.maxY))
        // Back up the stem's left edge and out along the underside.
        path.addArc(
            tangent1End: CGPoint(x: stemX - halfStem, y: headBottom),
            tangent2End: CGPoint(x: rect.minX, y: headBottom),
            radius: leadingFillet
        )
        path.addArc(
            tangent1End: CGPoint(x: rect.minX, y: headBottom),
            tangent2End: CGPoint(x: rect.minX, y: rect.minY),
            radius: corner
        )
        path.addArc(
            tangent1End: CGPoint(x: rect.minX, y: rect.minY),
            tangent2End: CGPoint(x: rect.maxX, y: rect.minY),
            radius: corner
        )
        path.closeSubpath()
        return path
    }
}

/// Absolute-time ruler above the clip lane. The ruler itself never scrolls: it
/// draws only the time span currently on screen, so a deeply zoomed timeline
/// costs the same to render as a fitted one.
private struct StudioTimelineRuler: View {
    let duration: Double
    let pointsPerSecond: CGFloat
    let scrollX: CGFloat

    var body: some View {
        Canvas { context, size in
            guard duration > 0.2, pointsPerSecond > 0, size.width > 60 else { return }

            let step = Self.labelStep(forPointsPerSecond: pointsPerSecond)
            let startTime = max(0, Double(scrollX / pointsPerSecond))
            let endTime = min(duration, Double((scrollX + size.width) / pointsPerSecond))
            let endpointLabel = Self.label(for: duration, step: step)
            var lastLabelMaxX = -CGFloat.greatestFiniteMagnitude

            func x(for time: Double) -> CGFloat {
                CGFloat(time) * pointsPerSecond - scrollX
            }

            /// `anchorX` is the tick position; `trailing` right-aligns the
            /// label onto it instead of centering, which is how the endpoint
            /// label stays inside the viewport.
            func drawLabel(_ text: String, at anchorX: CGFloat, trailing: Bool = false) {
                let label = context.resolve(
                    Text(text)
                        .font(.system(size: 9, weight: .medium).monospacedDigit())
                        .foregroundStyle(Color.secondary)
                )
                let labelSize = label.measure(in: size)
                let labelX = trailing ? anchorX - labelSize.width : anchorX - labelSize.width / 2
                let clampedX = min(max(labelX, 0), max(0, size.width - labelSize.width))
                guard clampedX >= lastLabelMaxX + 8 else { return }
                context.draw(label, in: CGRect(
                    x: clampedX,
                    y: size.height - 5 - labelSize.height,
                    width: labelSize.width,
                    height: labelSize.height
                ))
                lastLabelMaxX = clampedX + labelSize.width
            }

            var index = max(0, Int(floor(startTime / step)))
            let lastIndex = Int(ceil(endTime / step))
            while index <= lastIndex {
                let time = Double(index) * step
                index += 1
                guard time <= duration else { break }
                let tickX = x(for: time)

                context.fill(
                    Path(CGRect(x: tickX - 0.5, y: size.height - 4, width: 1, height: 4)),
                    with: .color(.primary.opacity(0.30))
                )

                let minorTime = time + step / 2
                if minorTime < duration {
                    context.fill(
                        Path(CGRect(
                            x: x(for: minorTime) - 0.5,
                            y: size.height - 2.5,
                            width: 1,
                            height: 2.5
                        )),
                        with: .color(.primary.opacity(0.16))
                    )
                }

                // The start needs no label: the playhead parks over it, and
                // the lane's leading edge already says where the cut begins.
                guard time > 0 else { continue }

                // A final whole-second tick can format identically to a
                // fractional endpoint (for example 4.2 -> 0:04). Let the
                // actual endpoint own that label.
                let timeLabel = Self.label(for: time, step: step)
                if timeLabel != endpointLabel {
                    drawLabel(timeLabel, at: tickX)
                }
            }

            // The end of the recording always gets a tick, right-aligned when
            // it lands at the trailing edge of the viewport.
            let endpointX = x(for: duration)
            if endpointX >= -1, endpointX <= size.width + 1 {
                context.fill(
                    Path(CGRect(
                        x: min(endpointX, size.width - 0.5) - 0.5,
                        y: size.height - 4,
                        width: 1,
                        height: 4
                    )),
                    with: .color(.primary.opacity(0.30))
                )
                drawLabel(endpointLabel, at: endpointX, trailing: true)
            }
        }
    }

    /// Smallest "nice" interval whose labels stay comfortably apart at the
    /// current scale. Sub-second steps unlock once a zoomed lane spreads a
    /// single second across most of the viewport.
    private static func labelStep(forPointsPerSecond pointsPerSecond: CGFloat) -> Double {
        let candidates: [Double] = [
            0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1800
        ]
        for candidate in candidates where CGFloat(candidate) * pointsPerSecond >= 64 {
            return candidate
        }
        return candidates.last ?? 60
    }

    private static func label(for time: Double, step: Double) -> String {
        step < 1 ? studioPreciseTimecode(time) : studioTimecode(time)
    }
}

/// Frame around the zoom lane. It stays pinned to the viewport while the cue
/// blocks scroll inside it, so the lane reads as a fixed track no matter how
/// far the timeline is zoomed.
private struct StudioZoomLaneBackground: View {
    /// An empty lane explains itself instead of reading as dead space.
    var showsHint = false

    var body: some View {
        RoundedRectangle(
            cornerRadius: StudioBlockMetrics.cornerRadius + StudioBlockMetrics.inset,
            style: .continuous
        )
            .fill(Color.primary.opacity(0.055))
            .overlay {
                if showsHint {
                    Label("Drag here to add a zoom", systemImage: "plus.viewfinder")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
            .allowsHitTesting(false)
    }
}

/// Zoom cues. Dragging across empty track draws out a zoom in the gap it
/// started in; a click scrubs. Recorded clicks mark the track's floor.
private struct StudioZoomLane: View {
    @Bindable var model: RecordingStudioModel
    let scale: StudioTimelineScale
    let visibleRange: ClosedRange<TimeInterval>
    var onScrubbing: ((Bool) -> Void)?

    var body: some View {
        let blocks = model.zoomTimelineBlocks
        StudioBlockLane(
            model: model,
            blocks: visibleBlocks(of: blocks),
            selectedID: model.selectedCueID,
            scale: scale,
            height: StudioTimelineMetrics.zoomLaneHeight,
            overlap: .forbidden(spans: model.zoomOverlapSpans),
            empty: .create(tint: Palette.highlight, minimumLength: ZoomCue.minimumDuration) { range in
                model.addZoomCue(overEditorRange: range)
            },
            onScrubbing: onScrubbing,
            actions: StudioBlockLaneActions(
                select: { model.selectZoomCue(id: $0.id) },
                begin: { _ in model.beginZoomCueEdit() },
                edit: apply,
                end: { kind in model.endZoomCueEdit(actionName: kind == .move ? "Move Zoom" : "Resize Zoom") }
            ),
            decoration: { pressMarks },
            content: { block, state in content(for: block, state: state) },
            menu: { block in menu(for: block.item) },
            help: { block in
                block.item.isEnabled
                    ? "Drag to move, drag an end to resize, right-click for options"
                    : "Turned off. Right-click to turn it back on."
            },
            accessibility: { block in accessibility(for: block) }
        )
        .opacity(model.zoomEnabled ? 1 : 0.45)
        .contextMenu {
            Button("Add Zoom at Playhead", systemImage: "plus.viewfinder") {
                model.addZoomCue(at: model.currentTime)
            }
        }
    }

    /// Recorded clicks as small dots along the track's floor, so they mark
    /// where Auto Zoom would act without striping the blocks. Culled to the
    /// visible span: an hour-long take can hold thousands of clicks.
    private var pressMarks: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(visiblePressTimes.enumerated()), id: \.offset) { _, pressTime in
                Circle()
                    .fill(Color.primary.opacity(0.28))
                    .frame(width: 3, height: 3)
                    .offset(
                        x: scale.x(for: pressTime) - 1.5,
                        y: StudioTimelineMetrics.zoomLaneHeight - StudioBlockMetrics.inset - 3
                    )
            }
        }
    }

    @ViewBuilder
    private func content(for block: StudioLaneBlock<ZoomCue>, state: StudioBlockState) -> some View {
        let cue = block.item
        StudioBlockLabel(
            systemImage: cue.anchorMode == .pinnedAnchor ? "scope" : "viewfinder",
            title: cue.isEnabled
                ? InspectorValueFormat.magnification(fractionDigits: 1).displayString(for: cue.zoom)
                : "Off",
            // Following the pointer is the default, so only a zoom that
            // does something else says so, ahead of its length.
            detail: (cue.isEnabled && cue.anchorMode != .pointerAnchor ? "\(cue.anchorMode.inspectorTitle) · " : "")
                + studioClock(block.editorLength),
            state: state,
            color: cue.isEnabled ? StudioBlockStyle.zoom.onTint : .secondary
        )
        .background {
            if cue.isEnabled {
                StudioBlockSurface(fill: StudioBlockStyle.zoom.fill(isHovering: state.isHovered))
            } else {
                // Hatched, so a turned-off zoom reads as "kept, not used".
                StudioBlockSurface(fill: Color.primary.opacity(0.08))
                    .overlay { StudioBlockHatch(color: .primary.opacity(0.10)) }
            }
        }
    }

    private func accessibility(for block: StudioLaneBlock<ZoomCue>) -> StudioBlockAccessibility {
        let cue = block.item
        let label = if cue.isEnabled {
            "Zoom \(InspectorValueFormat.magnification(fractionDigits: 1).displayString(for: cue.zoom)), \(cue.anchorMode.inspectorTitle)"
        } else {
            "Zoom, Off"
        }
        let range = "\(studioPreciseTimecode(block.editorStart)) to \(studioPreciseTimecode(block.editorEnd))"
        let value = model.zoomEnabled ? range : "\(range), zooms off"
        return StudioBlockAccessibility(label: label, value: value)
    }

    private func apply(_ edit: StudioBlockEdit<ZoomCue>) {
        let base = edit.base
        var cue = base.item
        switch edit.kind {
        case .move:
            let range = studioMovedSourceRange(
                model: model,
                editorStart: base.editorStart + edit.delta,
                editorLength: base.editorLength
            )
            cue.start = range.start
            cue.end = range.end
            model.moveZoomCue(cue)
        case .trimLeading:
            let source = studioSourceStart(atEditorTime: base.editorStart + edit.delta, in: model.clipTimeline)
            cue.start = min(max(0, source), base.item.end - ZoomCue.minimumDuration)
            model.updateZoomCue(cue)
        case .trimTrailing:
            let source = studioSourceEnd(atEditorTime: base.editorEnd + edit.delta, in: model.clipTimeline)
            cue.end = max(base.item.start + ZoomCue.minimumDuration, min(model.sourceDuration, source))
            model.updateZoomCue(cue)
        }
    }

    @ViewBuilder
    private func menu(for cue: ZoomCue) -> some View {
        Menu("Zoom Level") {
            ForEach(Self.zoomPresets, id: \.self) { preset in
                Toggle(
                    String(format: "%g×", preset),
                    isOn: Binding(
                        get: { abs(cue.zoom - preset) < 0.01 },
                        set: { _ in edit(cue, action: "Change Zoom Level") { $0.zoom = preset } }
                    )
                )
            }
        }

        Menu("Camera Focus") {
            ForEach(ZoomAnchorMode.allCases, id: \.self) { mode in
                Toggle(
                    mode.inspectorTitle,
                    isOn: Binding(
                        get: { cue.anchorMode == mode },
                        set: { _ in
                            edit(cue, action: "Change Camera Focus") { updated in
                                updated.anchorMode = mode
                                if mode == .pinnedAnchor,
                                   let pointer = model.pointerLocation(at: model.currentTime) {
                                    updated.pinnedPoint = pointer
                                }
                            }
                        }
                    )
                )
            }
        }

        Divider()

        Button(cue.isEnabled ? "Turn Off This Zoom" : "Turn On This Zoom",
               systemImage: cue.isEnabled ? "eye.slash" : "eye") {
            edit(cue, action: cue.isEnabled ? "Turn Off Zoom" : "Turn On Zoom") {
                $0.isEnabled.toggle()
            }
        }

        Button("Remove Zoom", systemImage: "trash", role: .destructive) {
            model.removeZoomCue(id: cue.id)
        }
    }

    /// Magnifications offered from a block's context menu.
    private static let zoomPresets: [Double] = [1.25, 1.5, 2, 2.5, 3]

    /// One undoable change to a zoom from its context menu.
    private func edit(_ cue: ZoomCue, action: String, _ change: (inout ZoomCue) -> Void) {
        var updated = cue
        change(&updated)
        model.beginZoomCueEdit()
        model.updateZoomCue(updated)
        model.endZoomCueEdit(actionName: action)
    }

    private var visiblePressTimes: [TimeInterval] {
        model.visibleRecordedPressTimes.filter { visibleRange.contains($0) }
    }

    private func visibleBlocks(of blocks: [RecordingZoomTimelineBlock]) -> [StudioLaneBlock<ZoomCue>] {
        blocks
            .filter { $0.editorEnd >= visibleRange.lowerBound && $0.editorStart <= visibleRange.upperBound }
            .map { StudioLaneBlock(item: $0.cue, editorStart: $0.editorStart, editorEnd: $0.editorEnd) }
    }
}

// MARK: - Inspector

private extension ZoomAnchorMode {
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

private struct StudioInspector: View {
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

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
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
            .frame(maxWidth: .infinity, alignment: .topLeading)
            // The Revert To bar keeps clear of the preview peek pill itself;
            // without the bar (a plain movie), the end of the list must.
            .padding(.top, floatingChrome ? -6 : 0)
            .padding(.bottom, model.isProject ? 12 : PreviewPeekTab.pillHeight * 1.1)
            }
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
            // A silent recording has nothing to send out, but it can still
            // be given a soundtrack - so only the export half is withheld.
            if model.hasRecordedAudio || model.hasReplacementAudio {
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
                        ? "Swap in an audio file, aligned to the start of the edited timeline"
                        : "Lay an audio file over this silent recording"
                )
            }

            if let replacement = model.replacementAudio {
                replacementChip(for: replacement)
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
                StudioAudioExportOptions(format: $model.audioExportFormat) {
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
