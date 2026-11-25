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
    @State private var studioWindow = WeakWindow()
    @State private var isOpen = true

    var body: some View {
        Group {
            if !isOpen {
                Color.clear
            } else if let model {
                RecordingStudioContent(model: model)
            } else {
                ProgressView()
                    .frame(minWidth: 900, minHeight: 600)
            }
        }
        .modifier(CaptureLibraryEditorRegistration(url: isOpen ? url : nil))
        .task(id: isOpen ? url : nil) {
            guard isOpen, let url, !Task.isCancelled else { return }
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
        .onAppear { isOpen = true }
        .onWindowChange { studioWindow.window = $0 }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            guard let closing = notification.object as? NSWindow, closing === studioWindow.window else { return }
            isOpen = false
            releaseModel()
        }
        .onDisappear { releaseModel() }
    }

    private func releaseModel() {
        model?.teardown()
        model = nil
    }
}

private struct RecordingStudioContent: View {
    private static let minimumWidth: CGFloat = 980

    @Bindable var model: RecordingStudioModel
    @State private var isInspectorPresented = true
    @State private var closeGuard = EditorCloseGuard()
    @State private var confirmsSharedLinkDeletion = false
    @FloatingGlassChrome private var floatingChrome
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
                if model.isReadOnlyNewerFormat {
                    HStack(spacing: 8) {
                        Image(systemName: "lock.fill")
                            .foregroundStyle(.secondary)
                        Text(RecordingEditDocument.newerFormatNotice)
                    }
                    .font(.callout)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.12))
                }
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
                if !model.missingVideoClipFiles.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Some imported video clips are missing from this project. Remove the missing clip or restore its file before exporting.")
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
        .sheet(item: $model.pendingRecordingImport) { pending in
            StudioRecordingImportSheet(
                pending: pending,
                onConfirm: { model.confirmPendingRecordingImport(mode: $0) },
                onCancel: { model.cancelPendingRecordingImport() }
            )
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
                    onRename: model.isProject && !model.isReadOnlyNewerFormat ? { model.rename(to: $0) } : nil
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
                    if let progress = model.videoImportProgress {
                        SharePill(stage: "Rendering Clip", progress: progress, cancelLabel: "Cancel Import") {
                            model.cancelVideoImport()
                        }
                    }

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
                .disabled(model.isReadOnlyNewerFormat)
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
            hasSidebar: false,
            sidebarVisible: false,
            inspectorVisible: isInspectorPresented,
            metrics: $glassMetrics
        )
        .navigationTitle(windowTitle)
        .navigationSubtitle(windowSubtitle)
        .onWindowChange { window in
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
        .focusedSceneValue(\.recordingStudio, WeakReference(model))
        .commandPaletteContext {
            .studio(StudioPaletteHooks(model: model, inspectorShown: { isInspectorPresented },
                                       toggleInspector: { isInspectorPresented.toggle() }))
        }
        .background {
            StudioKeyCommands(model: model)
        }
        .onDeleteCommand {
            model.deleteSelection()
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

    /// The command palette's request for this toolbar popover, if it's the last one made.
    private func requested(_ kind: StudioPaletteRequest.Kind) -> UUID? {
        model.paletteRequest?.kind == kind ? model.paletteRequest?.id : nil
    }

    /// Share pipeline in one toolbar slot: render → upload → link copied.
    /// The upload leg reads the uploader's live progress so the pill keeps
    /// moving through both stages.
    @ViewBuilder
    private var shareStatus: some View {
        switch model.shareState {
        case .idle:
            CloudUploadButton(suggestedTitle: shareSuggestedTitle, encryptionUnavailable: CloudShareSeal.unavailableNote,
                              messageSource: shareMessageSource, openRequest: requested(.uploadOptions),
                              onUpload: { model.shareToCloud(options: $0) }) {
                Label("Upload", systemImage: "icloud.and.arrow.up")
                    .labelStyle(.titleAndIcon)
            }
            .disabled(model.uploadUnavailableReason != nil)
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
                                  messageSource: shareMessageSource, openRequest: requested(.uploadOptions),
                                  onUpload: { model.shareToCloud(options: $0) }) {
                    Text("Retry")
                }
                .disabled(model.uploadUnavailableReason != nil)
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
                openRequest: requested(.exportOptions),
                onExport: model.export(settings:)
            ) {
                Label("Export", systemImage: "arrow.down.circle")
                    .labelStyle(.titleAndIcon)
            }
            // As export() refuses, and the command palette says why (Sol's second review).
            .disabled(model.exportUnavailableReason != nil)
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
                    openRequest: requested(.exportOptions),
                    onExport: model.export(settings:)
                ) {
                    Image(systemName: "arrow.down.circle")
                }
                .help("Export Again")
                .disabled(model.exportUnavailableReason != nil)
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
                    openRequest: requested(.exportOptions),
                    onExport: model.export(settings:)
                ) {
                    Text("Retry")
                }
                .disabled(model.exportUnavailableReason != nil)
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
struct BouncingCheck: View {
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
    @Entry var recordingStudio: WeakReference<RecordingStudioModel>?
}

/// File › Save for the key Studio window, disabled when clean. Only there
/// for a recording project while Studio is focused, as with the image
/// editor's Save. It is also a new recording's first save; after that the
/// project saves at a pause.
struct RecordingStudioSaveCommand: View {
    @FocusedValue(\.recordingStudio) private var studioReference

    var body: some View {
        if let studioReference, let studio = studioReference.value, studio.isProject {
            Button("Save") { studioReference.value?.saveProject() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!studio.hasUnsavedChanges)
        }
    }
}

struct RecordingStudioAgentPromptCommand: View {
    @FocusedValue(\.recordingStudio) private var studioReference

    var body: some View {
        if let studioReference, let studio = studioReference.value {
            Group {
                Button("Export Bug Report") { studioReference.value?.exportAgentPrompt() }
                if studio.session != nil {
                    Button("Export How-To Guide") { studioReference.value?.exportGuide() }
                }
            }
            .disabled(!studio.isLoaded || studio.hasRunningWork || studio.hasUnreadableDraft || studio.isReadOnlyNewerFormat || studio.transcriptionState.isTranscribing)
        }
    }
}

/// File › Revert To for the key Studio project. Each is one step Undo
/// takes back; the project then saves as after any edit.
struct RecordingStudioRevertCommand: View {
    @FocusedValue(\.recordingStudio) private var studioReference

    var body: some View {
        if let studioReference, let studio = studioReference.value, studio.isProject {
            Menu("Revert To") {
                RecordingStudioRevertItems(studioReference: studioReference)
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
                .disabled(!model.isLoaded || model.exportState.isExporting || model.isImportingVideoClip)
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

                let cutawayCoverage = isEditingVideoCrop ? 0 : model.cutawayCoverage(atEditorTime: model.displayTime)
                if model.isCameraVisible(at: model.displayTime), layout.bubbleRect.width > 0, cutawayCoverage < 0.999 {
                    StudioCameraBubble(model: model, layout: layout)
                        .opacity(1 - cutawayCoverage)
                        .allowsHitTesting(cutawayCoverage < 0.5)
                }

                // Layered video overlay (PiP or cutaway) sits above card and
                // camera, and under images, text, and subtitles.
                if !isEditingVideoCrop, let videoOverlay = model.activeVideoOverlay(atEditorTime: model.displayTime) {
                    StudioVideoOverlayCanvasView(
                        overlay: videoOverlay,
                        player: model.videoOverlayPlayer,
                        editorTime: model.displayTime,
                        canvasSize: canvasSize,
                        layout: layout
                    )
                }

                // Images, then text, sit on the canvas above the camera and
                // under the subtitles, matching the exporter's draw order.
                if !isEditingVideoCrop {
                    let texts = model.texts(atEditorTime: model.displayTime)
                    let images = overlayImages
                    if !texts.isEmpty || !images.isEmpty {
                        StudioCanvasOverlayLayer(
                            images: images,
                            texts: texts,
                            sourceTime: model.sourceTime(atEditorTime: model.displayTime),
                            canvasSize: canvasSize,
                            onImageFrameDecoded: { [weak model] in
                                model?.notifyOverlayFrameDecoded()
                            }
                        )
                    }
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

                // Redactions, images, and texts can be picked and arranged
                // while paused; while playing, clicking the picture still pauses.
                if !isEditingVideoCrop, !model.isPlaying, zoomTarget == nil {
                    let regions = model.redactions(atEditorTime: model.displayTime)
                    if !regions.isEmpty {
                        StudioRedactionEditingLayer(
                            model: model,
                            redactions: regions,
                            pictureRect: layout.frameRect(for: state),
                            canvasSize: canvasSize
                        )
                    }
                    if let videoOverlay = model.activeVideoOverlay(atEditorTime: model.displayTime),
                       videoOverlay.presentation == .pip {
                        StudioVideoOverlayEditingLayer(
                            model: model,
                            overlay: videoOverlay,
                            canvasSize: canvasSize
                        )
                    }
                    let images = model.images(atEditorTime: model.displayTime)
                    if !images.isEmpty {
                        StudioImageEditingLayer(model: model, images: images, canvasSize: canvasSize)
                    }
                    let texts = model.texts(atEditorTime: model.displayTime)
                    if !texts.isEmpty {
                        StudioTextEditingLayer(model: model, texts: texts, canvasSize: canvasSize)
                    }
                }
            }
            .frame(width: canvasSize.width, height: canvasSize.height)
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
    }

    /// Active images whose decoded frames are already in memory. Reading
    /// `overlayImageRevision` ensures newly decoded images redraw right away.
    private var overlayImages: [(overlay: RecordingImageOverlay, image: RecordingOverlayImage)] {
        _ = model.overlayImageRevision
        return model.images(atEditorTime: model.displayTime).compactMap { overlay in
            guard let url = model.overlayImageURL(for: overlay),
                  let image = model.overlayImages.cachedImage(at: url) else { return nil }
            return (overlay, image)
        }
    }

    /// The selected zoom, shown as a target on the paused canvas.
    private var zoomTargetCue: ZoomCue? {
        guard !isEditingVideoCrop,
              !model.isPlaying,
              model.zoomEnabled,
              model.isPrimaryRecording(at: model.displayTime),
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

/// Renders the active layered video overlay (PiP or full-card cutaway) on the
/// live preview canvas, matching `RecordingVideoOverlayRenderer`'s geometry,
/// opacity, crossfades, and corner clipping verbatim.
private struct StudioVideoOverlayCanvasView: View {
    let overlay: RecordingVideoOverlay
    let player: AVPlayer
    let editorTime: TimeInterval
    let canvasSize: CGSize
    let layout: RecordingStudioLayout

    var body: some View {
        let alpha = overlay.effectiveOpacity(atEditorTime: editorTime)
        if alpha > 0.001 {
            switch overlay.presentation {
            case .pip:
                let rect = overlay.pipRect(canvasSize: canvasSize)
                let unit = min(canvasSize.width, canvasSize.height) / 1080
                let radius = min(CGFloat(overlay.cornerRadius) * unit, rect.width / 2, rect.height / 2)
                let strength = CGFloat(min(max(overlay.shadow, 0), 1))
                StudioPlayerLayerView(player: player, gravity: .resizeAspectFill)
                    .frame(width: max(rect.width, 1), height: max(rect.height, 1))
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                    .rotationEffect(.degrees(overlay.rotation))
                    .shadow(
                        color: .black.opacity(0.5 * strength),
                        radius: 20 * unit * strength,
                        y: 12 * unit * strength
                    )
                    .opacity(alpha)
                    .position(x: rect.midX, y: rect.midY)
                    .allowsHitTesting(false)
            case .cutaway:
                let gravity: AVLayerVideoGravity = overlay.cutawayContentMode == .fill
                    ? .resizeAspectFill
                    : .resizeAspect
                // Paint letterbox backing on the single AVPlayerLayer so `.opacity(alpha)`
                // dissolves the cutaway and backing once instead of double-fading.
                StudioPlayerLayerView(player: player, gravity: gravity, backgroundColor: .black)
                    .frame(width: layout.cardRect.width, height: layout.cardRect.height)
                    .clipShape(RoundedRectangle(cornerRadius: layout.cardCornerRadius, style: .continuous))
                    .opacity(alpha)
                    .position(x: layout.cardRect.midX, y: layout.cardRect.midY)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// AVPlayerLayer host for the preview canvas.
private struct StudioPlayerLayerView: NSViewRepresentable {
    let player: AVPlayer
    let gravity: AVLayerVideoGravity
    var backgroundColor: CGColor? = nil

    func makeNSView(context: Context) -> StudioPlayerContainerView {
        let view = StudioPlayerContainerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = gravity
        view.playerLayer.backgroundColor = backgroundColor
        return view
    }

    func updateNSView(_ nsView: StudioPlayerContainerView, context: Context) {
        if nsView.playerLayer.player !== player {
            nsView.playerLayer.player = player
        }
        nsView.playerLayer.videoGravity = gravity
        if nsView.playerLayer.backgroundColor != backgroundColor {
            nsView.playerLayer.backgroundColor = backgroundColor
        }
    }

    static func dismantleNSView(_ nsView: StudioPlayerContainerView, coordinator: ()) {
        nsView.playerLayer.player = nil
    }
}

final class StudioPlayerContainerView: NSView {
    let playerLayer = AVPlayerLayer()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        let rootLayer = CALayer()
        rootLayer.allowsGroupOpacity = true
        layer = rootLayer
        playerLayer.frame = bounds
        rootLayer.addSublayer(playerLayer)
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

/// Asks whether to insert a Sukusho recording's raw screen capture (framed
/// inside this project) or its finished movie (with zooms, camera, and
/// overlays baked in). Defaults to Raw recording.
private struct StudioRecordingImportSheet: View {
    let pending: RecordingStudioModel.PendingRecordingImport
    let onConfirm: (StudioVideoClipImport.SukushoRecordingMode) -> Void
    let onCancel: () -> Void

    @State private var selection: StudioVideoClipImport.SukushoRecordingMode = .rawRecording

    private var titleText: String {
        pending.recordingNames.count == 1
            ? "Add Sukusho Recording"
            : "Add \(pending.recordingNames.count) Sukusho Recordings"
    }

    private var subtitleText: String {
        if pending.recordingNames.count == 1, let name = pending.recordingNames.first {
            return "Choose how to insert “\(name)” into this timeline."
        }
        return "Choose how to insert these recordings into this timeline."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(titleText)
                    .font(.headline)
                Text(subtitleText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 10) {
                optionCard(
                    mode: .rawRecording,
                    title: "Raw recording",
                    detail: "Your screen recording only, with its redactions, in this project's framing.",
                    systemImage: "video"
                )
                if pending.canImportFinished {
                    optionCard(
                        mode: .finishedMovie,
                        title: "Finished movie",
                        detail: "Bakes in that recording's zooms, camera bubble, and overlays. Renders on the spot if needed.",
                        systemImage: "sparkles.tv"
                    )
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    onConfirm(selection)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func optionCard(
        mode: StudioVideoClipImport.SukushoRecordingMode,
        title: String,
        detail: String,
        systemImage: String
    ) -> some View {
        let isSelected = selection == mode
        return Button {
            selection = mode
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Image(systemName: systemImage)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                    }
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.accentColor.opacity(0.65) : Color.primary.opacity(0.10),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
