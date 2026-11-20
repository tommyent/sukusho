import AppKit
import SwiftUI

struct CaptureLibraryView: View {
    @State private var model = CaptureLibraryModel.shared
    @State private var cloud = CloudLibraryModel.shared
    @State private var comments = CommentsLibraryModel.shared
    @State private var likes = LikesLibraryModel.shared
    @State private var clipboard = ClipboardHistoryModel.shared
    @State private var saved = LibrarySavedModel.shared
    @AppStorage(ScreendropPreferences.clipboardHistoryEnabledKey) private var clipboardEnabled = false
    @State private var history = ScreenshotHistoryStore.shared
    @State private var projects = RecordingProjectStore.shared
    @State private var libraryWindow: NSWindow?
    @State private var handledInitialWindowPlacement = false
    @State private var glassMetrics = GlassWindowButtonMetrics.fallback
    @State private var columnVisibility = NavigationSplitViewVisibility.automatic
    @AppStorage("captureLibrary.inspectorVisible") private var inspectorVisible = true
    @AppStorage("captureLibrary.tagsExpanded") private var tagsExpanded = true
    @AppStorage("captureLibrary.cardWidth") private var cardWidth = 220.0
    @AppStorage("captureLibrary.sort") private var savedSort: CaptureLibrarySort = .newest

    @AppStorage("clipboard.libraryShowsList") private var showsList = false
    private var layout: CaptureLibraryLayout { showsList ? .list : .grid }

    private var activeFilter: CaptureLibraryFilter { model.filter ?? .all }
    private var title: String {
        saved.isShown ? "Saved" : clipboard.isShown ? (clipboard.showsSnippets ? "Snippets" : "Clipboard") : comments.isShown ? "Comments" : likes.isShown ? "Likes" : cloud.isShown ? (!CloudUploader.shared.isConfigured ? "Cloud" : cloud.showsReceived ? "Received" : cloud.showsFiles ? "Files" : "Uploads") : model.tagFilter ?? activeFilter.title
    }
    @FloatingGlassChrome private var floatingChrome
    @Environment(\.colorScheme) private var colorScheme

    /// The sidebar picks a kind of capture, the cloud uploads or a tag.
    private var currentPage: CaptureLibrarySidebarSelection? {
        if saved.isShown { return .saved }
        if clipboard.isShown { return clipboard.showsSnippets ? .snippets : .clipboard }
        if comments.isShown { return .comments }
        if likes.isShown { return .likes }
        if cloud.isShown { return cloud.showsReceived ? .received : cloud.showsFiles ? .files : .cloud }
        if let tag = model.tagFilter { return .tag(tag) }
        return model.filter.map { .kind($0) }
    }

    private var sidebarSelection: Binding<CaptureLibrarySidebarSelection?> {
        Binding { currentPage } set: { selection in
            guard selection != currentPage else { return }
            if QuickLookPreviewPresenter.followsLibrary { QuickLookPreviewPresenter.dismiss() }
            cloud.cancelPreview()
            cloud.isShown = selection == .cloud || selection == .files || selection == .received
            cloud.showsFiles = selection == .files
            cloud.showsReceived = selection == .received
            comments.setShown(selection == .comments)
            likes.setShown(selection == .likes)
            clipboard.librarySelectionIDs = []
            clipboard.isShown = selection == .clipboard || selection == .snippets
            clipboard.showsSnippets = selection == .snippets
            saved.isShown = selection == .saved
            switch selection {
            case .saved:
                // Every saved capture, whatever kind or tag the captures page was on.
                model.selection = []
                clipboard.librarySelection = nil
                model.tagFilter = nil
                model.filter = .all
            case .cloud, .files, .received, .comments, .likes, .clipboard, .snippets:
                // The toolbar's capture actions mustn't act on captures out of sight.
                model.selection = []
            case .tag(let tag):
                model.filter = .all
                model.tagFilter = tag
            case .kind(let filter):
                model.tagFilter = nil
                model.filter = filter
            case nil:
                model.tagFilter = nil
                model.filter = nil
            }
        }
    }

    var body: some View {
        splitLayout
        .modifier(LibraryToolbarSeparator())
        .glassWindowChrome(
            window: libraryWindow,
            hasSidebar: true,
            sidebarVisible: columnVisibility != .detailOnly,
            inspectorVisible: inspectorVisible,
            metrics: $glassMetrics
        )
        .focusedSceneValue(\.captureLibraryCardWidth, $cardWidth)
        .background { refreshShortcut }
        // 860 pt holds the sidebar, the grid and the inspector; below 900 the inspector folds
        // away on its own, and without it the window goes down to 620 (Fable #7).
        .frame(minWidth: inspectorVisible ? 860 : 620, minHeight: 540)
        .inspectorAutoFold(isPresented: $inspectorVisible, below: 900)
        .onAppear {
            AppActivationPolicy.enter()
            model.sortOrder = savedSort
            model.refresh()
            cloud.refresh()
            comments.refresh()
            likes.refresh()
            clipboard.refresh()
        }
        .onDisappear { AppActivationPolicy.leave() }
        .onWindowChange { window in
            libraryWindow = window
            model.savedUndoManager = window?.undoManager
            PreviewWindowCaptureExclusion.shared.register(window: window)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            if let window = notification.object as? NSWindow, window === libraryWindow {
                if !handledInitialWindowPlacement {
                    handledInitialWindowPlacement = true
                    if floatingChrome, let screen = window.screen?.visibleFrame {
                        // SwiftUI can open at the Library's previous minimum size despite the scene's default.
                        let size = CGSize(width: min(1180, screen.width), height: min(760, screen.height))
                        window.setFrame(CGRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2,
                                               width: size.width, height: size.height), display: true)
                    }
                }
                model.refresh()
                if cloud.isShown { cloud.refresh() }
                // The sidebar's unread counts, whichever page is open. No timer: only here, on open and on ⌘R.
                comments.refresh()
                likes.refresh()
            }
        }
        .onChange(of: model.selection) { _, _ in
            // AppKit can deselect before selecting the next card in the same key event.
            guard QuickLookPreviewPresenter.followsLibrary else { return }
            switch currentPage {
            case .kind, .tag:
                QuickLookPreviewPresenter.follow(urls: model.selectedItems.map(\.fileURL))
            default: break
            }
        }
        .onChange(of: history.items) { _, _ in model.refresh() }
        .onChange(of: projects.projects) { _, _ in model.refresh() }
        // New Snippet's editor is in the inspector: show it, or the typing has nowhere to go (VM check, 2026-11-17).
        .onChange(of: clipboard.snippetAwaitingFocus) { _, id in if id != nil { inspectorVisible = true } }
        .onChange(of: clipboard.snippetAwaitingName) { _, id in
            if id != nil { inspectorVisible = true }
        }
        .onChange(of: model.sortOrder) { _, value in savedSort = value }
        .sheet(item: $model.pendingConversion) { conversion in
            ImageConversionSheet(conversion: conversion) { model.actionFeedback.show($0) }
        }
        .sheet(item: $model.pendingClipUpload) { batch in
            CloudUploadOptionsPopover(showsTitle: batch.sources.count == 1,
                                      encryptionUnavailable: CloudShareSeal.unavailableReason(fileURLs: batch.sources.map(\.url), isRecording: batch.includesRecording)) { options in
                batch.upload(options: options)
            }
        }
        .sheet(item: $model.pendingCloudUpload) { item in
            // The card's own name: yours, else Apple Intelligence's, else the date; never the file name.
            CloudUploadOptionsPopover(suggestedTitle: item.title,
                                      encryptionUnavailable: CloudShareSeal.unavailableReason(fileURLs: [item.fileURL],
                                                                                              isRecording: item.isVideo),
                                      messageSource: item.session.map { .recording($0.loadProjectMetadata()) }
                                          ?? ShareMessageSource(isVideo: item.isVideo)) { options in
                model.upload(item, options: options)
            }
        }
        .sheet(isPresented: Binding(get: { !model.pendingGallery.isEmpty }, set: { if !$0 { model.pendingGallery = [] } })) {
            let items = model.pendingGallery
            // The title names the gallery; its images keep their cards' names.
            CloudUploadOptionsPopover(suggestedTitle: "\(items.count) screenshots",
                                      encryptionUnavailable: "Galleries can’t be end-to-end encrypted yet.") { options in
                model.shareGallery(items, options: options)
            }
        }
        .alert("Revert “\(model.pendingRevert?.title ?? "")” to the original?", isPresented: Binding(
            get: { model.pendingRevert != nil }, set: { if !$0 { model.pendingRevert = nil } }
        )) {
            Button("Revert", role: .destructive) { model.revertPendingItem() }
            Button("Cancel", role: .cancel) { model.pendingRevert = nil }
        } message: {
            Text("Its edits will be removed.")
        }
        .alert("Delete from cloud?", isPresented: Binding(
            get: { model.pendingCloudDelete != nil }, set: { if !$0 { model.pendingCloudDelete = nil } }
        ), presenting: model.pendingCloudDelete) { item in
            Button("Delete", role: .destructive) {
                model.deleteCloudCopy(item)
                model.pendingCloudDelete = nil
            }
            Button("Cancel", role: .cancel) { model.pendingCloudDelete = nil }
        } message: { item in
            Text("This permanently removes the cloud copy and breaks its share link. Your local capture stays in the Library."
                 // Galleries hold images only.
                 + ((item.isVideo ? nil : cloud.galleryNote(forLink: item.cloudURL)).map { " " + $0 } ?? ""))
        }
        .alert("The Library action could not be completed", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }

    @ViewBuilder private var splitLayout: some View {
        if floatingChrome {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                sidebarContent
                    .glassSidebarCollapseOverlay(enabled: true, metrics: glassMetrics) {
                        withAnimation { columnVisibility = .detailOnly }
                    }
                    .toolbar(removing: .sidebarToggle)
            } detail: {
                detailColumn
                    .navigationTitle(title)
                    .toolbar(removing: .title)
                    .overlay(alignment: .top) {
                        glassDetailHeader
                    }
            }
            .navigationSplitViewStyle(.balanced)
            .modifier(LibraryWindowSurface())
            .inspector(isPresented: $inspectorVisible) {
                inspectorContent
            }
            // Keep AppKit's full-height sidebar and window-button placement with the native toolbar empty.
            .toolbar { ToolbarSpacer(.flexible) }
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            .glassInspectorToggleOverlay(
                enabled: true,
                isPresented: $inspectorVisible,
                metrics: glassMetrics,
                hasKeyboardShortcut: true
            )
        } else {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                sidebarContent
            } detail: {
                detailColumn
                    .modifier(LibraryColumnSeparators(
                        leading: columnVisibility != .detailOnly,
                        trailing: inspectorVisible
                    ))
                    // Inside the detail column the inspector sits under the toolbar,
                    // so the toolbar runs unbroken across it.
                    .inspector(isPresented: $inspectorVisible) {
                        inspectorContent
                    }
                    .modifier(LibraryWindowSurface())
                    .navigationTitle(title)
            }
            .navigationSplitViewStyle(.balanced)
            .toolbar { toolbar }
        }
    }

    // Detail-scoped overlay keeps the title and search pills clear of the floating sidebar and inspector panels.
    private var glassDetailHeader: some View {
        let sidebarHidden = columnVisibility == .detailOnly
        let headerHeight = max(34, glassMetrics.diameter)
        let trailingReserve = inspectorVisible
            ? 12
            : LibraryFloatingSidebar.outerInset + glassMetrics.paneTrailingInset + glassMetrics.diameter + 8
        return HStack(alignment: .center, spacing: 8) {
            if sidebarHidden {
                GlassPaneToggleButton(
                    title: "Show Sidebar",
                    symbol: "sidebar.left",
                    diameter: glassMetrics.diameter
                ) {
                    withAnimation { columnVisibility = .all }
                }
            }
            Text(title)
                .font(.headline)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background { CapsuleGlass().allowsHitTesting(false) }
            Spacer(minLength: 12)
            searchField(onGlass: true)
        }
        .foregroundStyle(AppTheme.glassTitleInk(dark: colorScheme == .dark).color)
        .frame(height: headerHeight)
        .padding(.leading, sidebarHidden ? glassMetrics.trailing + 8 : 12)
        .padding(.trailing, trailingReserve)
        .padding(.top, max(4, glassMetrics.centerY - headerHeight / 2))
        .frame(maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea(.container, edges: .top)
    }

    private var sidebarContent: some View {
        List(selection: sidebarSelection) {
            // Option A (sd-ogtp.1.1): Captures is the working folder, everything taken or copied;
            // Library is what the user chose to keep.
            Section("Captures") {
                ForEach(CaptureLibraryFilter.allCases) { filter in
                    Label {
                        HStack {
                            Text(filter.title)
                            Spacer()
                            SidebarCount(model.count(for: filter))
                        }
                    } icon: { Image(systemName: filter.symbol) }
                    .tag(CaptureLibrarySidebarSelection.kind(filter))
                }
                // Copies from any app, beside the captures. While history is
                // off, it opens its setup page.
                Label {
                    HStack {
                        Text("Clipboard")
                        Spacer()
                        if clipboardEnabled {
                            SidebarCount(clipboard.historyCount)
                        } else {
                            Text("Off").foregroundStyle(.secondary).font(.caption)
                        }
                    }
                } icon: { Image(systemName: "doc.on.clipboard") }
                .tag(CaptureLibrarySidebarSelection.clipboard)
            }
            Section("Library") {
                Label {
                    HStack {
                        Text("Saved")
                        Spacer()
                        SidebarCount(model.items.count(where: \.isSaved) + clipboard.savedCount)
                    }
                } icon: { Image(systemName: "star") }
                .tag(CaptureLibrarySidebarSelection.saved)
                if clipboardEnabled {
                    Label {
                        HStack {
                            Text("Snippets")
                            Spacer()
                            SidebarCount(clipboard.snippetCount)
                        }
                    } icon: { Image(systemName: "text.badge.star") }
                    .tag(CaptureLibrarySidebarSelection.snippets)
                }
            }
            // Uploads and their comments live on the Worker, apart from
            // the captures on this Mac. Until a Worker is set up, one row
            // leads to setup instead of two that both end there (design
            // pass choice 7).
            Section("Cloud") {
                if CloudUploader.shared.isConfigured {
                    Label {
                        HStack {
                            Text("Uploads")
                            Spacer()
                            if cloud.hasLoaded {
                                SidebarCount(cloud.count(files: false))
                            }
                        }
                    } icon: { Image(systemName: "cloud") }
                    .tag(CaptureLibrarySidebarSelection.cloud)
                    Label {
                        HStack {
                            Text("Files")
                            Spacer()
                            if cloud.hasLoaded {
                                SidebarCount(cloud.count(files: true))
                            }
                        }
                    } icon: { Image(systemName: "doc") }
                    .tag(CaptureLibrarySidebarSelection.files)
                    Label {
                        HStack {
                            Text("Received")
                            Spacer()
                            if cloud.hasLoaded {
                                SidebarCount(cloud.receivedCount)
                            }
                        }
                    } icon: { Image(systemName: "tray.and.arrow.down") }
                    .tag(CaptureLibrarySidebarSelection.received)
                    Label {
                        HStack {
                            Text("Comments")
                            Spacer()
                            if comments.hasLoaded, !comments.isUnavailable {
                                FeedCount(total: comments.comments.count, unread: comments.unreadCount)
                            }
                        }
                    } icon: { Image(systemName: "bubble.left.and.bubble.right") }
                    .tag(CaptureLibrarySidebarSelection.comments)
                    Label {
                        HStack {
                            Text("Likes")
                            Spacer()
                            if likes.hasLoaded, !likes.isUnavailable {
                                FeedCount(total: likes.likes.count, unread: likes.unreadCount)
                            }
                        }
                    } icon: { Image(systemName: "heart") }
                    .tag(CaptureLibrarySidebarSelection.likes)
                } else {
                    Label("Set Up Cloud", systemImage: "cloud")
                        .tag(CaptureLibrarySidebarSelection.cloud)
                }
            }
            if !model.tags.isEmpty {
                Section("Tags", isExpanded: $tagsExpanded) {
                    ForEach(model.tags, id: \.self) { tag in
                        Label {
                            HStack {
                                Text(tag)
                                Spacer()
                                SidebarCount(model.tagCounts[tag] ?? 0)
                            }
                        } icon: { CaptureTagIcon(tag: tag) }
                        .tag(CaptureLibrarySidebarSelection.tag(tag))
                        .contextMenu { CaptureTagAppearanceMenu(tag: tag) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
        .safeAreaInset(edge: .bottom) {
            HStack(alignment: .center, spacing: 12) {
                Button {
                    SettingsWindowController.show(tab: .general)
                } label: {
                    // Icon only; the label still names it for VoiceOver.
                    Label("Settings", systemImage: "gearshape")
                        .labelStyle(.iconOnly)
                        .padding(.vertical, 8)
                        // A comfortable target, not just the gear's own pixels.
                        .frame(minWidth: 28, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Settings")

                // Cloud storage against the threshold in Settings › Cloud
                // (sd-irc), beside the gear on every page; none until the
                // Worker reports it.
                if let usage = cloud.usage, CloudUploader.shared.isConfigured {
                    CloudUsageBar(usage: usage)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
        .modifier(LibrarySidebarSurface())
    }

    private var detailColumn: some View {
        VStack(spacing: 0) {
            // Empty pages are only as tall as their message; fill the column anyway.
            browser.frame(maxWidth: .infinity, maxHeight: .infinity)
                .modifier(LibraryBrowserSurface(
                    showsDots: comments.isShown ? comments.visibleComments.isEmpty
                        : likes.isShown ? likes.visibleLikes.isEmpty : true
                ))
                .overlay(alignment: .bottom) {
                    if floatingChrome { glassFooter }
                }
            if !floatingChrome {
                Divider()
                statusBar
            }
        }
    }

    private var inspectorContent: some View {
        Group {
            if (saved.isShown || clipboard.isShown), clipboard.librarySelectionIDs.count + model.selection.count > 1 {
                Text("\(clipboard.librarySelectionIDs.count + model.selection.count) items selected")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if saved.isShown, clipboard.librarySelection != nil {
                ClipboardLibraryInspector(model: clipboard)
            } else if saved.isShown {
                CaptureLibraryInspector(model: model, emptyMessage: "Select a capture or clip\nto take a closer look.")
            } else if clipboard.isShown {
                ClipboardLibraryInspector(model: clipboard)
            } else if comments.isShown {
                CommentInspector(comments: comments)
            } else if likes.isShown {
                LikeInspector(likes: likes)
            } else if cloud.isShown {
                CloudUploadInspector(cloud: cloud)
            } else {
                CaptureLibraryInspector(model: model)
            }
        }
        // The inspector column paints its own grey, under the
        // toolbar too, so its content carries the sidebar's.
        .modifier(LibrarySidebarSurface())
        .inspectorColumnWidth(min: 240, ideal: 280, max: 360)
    }

    @ViewBuilder private var browser: some View {
        if saved.isShown {
            LibrarySavedPage(cardWidth: cardWidth, layout: layout)
        } else if clipboard.isShown {
            ClipboardLibraryPage(model: clipboard, cardWidth: cardWidth, layout: layout)
        } else if comments.isShown {
            CommentsLibraryPage(comments: comments)
        } else if likes.isShown {
            LikesLibraryPage(likes: likes)
        } else if cloud.isShown {
            CloudLibraryPage(cloud: cloud, cardWidth: cardWidth, layout: layout)
        } else if !model.hasLoaded {
            ProgressView("Loading Library…").workspaceTextPlate().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.visibleItems.isEmpty {
            if !model.searchText.isEmpty {
                ContentUnavailableView {
                    Label("No Results for “\(model.searchText)”", systemImage: "magnifyingglass")
                } description: {
                    Text(activeFilter == .all
                        ? "Check the spelling or try a new search."
                        : "Nothing in \(activeFilter.title) matches. Check the spelling, or search all your captures.")
                } actions: {
                    HStack {
                        if activeFilter != .all {
                            // Widening keeps the query and may find the other
                            // kind of capture, so it's the likeliest next step.
                            Button("Search All Captures") { model.filter = .all }
                                .buttonStyle(.borderedProminent)
                        }
                        Button("Clear Search") { model.searchText = "" }
                            .buttonStyle(.bordered)
                    }
                    .controlSize(.large)
                }
                .workspaceTextPlate()
            } else {
                ContentUnavailableView {
                    Label(emptyLibraryTitle, systemImage: activeFilter.symbol)
                } description: {
                    Text(emptyLibraryDescription)
                } actions: {
                    VStack(spacing: 12) {
                        emptyActions
                        if let shortcutLine {
                            Text(shortcutLine)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .workspaceTextPlate()
            }
        } else {
            LibraryCaptureCollection(items: model.visibleItems, layout: layout, cardWidth: cardWidth, model: model)
        }
    }

    private var emptyLibraryTitle: String {
        switch activeFilter {
        case .all: "No Captures Yet"
        case .screenshots: "No Screenshots Yet"
        case .recordings: "No Recordings Yet"
        }
    }

    private var emptyLibraryDescription: String {
        switch activeFilter {
        case .all: "Screenshots and recordings you make appear here."
        case .screenshots: "Capture an area, a window or the whole screen."
        case .recordings: "Record your screen, a window or an area."
        }
    }

    /// One prominent button for the page's likeliest action and at most one
    /// standard one beside it, at the same size (HIG: Buttons).
    private var emptyActions: some View {
        HStack {
            switch activeFilter {
            case .all:
                captureAreaButton.buttonStyle(.borderedProminent)
                recordScreenButton.buttonStyle(.bordered)
            case .screenshots:
                captureAreaButton.buttonStyle(.borderedProminent)
                Button("Capture Window") { CaptureCoordinator.shared.captureWindow() }
                    .buttonStyle(.bordered)
            case .recordings:
                recordScreenButton.buttonStyle(.borderedProminent)
            }
        }
        .controlSize(.large)
    }

    /// The page's capture shortcuts as the user set them, so an empty page
    /// teaches the keys that work from anywhere. Keys that failed to register
    /// are left out, and with none left there's no line at all. Non-breaking
    /// spaces keep each key with its name, so the line wraps between them,
    /// including the space inside a modifier key on its own ("Right ⌥", "⌥ ⌥").
    private var shortcutLine: String? {
        let actions: [(CaptureHotkeyAction, String)] = switch activeFilter {
        case .all: [(.area, "Area"), (.window, "Window"), (.fullscreen, "Fullscreen"), (.screenRecording, "Record")]
        case .screenshots: [(.area, "Area"), (.window, "Window"), (.fullscreen, "Fullscreen")]
        case .recordings: [(.screenRecording, "Record")]
        }
        let keys = actions
            .filter { HotkeyManager.shared.registrationErrors[$0.0] == nil }
            .compactMap { action, name in
                CaptureHotkeyPreferences.shortcut(for: action).map {
                    $0.displayTokens.joined().replacingOccurrences(of: " ", with: "\u{00A0}") + "\u{00A0}" + name
                }
            }
        guard !keys.isEmpty else { return nil }
        let heading = keys.count == 1 ? "Shortcut that works anywhere" : "Shortcuts that work anywhere"
        return heading + "\n" + keys.joined(separator: "\u{00A0}· ")
    }

    private var captureAreaButton: some View {
        Button("Capture Area") { CaptureCoordinator.shared.captureArea() }
    }

    /// The ellipsis: it opens the recording picker rather than starting at once.
    private var recordScreenButton: some View {
        Button("Record Screen…") { RecordingBarPresenter.shared.showPicker() }
            .disabled(ScreenRecordingManager.shared.isActive || ScrollingCapturePresenter.shared.isRunning)
    }

    private static let glassFooterPillHeight: CGFloat = 32

    private var hasLeadingStatus: Bool {
        if model.operationTitle != nil || model.actionFeedback.message != nil
            || model.savedAgentPrompt != nil || model.copiedLink != nil
            || comments.isShown || likes.isShown || cloud.isShown || saved.isShown {
            return true
        }
        return !clipboard.isShown || clipboardEnabled
    }

    private var isStatusRefreshing: Bool {
        clipboard.isShown ? false : comments.isShown ? comments.isLoading : likes.isShown ? likes.isLoading : cloud.isShown ? cloud.isLoading : model.isLoading
    }

    private var showsViewControls: Bool {
        !comments.isShown && !likes.isShown && (!clipboard.isShown || clipboardEnabled)
    }

    @ViewBuilder private var statusLeading: some View {
        if let title = model.operationTitle {
            ProgressView().controlSize(.mini)
            Text(title)
            if let export = model.agentPromptExport {
                Text("\(Int((export.progress * 100).rounded()))%").monospacedDigit()
            }
        } else if let done = model.actionFeedback.message {
            StatusSuccess(title: done, systemImage: "checkmark.circle.fill", onGlass: floatingChrome)
        } else if let folder = model.savedAgentPrompt {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([folder])
            } label: {
                StatusSuccess(title: "Prompt Copied", systemImage: "checkmark.circle.fill", onGlass: floatingChrome)
            }
            .buttonStyle(.plain)
            .help("Reveal \(folder.lastPathComponent) in Finder")
        } else if let link = model.copiedLink {
            Button {
                CloudShareLinks.copy([link], feedback: model.actionFeedback)
            } label: {
                StatusSuccess(title: "Link Copied", systemImage: "checkmark.icloud", onGlass: floatingChrome)
            }
            .buttonStyle(.plain)
            .help("Copy the gallery link again")
        } else if comments.isShown {
            let count = comments.visibleComments.count
            Text("\(count) \(count == 1 ? "comment" : "comments")")
            if !comments.selection.isEmpty { Text("· \(comments.selection.count) selected") }
            if !comments.deletingIDs.isEmpty { Text("· Deleting…") }
        } else if likes.isShown {
            let count = likes.visibleLikes.count
            Text("\(count) \(count == 1 ? "like" : "likes")")
            if !likes.selection.isEmpty { Text("· \(likes.selection.count) selected") }
        } else if cloud.isShown, let fetch = cloud.previewFetch {
            ProgressView(value: fetch.total).controlSize(.mini).frame(width: 60)
            Text(fetch.title)
            Button("Stop Downloading", systemImage: "xmark.circle.fill") { cloud.cancelPreview() }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .help("Stop downloading")
        } else if cloud.isShown {
            let count = cloud.visibleUploads.count
            Text("\(count) \(cloud.showsFiles || cloud.showsReceived ? (count == 1 ? "file" : "files") : count == 1 ? "upload" : "uploads")")
            if !cloud.selection.isEmpty { Text("· \(cloud.selection.count) selected") }
            if !cloud.deletingIDs.isEmpty { Text("· Deleting…") }
        } else if saved.isShown {
            let count = saved.cards.count
            Text("\(count) saved")
            let selected = model.selection.count + clipboard.librarySelectionIDs.count
            if selected > 0 { Text("· \(selected) selected") }
        } else if clipboard.isShown {
            if clipboardEnabled {
                let count = clipboard.librarySections(query: model.searchText).reduce(0) { $0 + $1.entries.count }
                if !clipboard.librarySelectionIDs.isEmpty { Text("\(clipboard.librarySelectionIDs.count) selected ·") }
                Text("\(count) \(clipboard.showsSnippets ? (count == 1 ? "snippet" : "snippets") : count == 1 ? "copy" : "copies")")
            }
        } else {
            Text("\(model.visibleItems.count) \(model.visibleItems.count == 1 ? "capture" : "captures")")
            if !model.selection.isEmpty { Text("· \(model.selection.count) selected") }
        }
    }

    @ViewBuilder private var statusTrailing: some View {
        if isStatusRefreshing {
            ProgressView().controlSize(.mini)
                .help(comments.isShown ? "Refreshing comments" : likes.isShown ? "Refreshing likes"
                      : cloud.isShown ? "Refreshing uploads" : "Refreshing Library")
        }
        if showsViewControls {
            Picker("Layout", selection: $showsList) {
                Label("Grid", systemImage: "square.grid.2x2").tag(false)
                Label("List", systemImage: "list.bullet").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().labelStyle(.iconOnly).controlSize(.small).fixedSize()
            if !showsList {
                // Capped where the 640 px thumbnails stay sharp on Retina.
                Slider(value: $cardWidth, in: LibraryCardWidth.range) {
                    EmptyView()
                } minimumValueLabel: {
                    Image(systemName: "photo").imageScale(.small)
                } maximumValueLabel: {
                    Image(systemName: "photo").imageScale(.large)
                }
                .controlSize(.mini)
                .frame(width: 150)
                .accessibilityLabel("Card size")
                .help("Card size")
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            statusLeading
            Spacer()
            statusTrailing
        }
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        // 20, not a DS step: it lines the count up with the toolbar title above.
        .padding(.horizontal, 20)
        // Keep the status bar out of the column's minimum width. With the card
        // size slider counted in it, resizing the window looped in AppKit's
        // constraint pass until it crashed.
        .frame(minWidth: 0, maxWidth: .infinity)
        .frame(height: 30)
    }

    /// Glass: two floating Liquid Glass pills over the bottom of the browser (count on the left, view controls on the
    /// right) with no strip behind them, so cards scroll underneath and show between them.
    private var glassFooter: some View {
        HStack(spacing: 12) {
            if hasLeadingStatus {
                HStack(spacing: 6) {
                    statusLeading
                }
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(height: Self.glassFooterPillHeight)
                .background { CapsuleGlass().allowsHitTesting(false) }
            }
            Spacer(minLength: 0)
            if isStatusRefreshing || showsViewControls {
                HStack(spacing: 8) {
                    statusTrailing
                }
                .padding(.leading, showsViewControls && !isStatusRefreshing ? 6 : 10)
                .padding(.trailing, showsViewControls && showsList ? 6 : 12)
                .frame(height: Self.glassFooterPillHeight)
                .background { CapsuleGlass().allowsHitTesting(false) }
            }
        }
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(AppTheme.glassTitleInk(dark: colorScheme == .dark).color)
        // 8 pt lines the count text (8 + 12 = 20) and pill edge up with the title pill above, and aligns the pills'
        // bottom edge with the floating sidebar's 8 pt inset.
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        // Keep the footer out of the column's minimum width (see statusBar).
        .frame(minWidth: 0, maxWidth: .infinity)
    }

    /// ⌘R refreshes the page. Its menu item went with the toolbar's sort
    /// menu; Refresh is also in the right-click menu between the cards.
    private var refreshShortcut: some View {
        Button("Refresh") {
            if comments.isShown { comments.refresh() } else if likes.isShown { likes.refresh() }
            else if cloud.isShown { cloud.refresh() }
            else if clipboard.isShown { clipboard.refresh() }
            else if saved.isShown { clipboard.refresh(); history.reload(); model.refresh() }
            else { history.reload(); model.refresh() }
        }
        .keyboardShortcut("r", modifiers: .command)
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func searchField(onGlass: Bool) -> some View {
        LibrarySearchField(
            text: $model.searchText,
            prompt: saved.isShown ? "Search saved" : clipboard.isShown ? (clipboard.showsSnippets ? "Search snippets" : "Search clipboard") : comments.isShown ? "Search comments" : likes.isShown ? "Search likes" : cloud.isShown ? (cloud.showsReceived ? "Search received files" : cloud.showsFiles ? "Search files" : "Search uploads") : "Search captures",
            bezel: !onGlass
        )
        .padding(.horizontal, onGlass ? 8 : 0)
        .frame(minWidth: 120, idealWidth: 320, maxWidth: 320)
        .frame(height: onGlass ? 34 : nil)
        .background {
            if onGlass { CapsuleGlass().allowsHitTesting(false) }
        }
    }

    @ToolbarContentBuilder private var searchToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) { searchField(onGlass: false) }
        .sharedBackgroundVisibility(.visible)
    }

    @ToolbarContentBuilder private var inspectorToggleToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button { inspectorVisible.toggle() } label: {
                Label(inspectorVisible ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.right")
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .help(inspectorVisible ? "Hide Inspector" : "Show Inspector")
        }
        .sharedBackgroundVisibility(.hidden)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        searchToolbarItem
        inspectorToggleToolbarItem
    }
}

struct LibraryCaptureCollection: View {
    let items: [CaptureLibraryItem]
    let layout: CaptureLibraryLayout
    let cardWidth: CGFloat
    @Bindable var model: CaptureLibraryModel

    var body: some View {
        CaptureLibraryCollection(items: items, revision: model.contentRevision, layout: layout,
            cardWidth: cardWidth, selection: $model.selection, isBusy: model.isBusy,
            cell: { item, selected, onTitleFrame in
                AnyView(LibraryCellContent(item: item, selected: selected, layout: layout, onTitleFrame: onTitleFrame))
            },
            menu: { [model] in model.menuItems(selected: $0) },
            backgroundMenu: { [model] in model.backgroundMenuItems { model.refresh() } },
            dragWriter: { try LibrarySavedCard.capture($0).dragWriter() },
            onAction: model.perform)
    }
}

/// A Comments or Likes row's count: the total, as other rows count, with a dot while some are
/// new since the page was last open.
private struct FeedCount: View {
    let total: Int
    let unread: Int

    var body: some View {
        // Nothing at zero, as every other sidebar count (Astra R4).
        HStack(spacing: 5) {
            if unread > 0 { Circle().fill(.tint).frame(width: 6, height: 6) }
            if total > 0 { Text(total, format: .number) }
        }
        .foregroundStyle(.secondary)
        .font(.caption.monospacedDigit())
        .help(unread > 0 ? "\(unread) new" : "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(unread > 0 ? "\(total), \(unread) new" : "\(total)")
    }
}

/// AppKit's search field in place of `.searchable`, whose system field always
/// sat at the far right, right of the inspector toggle. The field brings its
/// own clear button, and Escape clears it.
private struct LibrarySearchField: NSViewRepresentable {
    @Binding var text: String
    let prompt: String
    let bezel: Bool

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        if !bezel {
            field.cell = GlassSearchFieldCell(textCell: "")
            field.isEditable = true
            field.isSelectable = true
            field.isBezeled = false
            field.isBordered = false
        }
        field.sendsSearchStringImmediately = true
        field.target = context.coordinator
        field.action = #selector(Coordinator.search(_:))
        // ⌘F focuses the field, as with `.searchable`. A monitor rather than
        // a shortcut: a disabled menu item with ⌘F would take the key first.
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak field] event in
            guard let field, let window = field.window, event.window === window,
                  event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
                  event.charactersIgnoringModifiers == "f" else { return event }
            window.makeFirstResponder(field)
            return nil
        }
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text { field.stringValue = text }
        field.placeholderString = prompt
        field.setAccessibilityLabel(prompt)
    }

    static func dismantleNSView(_ field: NSSearchField, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject {
        var text: Binding<String>
        var monitor: Any?

        init(text: Binding<String>) { self.text = text }

        @objc func search(_ field: NSSearchField) { text.wrappedValue = field.stringValue }
    }
}

private final class GlassSearchFieldCell: NSSearchFieldCell {
    override func searchTextRect(forBounds rect: NSRect) -> NSRect {
        let text = super.searchTextRect(forBounds: rect)
        let search = searchButtonRect(forBounds: rect)
        let cancel = cancelButtonRect(forBounds: rect)
        // The borderless cell gives its text the button's space as well.
        let left = max(text.minX, search.maxX + 4)
        let right = cancel.isEmpty ? text.maxX : min(text.maxX, cancel.minX - 4)
        return NSRect(x: left, y: text.minY, width: max(0, right - left), height: text.height)
    }
}

/// Liquid Glass capsule shared by floating controls.
final class CapsuleGlassView: NSGlassEffectView {
    var onFrameMetrics: ((GlassWindowButtonMetrics) -> Void)?
    private var lastReportedMetrics: GlassWindowButtonMetrics?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if shadow != nil {
            superview?.clipsToBounds = false
            superview?.superview?.clipsToBounds = false
        }
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        reportMetricsIfNeeded()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        reportMetricsIfNeeded()
    }

    override func layout() {
        super.layout()
        cornerRadius = bounds.height / 2
        reportMetricsIfNeeded()
    }

    func reportMetricsIfNeeded() {
        guard let onFrameMetrics, let container = superview, frame.height > 0 else { return }
        let top = container.isFlipped ? frame.minY : container.bounds.height - frame.maxY
        let metrics = GlassWindowButtonMetrics(
            top: top.rounded(),
            diameter: frame.height.rounded(),
            trailing: frame.maxX.rounded(),
            leading: frame.minX.rounded()
        )
        guard metrics != lastReportedMetrics else { return }
        lastReportedMetrics = metrics
        DispatchQueue.main.async { onFrameMetrics(metrics) }
    }

    func applyLiftShadow() {
        wantsLayer = true
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
        shadow.shadowBlurRadius = 8
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        self.shadow = shadow
    }
}

struct CapsuleGlass: NSViewRepresentable {
    var lifted = false

    func makeNSView(context: Context) -> CapsuleGlassView {
        let view = CapsuleGlassView()
        view.style = .regular
        view.cornerRadius = 16
        if lifted { view.applyLiftShadow() }
        return view
    }

    func updateNSView(_ view: CapsuleGlassView, context: Context) {}
}

/// Measured geometry of a window's Glass traffic-light pill, in top-down window coordinates.
struct GlassWindowButtonMetrics: Equatable {
    let top: CGFloat
    let diameter: CGFloat
    let trailing: CGFloat
    let leading: CGFloat

    var centerY: CGFloat { top + diameter / 2 }
    var topInsideFloatingPane: CGFloat { max(4, top - LibraryFloatingSidebar.verticalInset) }
    var paneTrailingInset: CGFloat { max(6, leading - LibraryFloatingSidebar.outerInset) }

    static let fallback = GlassWindowButtonMetrics(top: 12, diameter: 28, trailing: 86, leading: 14)
}

/// Glass: a Liquid Glass capsule under macOS's own close, minimize and zoom buttons ("option A"), matching the title
/// pill (`CapsuleGlassView`). The standard buttons stay untouched in the titlebar above it, so hover glyphs, the green
/// button's menu, inactive dimming and VoiceOver/accessibility all stay native.
enum LibraryWindowButtonCapsule {
    private static let id = NSUserInterfaceItemIdentifier("LibraryWindowButtonCapsule")
    private static let padding: CGFloat = 7

    /// False while the standard window buttons aren't in the window frame and laid out yet.
    static func update(
        _ window: NSWindow?,
        shown: Bool,
        onMetrics: ((GlassWindowButtonMetrics) -> Void)? = nil
    ) -> Bool {
        guard let window, let content = window.contentView, let frame = content.superview else { return true }
        let existing = frame.subviews.filter { $0.identifier == id }
        guard shown else {
            existing.forEach { $0.removeFromSuperview() }
            return true
        }
        guard let close = window.standardWindowButton(.closeButton),
              let zoom = window.standardWindowButton(.zoomButton),
              !close.isHidden, !zoom.isHidden,
              close.frame.width > 0, zoom.frame.width > 0,
              close.isDescendant(of: frame), zoom.isDescendant(of: frame) else {
            existing.forEach { $0.removeFromSuperview() }
            return false
        }
        if existing.count == 1,
           let capsule = existing[0] as? CapsuleGlassView,
           frame.constraints.contains(where: { $0.firstItem === capsule && $0.isActive }) {
            capsule.onFrameMetrics = onMetrics
            capsule.reportMetricsIfNeeded()
            return true
        }
        existing.forEach { $0.removeFromSuperview() }
        var titlebar: NSView = close
        while let up = titlebar.superview, up !== frame { titlebar = up }
        let capsule = CapsuleGlassView()
        capsule.identifier = id
        capsule.style = .regular
        capsule.cornerRadius = 14
        capsule.applyLiftShadow()
        capsule.onFrameMetrics = onMetrics
        capsule.translatesAutoresizingMaskIntoConstraints = false
        frame.addSubview(capsule, positioned: .below, relativeTo: titlebar)
        NSLayoutConstraint.activate([
            capsule.leadingAnchor.constraint(equalTo: close.leadingAnchor, constant: -padding),
            capsule.trailingAnchor.constraint(equalTo: zoom.trailingAnchor, constant: padding),
            capsule.topAnchor.constraint(equalTo: close.topAnchor, constant: -padding),
            capsule.bottomAnchor.constraint(equalTo: close.bottomAnchor, constant: padding),
        ])
        let closeRect = close.convert(close.bounds, to: frame)
        let zoomRect = zoom.convert(zoom.bounds, to: frame)
        let top = (frame.isFlipped ? closeRect.minY : frame.bounds.height - closeRect.maxY) - padding
        let initial = GlassWindowButtonMetrics(
            top: top.rounded(),
            diameter: (closeRect.height + padding * 2).rounded(),
            trailing: (zoomRect.maxX + padding).rounded(),
            leading: (closeRect.minX - padding).rounded()
        )
        DispatchQueue.main.async { onMetrics?(initial) }
        return true
    }
}

/// Glass: float the Library's side panes as inset, rounded, lifted glass panes with a subtle light rim and no flat
/// full-height split divider beside them. The left sidebar needs this only on macOS 27.2+ (macOS 26 already floats it
/// natively); the right inspector needs it on both macOS 26 and 27.2+. Classic, Chip, Reduce Transparency and Increase
/// Contrast restore the flush layout untouched.
enum LibraryFloatingSidebar {
    static let outerInset: CGFloat = 8
    static let verticalInset: CGFloat = 8
    private static let innerInset: CGFloat = 0
    private static let cornerRadius: CGFloat = 16
    private static let rimID = NSUserInterfaceItemIdentifier("LibraryFloatingSidebarRim")
    private static let paneGlassID = NSUserInterfaceItemIdentifier("LibraryFloatingPaneGlass")

    private struct Pane {
        let glass: NSGlassEffectView
        let wrapper: NSView
        let split: NSSplitView
        let isCollapsed: Bool
    }

    private final class FloatingPaneGlassView: NSGlassEffectView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    /// Subtle 0.5 pt rim matching the Glass cards' `frost.rim`, sharpening a floating pane's perimeter where AppKit's
    /// glass draws no specular border of its own.
    private final class SidebarRimView: NSView {
        override var wantsUpdateLayer: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.borderWidth = 0.5
            layer?.cornerRadius = LibraryFloatingSidebar.cornerRadius
            layer?.cornerCurve = .continuous
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updateRimColor()
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            updateRimColor()
        }

        override func updateLayer() {
            super.updateLayer()
            updateRimColor()
        }

        func updateRimColor() {
            let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let rim = AppTheme.current(dark: isDark).card.recipe.frost?.rim
                ?? .white(opacity: isDark ? 0.16 : 0.55)
            layer?.borderColor = rim.nsColor.cgColor
        }
    }

    /// False while an expanded pane's glass wrapper isn't in the window and laid out yet.
    static func update(
        _ window: NSWindow?,
        floating: Bool,
        hasSidebar: Bool = true,
        inspectorVisible: Bool = true
    ) -> Bool {
        guard let content = window?.contentView else { return true }
        var sidebarDone = true
        // ponytail: 27.2+ flattened NavigationSplitView's sidebar glass (26.x already floats it);
        // drop the sidebar branch if a future macOS restores floating sidebars or exposes a public opt-in.
        if #available(macOS 27.2, *), hasSidebar {
            if let sidebar = findPane(behavior: .sidebar, in: content) {
                sidebarDone = sidebar.isCollapsed ? true : updatePane(sidebar, floating: floating, isTrailing: false)
            } else {
                sidebarDone = false
            }
        }
        var inspectorDone = true
        if let inspector = findPane(behavior: .inspector, in: content) {
            if !inspector.isCollapsed {
                inspectorDone = updatePane(inspector, floating: floating, isTrailing: true)
            }
        } else if inspectorVisible {
            inspectorDone = false
        }
        return sidebarDone && inspectorDone
    }

    private static func updatePane(_ pane: Pane, floating: Bool, isTrailing: Bool) -> Bool {
        guard pane.wrapper.frame.width > 0 else { return false }
        let (glass, wrapper, split) = (pane.glass, pane.wrapper, pane.split)
        let lead = floating ? (isTrailing ? innerInset : outerInset) : 0
        let trail = floating ? (isTrailing ? outerInset : innerInset) : 0
        let vert = floating ? verticalInset : 0

        for constraint in wrapper.constraints {
            let isGlassToWrapper = (constraint.firstItem === glass && constraint.secondItem === wrapper)
                || (constraint.firstItem === wrapper && constraint.secondItem === glass)
            guard isGlassToWrapper else { continue }
            switch (constraint.firstAttribute, constraint.secondAttribute) {
            case (.leading, .leading):
                constraint.constant = (constraint.firstItem === glass) ? lead : -lead
            case (.trailing, .trailing):
                constraint.constant = (constraint.firstItem === glass) ? -trail : trail
            case (.top, .top):
                constraint.constant = (constraint.firstItem === glass) ? vert : -vert
            case (.bottom, .bottom):
                constraint.constant = (constraint.firstItem === glass) ? -vert : vert
            case (.width, .width):
                let horizontal = lead + trail
                constraint.constant = (constraint.firstItem === glass) ? -horizontal : horizontal
            default: break
            }
        }

        // On macOS 26, the inspector's NSContainerConcentricGlassEffectView leaves its inner corners square and drops
        // its frost scrim when inactive. Clip its layer to the floating radius (keeping its SwiftUI content intact) and
        // back it with a regular rounded NSGlassEffectView that casts the lift shadow and holds frost when inactive.
        let useBackdropGlass: Bool
        if #available(macOS 27.2, *) {
            useBackdropGlass = false
        } else {
            useBackdropGlass = isTrailing
        }

        let existingBackdrop = wrapper.subviews.first { $0.identifier == paneGlassID }
        let existingRim = wrapper.subviews.first { $0.identifier == rimID }
        let shadowHost: NSView
        if useBackdropGlass {
            glass.wantsLayer = true
            glass.layer?.cornerRadius = floating ? cornerRadius : 0
            glass.layer?.cornerCurve = .continuous
            glass.layer?.masksToBounds = floating
            if floating {
                let backdrop: NSView
                if let existingBackdrop {
                    backdrop = existingBackdrop
                } else {
                    let view = FloatingPaneGlassView()
                    view.identifier = paneGlassID
                    view.style = .regular
                    view.cornerRadius = cornerRadius
                    view.translatesAutoresizingMaskIntoConstraints = false
                    wrapper.addSubview(view, positioned: .below, relativeTo: glass)
                    NSLayoutConstraint.activate([
                        view.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
                        view.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
                        view.topAnchor.constraint(equalTo: glass.topAnchor),
                        view.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
                    ])
                    backdrop = view
                }
                shadowHost = backdrop
            } else {
                existingBackdrop?.removeFromSuperview()
                shadowHost = glass
            }
        } else {
            existingBackdrop?.removeFromSuperview()
            glass.cornerRadius = floating ? cornerRadius : 0
            shadowHost = glass
        }

        if floating {
            wrapper.clipsToBounds = false
            shadowHost.wantsLayer = true
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
            shadow.shadowBlurRadius = 14
            shadow.shadowOffset = NSSize(width: 0, height: -2)
            shadowHost.shadow = shadow
            if useBackdropGlass {
                glass.shadow = nil
                existingRim?.removeFromSuperview()
            } else if let rim = existingRim as? SidebarRimView {
                rim.updateRimColor()
            } else {
                let rim = SidebarRimView()
                rim.identifier = rimID
                rim.translatesAutoresizingMaskIntoConstraints = false
                wrapper.addSubview(rim, positioned: .above, relativeTo: glass)
                NSLayoutConstraint.activate([
                    rim.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
                    rim.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
                    rim.topAnchor.constraint(equalTo: glass.topAnchor),
                    rim.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
                ])
            }
        } else {
            existingRim?.removeFromSuperview()
            glass.shadow = nil
        }

        // Hide the straight full-height divider and shadow strip along the pane's inner edge while floating.
        let edge = isTrailing ? wrapper.frame.minX : wrapper.frame.maxX
        for sibling in split.subviews where sibling !== wrapper {
            let name = NSStringFromClass(type(of: sibling))
            guard (name.contains("Divider") || name.contains("Shadow")),
                  abs(sibling.frame.minX - edge) <= 4 || abs(sibling.frame.maxX - edge) <= 4 else { continue }
            sibling.alphaValue = floating ? 0 : 1
        }
        return true
    }

    private static func findPane(behavior: NSSplitViewItem.Behavior, in root: NSView) -> Pane? {
        if let split = root as? NSSplitView,
           let controller = split.delegate as? NSSplitViewController,
           let item = controller.splitViewItems.first(where: { $0.behavior == behavior }) {
            var current: NSView? = item.viewController.view
            while let view = current, view !== split {
                if let glass = view as? NSGlassEffectView, let wrapper = glass.superview {
                    return Pane(glass: glass, wrapper: wrapper, split: split, isCollapsed: item.isCollapsed)
                }
                current = view.superview
            }
        }
        for subview in root.subviews {
            if let found = findPane(behavior: behavior, in: subview) { return found }
        }
        return nil
    }
}

/// The editor's chrome colour behind a sidebar or inspector column, so the
/// columns and the toolbar read as one flat surface under Reduce Transparency
/// or Increase Contrast. Otherwise macOS's own sidebar glass shows over the
/// window background.
private struct LibrarySidebarSurface: ViewModifier {
    @FloatingGlassChrome private var floatingChrome

    @ViewBuilder
    func body(content: Content) -> some View {
        if floatingChrome {
            content.scrollEdgeEffectStyle(.soft, for: .all)
        } else {
            content
                .scrollContentBackground(.hidden)
                .background {
                    WorkspaceChrome.background.ignoresSafeArea(.container)
                }
        }
    }
}

/// The browser's ground: the editor's dotted workspace behind the grid and
/// the empty pages when the floating glass layout is off; otherwise
/// `LibraryWindowSurface` extends the ground under the whole window.
private struct LibraryBrowserSurface: ViewModifier {
    let showsDots: Bool
    @FloatingGlassChrome private var floatingChrome

    @ViewBuilder
    func body(content: Content) -> some View {
        if showsDots && !floatingChrome {
            content.background { AnnotationEditorWorkspaceBackground().allowsHitTesting(false) }
        } else {
            content
        }
    }
}

/// Straight hairlines between the browser and the sidebar and inspector. The
/// columns share one chrome colour, so in the list nothing else divides them.
/// They stay below the toolbar, which runs unbroken across the window.
/// From 27.2 the split view draws its own dividers there (on 27.0.1 they're
/// clear), so these step aside rather than double them.
private struct LibraryColumnSeparators: ViewModifier {
    let leading: Bool
    let trailing: Bool
    @Environment(\.displayScale) private var displayScale
    @FloatingGlassChrome private var floatingChrome

    @ViewBuilder
    func body(content: Content) -> some View {
        // ponytail: 27.1 unchecked (only 27.0.1 and 27.2 seen); move the
        // cut-off if 27.1 shows doubled or missing lines.
        if #available(macOS 27.2, *) {
            content
        } else {
            content
                .overlay(alignment: .leading) { if leading && !floatingChrome { line } }
                .overlay(alignment: .trailing) { if trailing && !floatingChrome { line } }
        }
    }

    private var line: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1 / displayScale)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The system's line under the toolbar, the one the editor shows. With the
/// toolbar background visible it runs over the browser and inspector; a hard
/// top scroll edge turns it on over the sidebar too. Floating chrome hides
/// the toolbar bar and floats the sidebar, so it leaves the scroll edge soft.
private struct LibraryToolbarSeparator: ViewModifier {
    @FloatingGlassChrome private var floatingChrome

    @ViewBuilder
    func body(content: Content) -> some View {
        if floatingChrome {
            content
        } else {
            content.scrollEdgeEffectStyle(.hard, for: .top)
        }
    }
}

/// The window background behind the split view. Glass with blurred picture paints
/// `GlassBackdrop`; Glass with Solid background paints the solid workspace colour;
/// Classic and Chip extend `AnnotationEditorWorkspaceBackground` under the floating
/// sidebars; Reduce Transparency and Increase Contrast fall back to opaque chrome.
private struct LibraryWindowSurface: ViewModifier {
    @CurrentTheme private var theme
    @DrawnGlass private var glass
    @FloatingGlassChrome private var floatingChrome

    @ViewBuilder
    func body(content: Content) -> some View {
        if let backdrop = glass {
            content
                .environment(\.overGlassPicture, true)
                .background { GlassBackdrop(backdrop: backdrop).backgroundExtensionEffect().ignoresSafeArea() }
        } else if floatingChrome {
            content
                .background {
                    if theme.chrome.glass {
                        Rectangle()
                            .fill(theme.ground.workspace.color)
                            .backgroundExtensionEffect()
                            .ignoresSafeArea()
                    } else {
                        AnnotationEditorWorkspaceBackground()
                            .backgroundExtensionEffect()
                            .ignoresSafeArea()
                    }
                }
        } else {
            content
                .background { WorkspaceChrome.background.ignoresSafeArea() }
                .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        }
    }
}

struct LibrarySecondaryBarSurface: ViewModifier {
    @FloatingGlassChrome private var floatingChrome

    @ViewBuilder
    func body(content: Content) -> some View {
        if floatingChrome {
            content
        } else {
            content
                .background(.bar)
                .overlay(alignment: .bottom) { Divider() }
        }
    }
}

enum CaptureLibrarySidebarSelection: Hashable {
    case kind(CaptureLibraryFilter)
    case cloud
    case files
    case received
    case comments
    case likes
    case clipboard
    case snippets
    case saved
    case tag(String)
}

/// A sidebar row's count, shown only above zero: "Recordings 0" said nothing a missing number doesn't (Fable #10).
private struct SidebarCount: View {
    let value: Int
    init(_ value: Int) { self.value = value }

    var body: some View {
        if value > 0 {
            Text(value, format: .number)
                .foregroundStyle(.secondary)
                .font(.caption.monospacedDigit())
        }
    }
}
