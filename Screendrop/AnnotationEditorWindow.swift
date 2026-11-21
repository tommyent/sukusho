//
//  AnnotationEditorWindow.swift
//  Screendrop
//
//  Created by Codex on 27/04/26.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AnnotationEditorWindow: View {
    @Binding var url: URL?

    @State private var model = AnnotationEditorModel()
    @State private var probe = PixelProbe()
    @State private var wallpaperStore = AnnotationWallpaperStore.shared
    @State private var backgroundPresetStore = AnnotationBackgroundPresetStore.shared
    private static let inspectorKey = "annotationEditor.inspectorVisible"
    @State private var isInspectorPresented = InspectorVisibilityStore.initial(forKey: inspectorKey)

    private var inspectorChoice: Binding<Bool> {
        InspectorVisibilityStore.binding($isInspectorPresented, key: Self.inspectorKey)
    }
    @State private var isFinishing = false
    @State private var isSaving = false
    @State private var isUploading = false
    /// No close-button dot: Apple's HIG says that with autosave on, a dot
    /// implies people must act to keep their work. The subtitle says it instead.
    @State private var closeGuard = EditorCloseGuard()
    /// The uploaded link, until the next edit brings Upload back.
    @State private var copiedLink: String?
    /// Found once per load: matching by URL probes each recording on disk,
    /// and the title is read on every edit.
    @State private var historyID: UUID?
    @FocusState private var focusedField: AnnotationEditorFocusedField?
    @Environment(\.dismiss) private var dismissWindow
    @FloatingGlassChrome private var floatingChrome
    @State private var editorWindow: NSWindow?
    @State private var handledInitialWindowPlacement = false
    @State private var glassMetrics = GlassWindowButtonMetrics.fallback

    /// What the tool dock needs, and so the narrowest the window goes.
    static let minimumWidth: CGFloat = 712

    private var isBusy: Bool { isSaving || isFinishing || isUploading || model.isBlockingCommit }

    var body: some View {
        mainContent
            .background {
                if floatingChrome {
                    AnnotationEditorWorkspaceBackground()
                        .backgroundExtensionEffect()
                        .ignoresSafeArea()
                }
            }
            .disabled(model.isBlockingCommit)
            .allowsHitTesting(!model.isBlockingCommit)
            // The capture an outside file became on its first save, so the Library can't trash it under the editor.
            .modifier(CaptureLibraryEditorRegistration(url: model.sourceURL ?? url))
            .navigationTitle(windowTitle)
            .navigationSubtitle(model.saveStatus)
            .toolbar(removing: .title)
            .toolbarBackgroundVisibility(floatingChrome ? .hidden : .visible, for: .windowToolbar)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    AnnotationEditorTitle(
                        title: windowTitle,
                        status: model.saveStatus,
                        customName: historyItem?.displayName,
                        defaultName: historyItem.map(automaticTitle) ?? windowTitle,
                        onRename: historyItem.map { item in { AnnotationEditorTitle.rename(item, to: $0) } }
                    )
                        .id(historyID)
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarSpacer(.flexible, placement: .primaryAction)
                ToolbarItemGroup(placement: .primaryAction) {
                    // Crop's options are in the inspector's tool slot; with the
                    // inspector hidden they stay here.
                    if model.isCropping {
                        if !isInspectorPresented { cropActions }
                    } else {
                        editingActions.disabled(isBusy)
                    }
                }
                // Bare icons, as in the Library and the Studio: no glass capsule.
                .sharedBackgroundVisibility(.hidden)
            }
            .onChange(of: model.sourceURL) { _, new in
                if let new, historyID == nil { historyID = ScreenshotHistoryStore.shared.item(for: new)?.id }
            }
            .task(id: url) {
                historyID = url.flatMap { ScreenshotHistoryStore.shared.item(for: $0)?.id }
                clearInspectorFocus()
                model.load(url: url, dismiss: dismissWindow)
            }
            .onAppear {
                Task { await wallpaperStore.reload() }
                AnnotationEditorActivationPolicy.enter(hidePreview: true)
            }
            .onDisappear {
                closeGuard.detach()
                probe.release()
                model.releaseEditorResources()
                AnnotationEditorActivationPolicy.leave(restorePreview: true)
            }
            .onWindowChange { window in
                editorWindow = window
                guard let window else {
                    handledInitialWindowPlacement = false
                    closeGuard.detach()
                    return
                }
                if !handledInitialWindowPlacement {
                    DispatchQueue.main.async {
                        guard editorWindow === window, !handledInitialWindowPlacement else { return }
                        handledInitialWindowPlacement = true
                    }
                }
                model.allowsIdleSave = { [weak window] in
                    guard let window else { return false }
                    return Self.allowsIdleSave(in: window, keyWindow: NSApp.keyWindow)
                }
                configureCloseGuard()
                closeGuard.attach(to: window)
                // As the Library does: Sukusho's own screenshots leave the editor out unless
                // "Include Sukusho windows" is on; other apps still see it (Astra E2).
                PreviewWindowCaptureExclusion.shared.register(window: window)
            }
            // Saves at a pause, so History and the Library keep up without a
            // Save button. Not on resign key: the editor's own popovers take
            // key (the Unsplash search, a style's name) but never main.
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignMainNotification)) { note in
                if let window = note.object as? NSWindow, window.delegate === closeGuard { saveAtPause(in: window) }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                if let window = NSApp.windows.first(where: { $0.delegate === closeGuard }) { saveAtPause(in: window) }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
                if let window = note.object as? NSWindow, window.delegate === closeGuard {
                    model.scheduleIdleSave()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSControl.textDidEndEditingNotification)) { note in
                if let control = note.object as? NSView, control.window?.delegate === closeGuard {
                    model.scheduleIdleSave()
                }
            }
            .onChange(of: focusedField) { _, _ in model.scheduleIdleSave() }
            .onDeleteCommand {
                if !model.isBlockingCommit { model.deleteSelectedAnnotation() }
            }
            .onChange(of: model.isCropping) { _, isCropping in
                if isCropping {
                    probe.isPicking = false
                    probe.isMeasuringTool = false
                }
            }
            // An edit brings Upload back; hovering or selecting a shape doesn't.
            .onChange(of: model.editState) { _, _ in
                if copiedLink != nil { withAnimation(.snappy(duration: 0.2)) { copiedLink = nil } }
            }
            .focusedSceneValue(\.annotationEditor, model)
            .focusedSceneValue(\.annotationEditorSelectTool) { tool in
                clearInspectorFocus()
                probe.isPicking = false
                probe.isMeasuringTool = false
                model.selectTool(tool)
            }
            .onChange(of: model.saveAsRequest) { _, _ in saveAs() }
            .onChange(of: model.saveRequest) { _, _ in saveEdits() }
            // The pixels under the pointer come from the base image, so they
            // are read again whenever a crop or its undo replaces it.
            .task(id: model.previewCGImage.map(ObjectIdentifier.init)) {
                await probe.load(model.baseImageURL, preview: model.previewCGImage)
            }
            .background(AnnotationKeyCommandHandler(
                isEnabled: { !model.isBlockingCommit },
                onDelete: model.deleteSelectedAnnotation,
                onSave: saveEdits,
                onCopy: {
                    if !model.copySelectedAnnotations() { copyAndFinishEditing() }
                },
                onCopyOriginal: { copyAndFinishEditing(original: true) },
                onUndo: model.undo,
                onRedo: model.redo,
                onSelectAll: model.selectAllAnnotations,
                onSelectTool: { tool in
                    probe.isPicking = false
                    probe.isMeasuringTool = false
                    model.selectTool(tool)
                },
                onZoomIn: model.zoomIn,
                onZoomOut: model.zoomOut,
                onStepTextSize: { direction in
                    if model.canStepTextSize { model.stepTextSize(by: direction) }
                },
                onFitCanvas: model.fitCanvas,
                onActualSize: { model.setZoomPercent(100) },
                onToggleCrop: { withAnimation(.canvasMoveIfAllowed) { model.toggleCropping() } },
                onApplyCrop: applyCropAction,
                onCancelCrop: { withAnimation(.canvasMoveIfAllowed) { model.cancelCrop() } },
                onNudgeCrop: model.nudgeCrop(by:),
                isCropping: { model.isCropping },
                onCopyColor: probe.copyHovered,
                onPaste: {
                    guard model.paste() else { return false }
                    probe.isPicking = false
                    probe.isMeasuringTool = false
                    return true
                },
                onMeasure: probe.measure,
                // Points of the image, as the ruler measures them.
                onNudge: { step in
                    model.nudgeSelection(dx: step.dx * probe.pixelsPerPoint, dy: step.dy * probe.pixelsPerPoint)
                },
                onEscape: {
                    if EditorPopovers.closeNewest() { return }
                    if probe.isPicking || probe.isMeasuringTool {
                        probe.isPicking = false
                        probe.isMeasuringTool = false
                    } else {
                        model.escapeSelectionOrDisarm()
                    }
                }
            ))
            .inspector(isPresented: inspectorChoice) {
                AnnotationEditorInspector(
                    model: model,
                    wallpaperStore: wallpaperStore,
                    backgroundPresetStore: backgroundPresetStore,
                    focusedField: $focusedField,
                    onEditorAction: clearInspectorFocus,
                    onPickWallpaper: pickCustomWallpaper
                )
                .disabled(model.isBlockingCommit)
                .glassInspectorToolbar(enabled: floatingChrome)
            }
            .glassInspectorToggleOverlay(
                enabled: floatingChrome && isInspectorPresented && !model.isCropping,
                isPresented: inspectorChoice,
                metrics: glassMetrics,
                isDisabled: isBusy,
                hasKeyboardShortcut: true,
                onToggle: clearInspectorFocus
            )
            .environment(\.backgroundDestination, .editors)
            .glassWindowChrome(
                window: editorWindow,
                hasSidebar: false,
                sidebarVisible: false,
                inspectorVisible: isInspectorPresented,
                metrics: $glassMetrics
            )
            // Below this the inspector folds away and the window can go down to the canvas's
            // own minimum; it was stuck at 1040 pt with the inspector (Fable #7).
            .inspectorAutoFold(
                isPresented: $isInspectorPresented,
                below: 1000,
                window: handledInitialWindowPlacement ? editorWindow : nil
            )
            .environment(probe)
    }

    // MARK: Toolbar actions

    /// The standard trailing actions shown when not cropping.
    @ViewBuilder
    private var editingActions: some View {
        if let copiedLink {
            Button {
                CloudShareLinks.copy([copiedLink])
            } label: {
                Label("Link Copied", systemImage: "checkmark.icloud")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.green)
                    .padding(.horizontal, 6)
            }
            .help("Copy the share link again")
        } else if CloudUploader.shared.isConfigured {
            CloudUploadButton(
                // The name its Library card shows, as the Library suggests; never the file name.
                suggestedTitle: historyItem == nil ? "" : windowTitle,
                messageSource: ShareMessageSource(isVideo: false),
                onUpload: uploadAnnotation
            ) {
                if isUploading {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Uploading...")
                    }
                    .padding(.horizontal, 6)
                } else {
                    Label("Upload", systemImage: "icloud.and.arrow.up")
                        .labelStyle(.titleAndIcon)
                        .padding(.horizontal, 6)
                }
            }
            .tint(.accentColor)
            .help("Upload to the cloud and copy the link")
            .disabled(isUploading)
        }

        if !floatingChrome || !isInspectorPresented {
            inspectorToggleButton
        }
    }

    private var inspectorToggleButton: some View {
        Button {
            clearInspectorFocus()
            inspectorChoice.wrappedValue.toggle()
        } label: {
            Label(isInspectorPresented ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.right")
                .labelStyle(.iconOnly)
        }
        .keyboardShortcut("i", modifiers: [.command, .option])
        .help(isInspectorPresented ? "Hide Inspector" : "Show Inspector")
    }

    /// The crop controls that replace the trailing actions while cropping.
    @ViewBuilder
    private var cropActions: some View {
        Menu {
            Picker("Aspect Ratio", selection: aspectBinding) {
                ForEach(CropAspectRatio.allCases) { aspect in
                    Text(aspect.title).tag(aspect)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Label(model.cropAspect.title, systemImage: "aspectratio")
                .labelStyle(.titleAndIcon)
        }
        .help("Aspect ratio")

        Button {
            clearInspectorFocus()
            withAnimation(.canvasMoveIfAllowed) { model.resetCrop() }
        } label: {
            Text("Reset").padding(.horizontal, 6)
        }
        .help("Reset the selection to the whole image")

        Button(action: exitCrop) {
            Text("Cancel").padding(.horizontal, 6)
        }
        .keyboardShortcut(.cancelAction)

        Button(action: applyCropAction) {
            Text("Crop").padding(.horizontal, 8)
        }
        .keyboardShortcut(.defaultAction)
    }

    private var aspectBinding: Binding<CropAspectRatio> {
        Binding(
            get: { model.cropAspect },
            set: { newValue in
                clearInspectorFocus()
                withAnimation(.canvasMoveIfAllowed) { model.setCropAspect(newValue) }
            }
        )
    }

    private func enterCrop() {
        clearInspectorFocus()
        withAnimation(.canvasMoveIfAllowed) { model.beginCropping() }
    }

    private func exitCrop() {
        clearInspectorFocus()
        withAnimation(.canvasMoveIfAllowed) { model.cancelCrop() }
    }

    private func applyCropAction() {
        clearInspectorFocus()
        // Not animated: the crop first lands where its box was, and the canvas
        // animates the fit from there (`canvasRevealID`).
        model.applyCrop()
    }

    private var mainContent: some View {
        ZStack {
            if !floatingChrome {
                AnnotationEditorWorkspaceBackground()
            }

            if let previewImage = model.previewImage, model.imageSize != .zero {
                AnnotationCanvas(
                    model: model,
                    image: previewImage,
                    onEditorInteraction: clearInspectorFocus
                )
            } else if let errorMessage = model.errorMessage {
                // A load failure (missing/unreadable source file, e.g. a stale
                // URL replayed by macOS window restoration) should never sit
                // behind an unexplained spinner with no way out.
                AnnotationLoadFailureView(message: errorMessage, onClose: closeAfterLoadFailure)
            } else {
                ProgressView()
                    .controlSize(.large)
            }
        }
        // Keep the canvas minimum steady while the split view adds or removes the inspector.
        .frame(minWidth: Self.minimumWidth, minHeight: 580)
        .clipped()
        .overlay(alignment: .top) {
            if model.previewImage != nil, model.imageSize != .zero {
                AnnotationToolDock(
                    model: model,
                    probe: probe,
                    isDisabled: model.isCropping || isBusy,
                    onSelectTool: { tool in
                        clearInspectorFocus()
                        probe.isPicking = false
                        probe.isMeasuringTool = false
                        model.selectTool(tool)
                    },
                    onCrop: enterCrop
                )
                .padding(.top, AnnotationToolDock.topPadding)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if model.previewImage != nil, model.imageSize != .zero {
                HStack(spacing: 8) {
                    AnnotationZoomControl(model: model)

                    if model.isPreviewDownscaled {
                        LowResolutionPreviewNotice()
                    }
                }
                .padding(.leading, 16)
                .padding(.bottom, 16)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if model.isCropping, model.imageSize != .zero {
                CropResolutionBadge(size: model.cropPixelSize)
                    .padding(.trailing, 16)
                    .padding(.bottom, 16)
                    .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .bottomTrailing)))
            }
        }
        .overlay(alignment: .bottomLeading) {
            // Only inline saves/uploads (which fail with an image already on
            // screen) land here; a load failure shows the full-canvas state
            // above instead of stacking a second copy of the same message.
            if let errorMessage = model.errorMessage, model.previewImage != nil {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(.bar)
            }
        }
    }

    /// The capture's Library title, following a rename made there: its name,
    /// else Apple Intelligence's, else when it was taken. A file outside
    /// History shows its file name.
    private var windowTitle: String {
        guard let url else { return "" }
        guard let item = historyItem else {
            return url.deletingPathExtension().lastPathComponent
        }
        return item.displayName ?? automaticTitle(item)
    }

    /// What clearing the name goes back to, as on its Library card.
    private func automaticTitle(_ item: ScreenshotHistoryItem) -> String {
        CaptureInsightRules.title(customName: nil, modelTitle: CaptureLibraryIndex.shared.visibleInsight(item.id.uuidString)?.title,
                                  sourceTitle: CaptureInsightRules.sourceTitle(appName: item.source?.appName,
                                                                               windowTitle: item.source?.windowTitle),
                                  dateTitle: CaptureLibraryItem.dateTitle(item.createdAt))
    }

    private var historyItem: ScreenshotHistoryItem? {
        ScreenshotHistoryStore.shared.items.first(where: { $0.id == historyID })
    }

    private func closeAfterLoadFailure() {
        model.releaseEditorResources()
        dismissWindow()
    }

    private func saveAs() {
        clearInspectorFocus()
        guard !isBusy, let sourceURL = model.sourceURL else { return }
        do { try model.validateEditDocument() } catch {
            model.errorMessage = error.localizedDescription
            return
        }
        let baseURL = model.baseImageURL ?? sourceURL

        let panel = NSSavePanel()
        panel.allowedContentTypes = [ScreenshotFileActions.exportContentType]
        panel.nameFieldStringValue = ScreenshotFileActions.exportFileName(for: sourceURL)
        panel.canCreateDirectories = true
        panel.title = "Save Annotated Screenshot"

        panel.begin { response in
            guard response == .OK, let destinationURL = panel.url else { return }

            Task {
                do {
                    try await AnnotationRenderer.renderInBackground(
                        sourceURL: baseURL,
                        shapes: model.shapes,
                        bindings: model.bindings,
                        images: model.engine.images,
                        backgroundSettings: model.backgroundSettings,
                        destinationURL: destinationURL,
                        contentType: ScreenshotFileActions.exportContentType
                    )
                } catch {
                    model.errorMessage = "Failed to save annotation: \(error.localizedDescription)"
                }
            }
        }
    }

    private func pickCustomWallpaper() {
        clearInspectorFocus()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = AnnotationWallpaperStore.supportedContentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.title = "Choose Background Wallpaper"

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
                let wallpaper = AnnotationCustomWallpaper(url: file)
                model.backgroundSettings.customWallpaper = wallpaper
                model.backgroundSettings.style = .customWallpaper(wallpaper)
            }
        }
    }

    private func uploadAnnotation(options: CloudUploadOptions) {
        clearInspectorFocus()
        guard model.sourceURL != nil, !isBusy else { return }

        isUploading = true
        Task {
            defer { isUploading = false }
            do {
                // Persist the current annotations first so the uploaded file
                // matches what's saved in history, then upload that file. The
                // editor stays open.
                guard let sourceURL = model.sourceURL else { return }
                let resultURL = try await model.commitEdits() ?? sourceURL
                // The canvas stays editable while the file uploads.
                let uploadedEdits = model.editState

                _ = await ScreenshotPreviewStack.shared.applyAnnotation(
                    originalURL: sourceURL,
                    historyURL: resultURL
                )

                let result = try await CloudUploader.shared.upload(
                    itemID: UUID(),
                    fileURL: resultURL,
                    title: options.trimmedTitleOrNil,
                    socialEnabled: options.socialEnabled,
                    expiresAt: options.expiry.date(),
                    allowAnonymousComments: options.allowAnonymousComments,
                    password: options.password,
                    encrypt: options.encrypted
                )
                CloudShareLinks.copy([result.url], message: options.message)
                ScreenshotHistoryStore.shared.setCloudURL(for: resultURL, cloudURL: result.url)
                // An edit made during the upload isn't in the link: the link is
                // still copied, but Upload stays rather than claiming it's current.
                if model.editState == uploadedEdits {
                    withAnimation(.snappy(duration: 0.2)) { copiedLink = result.url }
                }
            } catch {
                model.errorMessage = "Upload failed: \(error.localizedDescription)"
            }
        }
    }

    /// ⌘S and File › Save: saves now rather than at the next pause.
    private func saveEdits() {
        clearInspectorFocus()
        save()
    }

    /// Leaves focus alone; composition, unfinished interactions and sheets
    /// defer the background snapshot. Closing still saves.
    private func saveAtPause(in window: NSWindow) {
        guard model.canSaveInBackground, window.attachedSheet == nil else { return }
        save(idle: true)
    }

    /// Focus can return to a field editor even when nobody is typing.
    static func allowsIdleSave(in window: NSWindow, keyWindow: NSWindow?) -> Bool {
        let isComposing = (window.firstResponder as? NSTextView)?.hasMarkedText() == true
        let popoverIsComposing = keyWindow?.parent == window
            && (keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() == true
        return !isComposing && !popoverIsComposing && window.attachedSheet == nil
    }

    private func save(idle: Bool = false) {
        // Committing re-renders the composite, so a save with nothing
        // changed should cost nothing.
        guard model.sourceURL != nil, model.hasUnsavedChanges || model.isCommitting, !isBusy else { return }

        if !idle { isSaving = true }
        Task {
            defer { if !idle { isSaving = false } }
            do {
                guard let sourceURL = model.sourceURL,
                      let resultURL = try await model.commitEdits(idle: idle) else { return }
                _ = await ScreenshotPreviewStack.shared.applyAnnotation(
                    originalURL: sourceURL,
                    historyURL: resultURL,
                    updatesClipboard: !idle
                )
            } catch {
                model.errorMessage = "Failed to save annotation: \(error.localizedDescription)"
            }
        }
    }

    /// Cmd-C without a selection: saves, puts the finished image - annotations
    /// included - on the clipboard whatever the auto-copy setting, and closes, for a
    /// capture, mark up, paste loop that never touches the mouse. Nothing waits for
    /// the optimizer: the image is on the clipboard and the window gone as soon as
    /// it is saved, and the optimized copy takes its place in the background.
    private func copyAndFinishEditing(original: Bool = false) {
        clearInspectorFocus()
        guard let sourceURL = model.sourceURL else {
            model.releaseEditorResources()
            dismissWindow()
            return
        }

        guard !isBusy else { return }

        isFinishing = true
        // The copy's turn is taken now, at ⌘C, before the edits are saved: anything copied while they are, here or
        // in another app, is newer, and this copy doesn't land after it (as the Library's selection, Astra round 4).
        let turn = OptimizedImageCopy.shared.takeTurn()
        Task {
            defer { OptimizedImageCopy.shared.finish(turn) }
            do {
                let resultURL = try await model.commitEdits()
                if let resultURL {
                    // Not copied there too: the copy below is the one (auto-copy would make it twice).
                    _ = await ScreenshotPreviewStack.shared.applyAnnotation(
                        originalURL: sourceURL,
                        historyURL: resultURL,
                        updatesClipboard: false
                    )
                }
                // No result means nothing was drawn: the original is the image.
                guard try await ScreenshotFileActions.copyImageToClipboard(from: resultURL ?? sourceURL, original: original,
                                                                           turn: turn) else {
                    // Something newer reached the clipboard while the image was saved or read: nothing was copied, so
                    // the editor stays, edits saved, for another ⌘C.
                    isFinishing = false
                    return
                }
                // The window usually closes, so a toast says the image went to the clipboard.
                let display = ActiveDisplayResolver.activeDisplayID()
                let toast = {
                    CaptureTextFeedbackPresenter.shared.showDone(original ? "Copied Original" : "Copied",
                                                                 detail: "The marked-up screenshot is on the clipboard.",
                                                                 displayID: display)
                }
                guard !model.hasUnsavedChanges else {
                    isFinishing = false
                    toast()
                    return
                }
                // The window goes first; the toast and the clean-up follow it.
                dismissWindow()
                toast()
                model.releaseEditorResources()
            } catch {
                isFinishing = false
                model.errorMessage = "Failed to finish annotation: \(error.localizedDescription)"
            }
        }
    }

    private func configureCloseGuard() {
        closeGuard.savesWithoutAsking = { true }
        closeGuard.hasUnsavedChanges = { [weak model] in
            guard let model else { return false }
            return model.hasUnsavedChanges || model.isCommitting || model.isBlockingCommit
        }
        closeGuard.projectName = { [weak model] in model?.sourceURL?.lastPathComponent ?? "this screenshot" }
        // Capture only the model, not this view and its @State close guard.
        closeGuard.onDecision = { [weak model] decision, done in
            guard let model else { return done(true) }
            switch decision {
            case .save:
                Task {
                    do {
                        if let sourceURL = model.sourceURL,
                           let resultURL = try await model.commitEdits() {
                            _ = await ScreenshotPreviewStack.shared.applyAnnotation(
                                originalURL: sourceURL,
                                historyURL: resultURL
                            )
                        }
                        guard !model.hasUnsavedChanges else { return done(false) }
                        model.releaseEditorResources()
                        done(true)
                    } catch {
                        model.errorMessage = "Failed to save annotation: \(error.localizedDescription)"
                        done(false)
                    }
                }
            case .discard:
                model.releaseEditorResources()
                done(true)
            case .cancel:
                done(false)
            }
        }
    }

    private func clearInspectorFocus() {
        focusedField = nil
    }
}

private struct AnnotationLoadFailureView: View {
    let message: String
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.secondary)

            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            Button("Close", action: onClose)
                .keyboardShortcut(.cancelAction)
        }
        .workspaceTextPlate()
        .padding(32)
    }
}

extension FocusedValues {
    /// The key editor window's model, for menu commands.
    @Entry var annotationEditor: AnnotationEditorModel?
    /// Picks a tool as the dock does, turning Pick Color and Measure off.
    @Entry var annotationEditorSelectTool: ((AnnotationTool) -> Void)?
}

/// Tools: the editor's tools in the dock's order with their letter keys, and Crop, for the key
/// editor window. Only there while an editor is focused: a disabled item would still take its
/// key. The letters pass through to whatever field has the keyboard, as they do without the menu.
struct AnnotationEditorToolCommands: View {
    @FocusedValue(\.annotationEditor) private var editor
    @FocusedValue(\.annotationEditorSelectTool) private var selectTool

    var body: some View {
        if let editor, let selectTool {
            ForEach(Array(AnnotationToolDock.groups.enumerated()), id: \.offset) { index, group in
                if index > 0 { Divider() }
                ForEach(group) { tool in
                    let item = Toggle(tool.title, isOn: Binding(
                        get: { editor.selectedTool == tool && !editor.isCropping },
                        set: { _ in selectTool(tool) }
                    ))
                    if let key = tool.shortcutKey {
                        item.keyboardShortcut(KeyEquivalent(key), modifiers: [])
                    } else {
                        item
                    }
                }
            }
            Divider()
            Button(editor.isCropping ? "Cancel Crop" : "Crop") {
                withAnimation(.canvasMoveIfAllowed) { editor.toggleCropping() }
            }
            .keyboardShortcut("c", modifiers: [])
            .disabled(editor.imageSize == .zero)
        } else {
            Button("Open a Capture to Use Its Tools") {}
                .disabled(true)
        }
    }
}

/// View › zoom for the key editor window: the same keys as the editor's own, which take them
/// first, so a press zooms once. Only there while an editor is focused, for Studio's ⌘= and ⌘0.
struct AnnotationEditorZoomCommands: View {
    @FocusedValue(\.annotationEditor) private var editor

    var body: some View {
        if let editor {
            Button("Zoom In") { editor.zoomIn() }
                .keyboardShortcut("+", modifiers: .command)
            Button("Zoom Out") { editor.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
            Button("Actual Size") { editor.setZoomPercent(100) }
                .keyboardShortcut("0", modifiers: .command)
            Button("Zoom to Fit") { editor.fitCanvas() }
                .keyboardShortcut("1", modifiers: .command)
        }
    }
}

/// File › Save for the key editor window, disabled when clean. The editor's
/// key monitor takes ⌘S before the menu sees it, so one press saves once;
/// a second call would find the first save running anyway. Only there while
/// an editor is focused: a disabled item still consumes its ⌘S, which would
/// take the keystroke from Studio's own Save.
struct AnnotationEditorSaveCommand: View {
    @FocusedValue(\.annotationEditor) private var editor

    var body: some View {
        if let editor {
            Button("Save") { editor.requestSave() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!editor.hasUnsavedChanges)
        }
    }
}

/// File › Save As… for the key editor window. Only there while an editor
/// is focused, like Save: Studio has no Save As, and a disabled one sat
/// above Studio's Save.
struct AnnotationEditorSaveAsCommand: View {
    @FocusedValue(\.annotationEditor) private var editor

    var body: some View {
        if let editor {
            Button("Save As…") { editor.requestSaveAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
        }
    }
}

/// Format › Bigger Text and Smaller Text for the key editor window: text is sized by its handles,
/// and these are the keyboard's way. ⌘+ and ⌘− are the editor's zoom, so they take ⌥ too. In the
/// menu so Help's search finds them.
struct AnnotationEditorTextSizeCommands: View {
    @FocusedValue(\.annotationEditor) private var editor

    var body: some View {
        Button("Bigger Text") { editor?.stepTextSize(by: 1) }
            .keyboardShortcut("+", modifiers: [.command, .option])
            .disabled(!(editor?.canStepTextSize ?? false))
        Button("Smaller Text") { editor?.stepTextSize(by: -1) }
            .keyboardShortcut("-", modifiers: [.command, .option])
            .disabled(!(editor?.canStepTextSize ?? false))
    }
}

/// File › Revert To for the key editor window, as document apps have it.
/// Each is one step Undo takes back; the next save writes it.
struct AnnotationEditorRevertCommand: View {
    @FocusedValue(\.annotationEditor) private var editor

    var body: some View {
        if let editor {
            Menu("Revert To") {
                AnnotationEditorRevertItems(editor: editor)
            }
        }
    }
}
