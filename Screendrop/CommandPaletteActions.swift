//
//  CommandPaletteActions.swift
//  Screendrop
//
//  What the palette's commands do in Sukusho, whether each can run now and why not, and the rows of its steps. The
//  commands themselves are data (`PaletteCommand.catalog`); this is the app behind them. Each reaches the code its menu
//  item, button or Settings row already uses, so the palette does what they do.
//

import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class AppCommandPaletteHost: CommandPaletteHost {
    private let context: PaletteWindowContext?
    let window: PaletteWindow
    private let windowTitle: String?

    init(context: PaletteWindowContext?, windowTitle: String?) {
        self.context = context
        self.windowTitle = windowTitle
        switch context {
        case .library: window = .library
        case .editor: window = .editor
        case .studio: window = .studio
        case nil: window = .other
        }
    }

    private var library: LibraryPaletteHooks? { if case .library(let hooks) = context { hooks } else { nil } }
    private var editorHooks: EditorPaletteHooks? { if case .editor(let hooks) = context { hooks } else { nil } }
    private var studioHooks: StudioPaletteHooks? { if case .studio(let hooks) = context { hooks } else { nil } }
    private var editor: AnnotationEditorModel? { editorHooks?.model }
    private var studio: RecordingStudioModel? { studioHooks?.model }
    private var libraryModel: CaptureLibraryModel { .shared }

    /// The Library's selected captures, while the captures (not a Cloud or Clipboard page) are showing.
    private var selection: [CaptureLibraryItem] {
        guard window == .library else { return [] }
        switch CaptureLibrarySidebarSelection.current {
        case .kind, .tag, .saved, nil: return libraryModel.selectedItems
        default: return []
        }
    }

    var selectionTitle: String? {
        let selection = selection
        return selection.count == 1 ? selection[0].title : "\(selection.count) captures"
    }

    var place: String {
        switch window {
        case .library:
            let selection = selection
            return selection.isEmpty ? "Library" : "Library · \(selectionTitle ?? "")"
        case .editor: return ["Editor", windowTitle].compactMap { $0 }.joined(separator: " · ")
        case .studio: return ["Studio", windowTitle].compactMap { $0 }.joined(separator: " · ")
        case .other: return ["Sukusho", windowTitle].compactMap { $0 }.joined(separator: " · ")
        }
    }

    func place(for step: PaletteStep) -> String? {
        switch step {
        case .recentCaptures:
            let count = ScreenshotHistoryStore.shared.items.count
            return count == 1 ? "1 capture" : "\(count) captures"
        case .changeTheme: return isDark ? "Dark theme" : "Light theme"
        case .clipboardHistory: return "Pastes into this window"
        case .addTag: return selectionTitle
        default: return nil
        }
    }

    func keys(for command: PaletteCommand) -> [String] {
        switch command.keys {
        case .none: []
        case .keys(let keys): keys
        case .hotkey(let action): CaptureHotkeyPreferences.shortcut(for: action)?.displayTokens ?? []
        }
    }

    // MARK: State

    func state(of command: PaletteCommand) -> PaletteCommandState {
        let recording = ScreenRecordingManager.shared
        switch command.id {
        case "capture.scrolling":
            var state = PaletteCommandState(title: ScrollingCapturePresenter.shared.isRunning ? "Finish Scrolling Capture" : nil)
            if recording.isActive { state.reason = "not while recording" }
            return state
        case "capture.record":
            if recording.isActive {
                return PaletteCommandState(title: "Stop Recording", symbol: "stop.circle",
                                           reason: recording.state == .finishing ? "finishing the recording" : nil)
            }
            return ScrollingCapturePresenter.shared.isRunning ? .off("not during a scrolling capture") : .ready
        case "capture.draw":
            return recording.state == .recording ? .ready : .off("only while recording")

        case let id where id.hasPrefix("selection."):
            return selectionState(id)

        case "library.sidebar":
            return PaletteCommandState(title: library?.sidebarShown() == false ? "Show Sidebar" : "Hide Sidebar")
        case "library.biggerCards":
            return cardWidth >= LibraryCardWidth.range.upperBound ? .off("already the biggest") : .ready
        case "library.smallerCards":
            return cardWidth <= LibraryCardWidth.range.lowerBound ? .off("already the smallest") : .ready
        case "window.inspector":
            let shown = library?.inspectorShown() ?? editorHooks?.inspectorShown() ?? studioHooks?.inspectorShown() ?? true
            return PaletteCommandState(title: shown ? "Hide Inspector" : "Show Inspector")

        case let id where id.hasPrefix("tool.") || id.hasPrefix("editor."):
            return editorState(id)
        case let id where id.hasPrefix("studio."):
            return studioState(id)

        case "open.clipboardStep":
            return ScreendropPreferences.clipboardHistoryEnabled ? .ready : .hidden
        case "open.clipboardPopup":
            return ScreendropPreferences.clipboardHistoryEnabled || ScreendropPreferences.clipboardLauncherEnabled
                ? .ready : .off("clipboard history is off")
        case "open.recordings":
            return RecordingProjectStore.shared.projects.isEmpty ? .off("no recordings yet") : .ready
        case "open.recent":
            return ScreenshotHistoryStore.shared.items.isEmpty ? .off("no captures yet") : .ready

        case "look.theme":
            return PaletteCommandState(detail: themeName(AppTheme.current(dark: isDark)))
        case "look.appearance":
            return PaletteCommandState(detail: appearance.title)
        case "look.background":
            return PaletteCommandState(detail: backgroundChoice.style.title)

        case let id where id.hasPrefix("switch."):
            return PaletteCommandState(isOn: switchIsOn(id))

        case "app.checkUpdates":
            return UpdaterManager.shared.canCheckForUpdates ? .ready : .off("a check can’t start now")
        default:
            return .ready
        }
    }

    /// The Library's right-click menu for the selection, by title: what it offers now, and its action.
    private func menuItem(_ title: String) -> LibraryMenuItem? {
        libraryModel.menuItems(selected: selection.count).first { $0.title == title }
    }

    private static let selectionMenuTitles: [String: String] = [
        "selection.quickLook": "Quick Look", "selection.edit": "Edit", "selection.rename": "Rename", "selection.copy": "Copy",
        "selection.export": "Export…", "selection.share": "Share…", "selection.reveal": "Reveal in Finder",
        "selection.trash": "Move to Trash", "selection.revert": "Revert to Original…", "selection.optimize": "Optimize",
        "selection.webp": "Convert to WebP…", "selection.jpeg": "Convert to JPEG…", "selection.gif": "Export as GIF…",
        "selection.bugReport": "Export Bug Report", "selection.guide": "Export How-To Guide",
        "selection.shareCloud": "Share to Cloud…", "selection.copyLink": "Copy Link",
        "selection.openShared": "Open Shared Capture", "selection.deleteCloud": "Delete from Cloud…",
    ]

    private func selectionState(_ id: String) -> PaletteCommandState {
        let selection = selection
        guard !selection.isEmpty else { return .hidden }
        let one = selection.count == 1 ? selection[0] : nil
        if libraryModel.isBusy { return .off("wait for the Library to finish") }
        switch id {
        case "selection.copyOriginal":
            return .ready
        case "selection.copyText":
            guard let one else { return .off("one capture at a time") }
            return textParagraphs(one).isEmpty ? .off("no text read in it") : .ready
        case "selection.addTag":
            return .ready
        default:
            guard let title = Self.selectionMenuTitles[id] else { return .ready }
            if let item = menuItem(title) {
                if item.isEnabled { return .ready }
                return .off(item.subtitle ?? (selection.count > 1 ? "one capture at a time" : "not now"))
            }
            return .off(absentReason(id, one: one, count: selection.count))
        }
    }

    /// Why the Library's menu leaves a command out for this selection.
    private func absentReason(_ id: String, one: CaptureLibraryItem?, count: Int) -> String {
        switch id {
        case "selection.revert": return one == nil ? "one capture at a time" : "not edited yet"
        case "selection.optimize", "selection.webp", "selection.jpeg": return "screenshots only"
        case "selection.gif": return one == nil ? "one recording at a time" : "recordings only"
        case "selection.bugReport", "selection.guide": return one == nil ? "one recording at a time" : "recording projects only"
        case "selection.shareCloud":
            if !CloudUploader.shared.isConfigured { return "Cloud isn’t set up" }
            if one?.cloudURL != nil { return "already shared" }
            return "can’t share these together"
        case "selection.copyLink", "selection.openShared", "selection.deleteCloud":
            return one == nil ? "one capture at a time" : "not shared yet"
        default: return "not now"
        }
    }

    private func textParagraphs(_ item: CaptureLibraryItem) -> [String] {
        CaptureLibraryIndex.shared.entries[item.id]?.displayParagraphs ?? []
    }

    private static let tools: [String: AnnotationTool] = [
        "tool.select": .select, "tool.rectangle": .rectangle, "tool.ellipse": .ellipse, "tool.highlight": .highlight,
        "tool.arrow": .arrow, "tool.line": .line, "tool.freehand": .freehand, "tool.highlighter": .highlighter,
        "tool.text": .text, "tool.numberedCircle": .numberedCircle, "tool.magnifier": .magnifier,
        "tool.pixelate": .pixelate, "tool.blur": .blur,
    ]

    private func editorState(_ id: String) -> PaletteCommandState {
        guard let editor else { return .hidden }
        let loaded = editor.imageSize != .zero
        if let tool = Self.tools[id] {
            guard loaded else { return .off("loading") }
            return PaletteCommandState(detail: editor.selectedTool == tool && !editor.isCropping ? "Tool · in use" : "Tool")
        }
        switch id {
        case "editor.crop":
            return PaletteCommandState(title: editor.isCropping ? "Cancel Crop" : nil, reason: loaded ? nil : "loading")
        case "editor.biggerText", "editor.smallerText":
            return editor.canStepTextSize ? .ready : .off("select a text first")
        case "editor.save":
            return editor.hasUnsavedChanges ? .ready : .off("no changes to save")
        case "editor.revertTo":
            return editor.isCropping || editor.isBlockingCommit ? .off("finish cropping first") : .ready
        case "editor.styles":
            if editor.sourceURL == nil { return .off("loading") }
            return AnnotationBackgroundPresetStore.shared.presets.isEmpty ? .off("no saved styles yet") : .ready
        default:
            return loaded ? .ready : .off("loading")
        }
    }

    private func studioState(_ id: String) -> PaletteCommandState {
        guard let studio else { return .hidden }
        let canControl = studio.isLoaded && !studio.isRestoringDocument && !studio.isEditingSourceRegion
        let notNow = PaletteCommandState.off(studio.isEditingSourceRegion ? "finish cropping first" : "loading")
        switch id {
        case "studio.save":
            guard studio.isProject else { return .hidden }
            return studio.hasUnsavedChanges ? .ready : .off("no changes to save")
        case "studio.revertTo":
            guard studio.isProject else { return .hidden }
            return studio.canRevert ? .ready : .off("nothing to revert")
        case "studio.bugReport", "studio.guide":
            if id == "studio.guide", studio.session == nil { return .hidden }
            let blocked = !studio.isLoaded || studio.hasRunningWork || studio.hasUnreadableDraft || studio.isReadOnlyNewerFormat
                || studio.transcriptionState.isTranscribing
            return blocked ? .off("wait for Studio to finish") : .ready
        case "studio.snapping":
            return PaletteCommandState(reason: canControl ? nil : notNow.reason, isOn: studio.snapsEdits)
        default:
            break
        }
        guard canControl else { return notNow }
        switch id {
        case "studio.insertClip": return studio.canImportVideoClip ? .ready : .off("not now")
        case "studio.split": return studio.clipTimeline.split(at: studio.currentTime) == nil ? .off("can’t split here") : .ready
        case "studio.deleteRange", "studio.clearRange": return studio.rangeSelection == nil ? .off("no marked range") : .ready
        case "studio.clipEarlier": return studio.canMoveSelectedClipEarlier ? .ready : .off("select a clip that can move")
        case "studio.clipLater": return studio.canMoveSelectedClipLater ? .ready : .off("select a clip that can move")
        case "studio.transcribe":
            if studio.transcriptionState.isTranscribing { return .off("transcribing now") }
            return PaletteCommandState(title: studio.hasTranscriptWords ? "Transcribe Again" : nil)
        case "studio.summarize":
            if let reason = studio.textModelUnavailableReason { return .off(reason) }
            return studio.isSummarizing ? .off("summarizing now") : .ready
        case "studio.nameChapters":
            if let reason = studio.textModelUnavailableReason { return .off(reason) }
            return studio.isNamingChapters ? .off("naming now") : .ready
        case "studio.suggestChapters", "studio.removeFillers", "studio.shortenPauses":
            return studio.hasTranscriptWords ? .ready : .off("transcribe the narration first")
        default: return .ready
        }
    }

    // MARK: Running

    func run(_ command: PaletteCommand) -> PaletteOutcome {
        if command.isSwitch { flip(command.id); return .stay }
        let action = action(for: command.id)
        // Once the palette is gone: a capture mustn't catch it, and the window's keys need that window key again.
        CommandPalettePresenter.shared.whenClosed(action)
        return .close
    }

    private func action(for id: String) -> () -> Void {
        let library = library, editorHooks = editorHooks, studioHooks = studioHooks
        let editor = editor, studio = studio, model = libraryModel
        if let title = Self.selectionMenuTitles[id] {
            return { [weak self] in self?.menuItem(title)?.perform() }
        }
        if let tool = Self.tools[id] { return { editorHooks?.selectTool(tool) } }
        switch id {
        case "capture.fullscreen": return { CaptureCoordinator.shared.captureFullscreen() }
        case "capture.window": return { CaptureCoordinator.shared.captureWindow() }
        case "capture.area": return { CaptureCoordinator.shared.captureArea() }
        case "capture.scrolling": return { CaptureCoordinator.shared.captureScrolling() }
        case "capture.text": return { CaptureCoordinator.shared.captureText() }
        case "capture.record":
            return {
                if ScreenRecordingManager.shared.isActive { ScreenRecordingManager.shared.stopRecording() }
                else { RecordingBarPresenter.shared.showPicker() }
            }
        case "capture.draw": return { RecordingInkPresenter.shared.toggleFromShortcut() }

        case "selection.copyOriginal": return { model.perform(.copyOriginal) }
        case "selection.copyText":
            return { [weak self] in
                guard let self, let item = self.selection.first else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(self.textParagraphs(item).joined(separator: "\n\n"), forType: .string)
                model.actionFeedback.show("Copied Text")
            }

        case "library.refresh": return { library?.refresh() }
        case "library.find": return { library?.find() }
        case "library.biggerCards": return { [weak self] in self?.stepCards(by: 1) }
        case "library.smallerCards": return { [weak self] in self?.stepCards(by: -1) }
        case "library.sidebar": return { library?.toggleSidebar() }
        case "window.inspector":
            return {
                if let library { library.toggleInspector() }
                else if let editorHooks { editorHooks.toggleInspector() }
                else { studioHooks?.toggleInspector() }
            }

        case "editor.crop": return { withAnimation(.canvasMoveIfAllowed) { editor?.toggleCropping() } }
        case "editor.pickColor": return { editorHooks?.pickColor() }
        case "editor.measure": return { editorHooks?.measure() }
        case "editor.biggerText": return { editor?.stepTextSize(by: 1) }
        case "editor.smallerText": return { editor?.stepTextSize(by: -1) }
        case "editor.zoomIn": return { editor?.zoomIn() }
        case "editor.zoomOut": return { editor?.zoomOut() }
        case "editor.actualSize": return { editor?.setZoomPercent(100) }
        case "editor.zoomToFit": return { editor?.fitCanvas() }
        case "editor.save": return { editor?.requestSave() }
        case "editor.saveAs": return { editor?.requestSaveAs() }

        case "studio.insertClip": return { studio?.presentInsertVideoClipPanel() }
        case "studio.split": return { if let studio { studio.splitClip(at: studio.currentTime) } }
        case "studio.markIn": return { studio?.markRange(.start) }
        case "studio.markOut": return { studio?.markRange(.end) }
        case "studio.deleteRange": return { studio?.deleteRange() }
        case "studio.clearRange": return { studio?.clearRange() }
        case "studio.clipEarlier": return { studio?.moveSelectedClip(by: -1) }
        case "studio.clipLater": return { studio?.moveSelectedClip(by: 1) }
        case "studio.marker": return { studio?.toggleMarker() }
        case "studio.addZoom": return { if let studio { studio.addZoomCue(at: studio.currentTime) } }
        case "studio.addText": return { if let studio { studio.addText(atEditorTime: studio.currentTime) } }
        case "studio.transcribe": return { studio?.transcribe() }
        case "studio.summarize": return { studio?.summarize() }
        case "studio.suggestChapters": return { studio?.suggestChapters() }
        case "studio.nameChapters": return { studio?.nameChapters() }
        case "studio.removeFillers": return { studio?.removeFillerWords() }
        case "studio.shortenPauses": return { studio?.shortenPauses() }
        case "studio.save": return { _ = studio?.saveProject() }
        case "studio.bugReport": return { studio?.exportAgentPrompt() }
        case "studio.guide": return { studio?.exportGuide() }
        case "studio.goToStart": return { studio?.pause(); studio?.seek(to: 0) }
        case "studio.goToEnd": return { if let studio { studio.pause(); studio.seek(to: studio.duration) } }

        case "open.library": return { CaptureLibraryModel.shared.show() }
        case "open.clipboardPopup": return { ClipboardPopupPresenter.shared.show() }
        case "open.saveFolder": return Self.openSaveFolder

        case "app.settings": return { SettingsWindowController.show(tab: .general) }
        case "app.checkUpdates": return { UpdaterManager.shared.checkForUpdates() }
        case "app.about": return { AboutWindowController.show() }
        case "app.quit": return { NSApp.terminate(nil) }
        default: return {}
        }
    }

    private var cardWidth: Double {
        UserDefaults.standard.object(forKey: "captureLibrary.cardWidth") as? Double ?? 220
    }

    /// View › Bigger Cards and Smaller Cards, on the setting the Library's slider and those items share.
    private func stepCards(by direction: Int) {
        UserDefaults.standard.set(LibraryCardWidth.stepped(cardWidth, by: direction), forKey: "captureLibrary.cardWidth")
    }

    private static func openSaveFolder() {
        let directory = ScreendropPreferences.exportDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !NSWorkspace.shared.open(directory) { NSSound.beep() }
    }

    // MARK: Switches

    private func switchIsOn(_ id: String) -> Bool {
        let defaults = UserDefaults.standard
        switch id {
        case "switch.optimizeNew": return OptimizePreferences.newCaptures
        case "switch.optimizeCopy": return OptimizePreferences.whenCopying
        case "switch.cleanDesktop": return defaults.object(forKey: ScreendropPreferences.recordingCleanDesktopKey) as? Bool ?? true
        case "switch.sounds": return defaults.object(forKey: ScreendropPreferences.playSoundsKey) as? Bool ?? true
        case "switch.menuBarIcon": return defaults.object(forKey: ScreendropPreferences.showMenuBarIconKey) as? Bool ?? true
        case "switch.launchAtLogin": return SMAppService.mainApp.status == .enabled
        case "switch.betaUpdates": return UpdateChannels.getsBetas()
        default: return false
        }
    }

    /// Flips a switch as its Settings row does, on the same setting.
    private func flip(_ id: String) {
        let on = !switchIsOn(id)
        let defaults = UserDefaults.standard
        switch id {
        case "switch.optimizeNew": defaults.set(on, forKey: OptimizePreferences.newCapturesKey)
        case "switch.optimizeCopy": defaults.set(on, forKey: OptimizePreferences.whenCopyingKey)
        case "switch.cleanDesktop": defaults.set(on, forKey: ScreendropPreferences.recordingCleanDesktopKey)
        case "switch.sounds": defaults.set(on, forKey: ScreendropPreferences.playSoundsKey)
        case "switch.menuBarIcon": defaults.set(on, forKey: ScreendropPreferences.showMenuBarIconKey)
        case "switch.launchAtLogin":
            do { try on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() }
            catch { NSSound.beep() }
        case "switch.betaUpdates": defaults.set(on, forKey: UpdateChannels.betaKey)
        default: break
        }
    }

    // MARK: Steps

    private var isDark: Bool { NSApp.effectiveAppearance.isDarkAppearance }

    private var appearance: AppAppearance {
        UserDefaults.standard.string(forKey: AppAppearance.key).flatMap(AppAppearance.init) ?? .automatic
    }

    private var destination: BackgroundDestination { window == .editor || window == .studio ? .editors : .app }

    private var backgroundChoice: BackgroundChoice {
        WindowBackgroundStore.shared.choice(for: destination, theme: AppTheme.current(dark: isDark))
    }

    /// "Classic Light" is Classic in a list of the light themes.
    private func themeName(_ theme: AppTheme) -> String {
        theme.name.replacingOccurrences(of: theme.isDark ? " Dark" : " Light", with: "")
    }

    /// The Library's sidebar rows, as it shows them now.
    private var pages: [(id: String, page: CaptureLibrarySidebarSelection, title: String, symbol: String)] {
        let clipboardOn = ScreendropPreferences.clipboardHistoryEnabled
        var pages = CaptureLibraryFilter.allCases.map { ("kind.\($0.rawValue)", CaptureLibrarySidebarSelection.kind($0), $0.title, $0.symbol) }
        pages.append(("clipboard", .clipboard, "Clipboard", "doc.on.clipboard"))
        pages.append(("saved", .saved, "Saved", "star"))
        if clipboardOn { pages.append(("snippets", .snippets, "Snippets", "text.badge.star")) }
        if CloudUploader.shared.isConfigured {
            pages += [("cloud", .cloud, "Uploads", "cloud"), ("files", .files, "Files", "doc"),
                      ("received", .received, "Received", "tray.and.arrow.down"),
                      ("comments", .comments, "Comments", "bubble.left.and.bubble.right"), ("likes", .likes, "Likes", "heart")]
        } else {
            pages.append(("cloud", .cloud, "Set Up Cloud", "cloud"))
        }
        pages += libraryModel.tags.map { ("tag.\($0)", CaptureLibrarySidebarSelection.tag($0), $0, "tag") }
        return pages
    }

    func rows(for step: PaletteStep, query: String) -> [PaletteRow] {
        switch step {
        case .commands:
            return []
        case .recentCaptures:
            let items = ScreenshotHistoryStore.shared.items.prefix(30).map { item in
                PaletteRow(id: item.id.uuidString, title: item.displayName ?? (item.fileName as NSString).deletingPathExtension,
                           subtitle: "\(item.isVideo ? "Recording" : "Screenshot") · \(item.pixelWidth) × \(item.pixelHeight) · "
                               + CaptureLibraryItem.dateTitle(item.createdAt),
                           thumbnail: item.url)
            }
            return items + [PaletteRow(id: "all", title: "Show All Captures…", symbol: "square.grid.2x2")]
        case .recordings:
            let projects = RecordingProjectStore.shared.recentProjects.map { project in
                PaletteRow(id: project.session.directoryURL.path, title: project.displayName,
                           detail: project.hasUnsavedDraft ? "Unsaved" : "",
                           subtitle: CaptureLibraryItem.dateTitle(project.createdAt), thumbnail: project.session.deliverableURL)
            }
            return projects + [PaletteRow(id: "all", title: "Show All Recordings…", symbol: "square.grid.2x2")]
        case .clipboardHistory:
            // The ⌃⌘V popup's own list and search.
            return clipEntries(query).map { entry in
                PaletteRow(id: entry.id, title: ClipboardList.title(of: entry),
                           symbol: entry.kind == .image ? "photo" : entry.kind == .text ? "text.alignleft" : "doc")
            }
        case .goTo:
            let current = window == .library ? CaptureLibrarySidebarSelection.current : nil
            return pages.map { PaletteRow(id: $0.id, title: $0.title, detail: "Library", symbol: $0.symbol, ticked: $0.page == current) }
        case .searchCaptures:
            let typed = query.trimmingCharacters(in: .whitespaces)
            // The model's own offer: ↩ searches with what's typed.
            return typed.isEmpty ? [] : [PaletteRow(id: CommandPaletteModel.searchCapturesID, title: "Search captures for “\(typed)”",
                                                    symbol: "magnifyingglass")]
        case .goToSettings:
            return SettingsTab.allCases.map { PaletteRow(id: $0.rawValue, title: $0.title, detail: "Settings", symbol: $0.systemImage) }
        case .addTag:
            let selection = selection
            let typed = query.trimmingCharacters(in: .whitespaces)
            var rows = libraryModel.tags
                .filter { typed.isEmpty || $0.localizedCaseInsensitiveContains(typed) }
                .map { tag in PaletteRow(id: "tag.\(tag)", title: tag, ticked: !selection.isEmpty && selection.allSatisfy { $0.tags.contains(tag) }) }
            if !typed.isEmpty, !libraryModel.tags.contains(where: { $0.caseInsensitiveCompare(typed) == .orderedSame }) {
                rows.insert(PaletteRow(id: "new-tag", title: "Add tag “\(typed)”"), at: 0)
            }
            return rows
        case .sortBy:
            return CaptureLibrarySort.allCases.map { PaletteRow(id: $0.rawValue, title: $0.title, ticked: libraryModel.sortOrder == $0) }
        case .revertTo:
            return revertRows
        case .styles:
            guard let editor else { return [] }
            return AnnotationBackgroundPresetStore.shared.presets.map {
                PaletteRow(id: $0.id.uuidString, title: $0.name, symbol: "paintbrush", ticked: editor.appliedBackgroundPresetID == $0.id)
            }
        case .changeTheme:
            let saved = AppTheme.named(UserDefaults.standard.string(forKey: isDark ? AppTheme.darkKey : AppTheme.lightKey), dark: isDark)
            return AppTheme.builtIns.filter { $0.isDark == isDark }.map {
                PaletteRow(id: $0.id, title: themeName($0), detail: $0.id == saved.id ? "in use" : "", ticked: $0.id == saved.id)
            }
        case .appearance:
            return AppAppearance.allCases.map { PaletteRow(id: $0.rawValue, title: $0.title, ticked: $0 == appearance) }
        case .background:
            let current = backgroundChoice.style
            return [WorkspaceBackground.Style.grid, .plain, .wallpaper].map {
                PaletteRow(id: $0.rawValue, title: $0.title, detail: destination == .editors ? "Editors" : "App Windows",
                           ticked: $0 == current)
            }
        }
    }

    private func clipEntries(_ query: String) -> [ClipboardEntry] {
        guard ScreendropPreferences.clipboardHistoryEnabled else { return [] }
        let typed = query.trimmingCharacters(in: .whitespaces)
        return Array(ClipboardHistoryModel.shared.sections(filter: .all, query: typed, includesSnippets: !typed.isEmpty)
            .flatMap(\.entries).prefix(50))
    }

    /// A clip by id, wherever the step's search found it.
    private func clipEntry(_ id: String) -> ClipboardEntry? {
        ClipboardHistoryModel.shared.sections(filter: .all, query: "", includesSnippets: true).lazy.flatMap(\.entries).first { $0.id == id }
    }

    private var revertRows: [PaletteRow] {
        if let editor {
            let blocked = editor.isCropping || editor.isBlockingCommit
            return [PaletteRow(id: "original", title: "Original", reason: editor.canRevertToOriginal ? nil : "this is the original"),
                    PaletteRow(id: "lastOpened", title: "Last Opened", reason: editor.canRevertToLastOpened ? nil : "no changes since")]
                + editor.previousSessionSnapshots.map {
                    PaletteRow(id: $0.id.uuidString, title: $0.title, reason: blocked ? "finish cropping first" : nil)
                }
        }
        if let studio {
            return [PaletteRow(id: "original", title: "Original"),
                    PaletteRow(id: "lastOpened", title: "Last Opened", reason: studio.hasEditsSinceOpening ? nil : "no changes since")]
                + studio.previousSessionSnapshots.map { PaletteRow(id: $0.id.uuidString, title: $0.title) }
        }
        return []
    }

    func choose(_ row: PaletteRow, in step: PaletteStep) -> PaletteOutcome {
        let id = row.choiceID
        switch step {
        case .commands:
            return .close
        case .recentCaptures:
            if id == "all" { return later { CaptureLibraryModel.shared.show(filter: .all) } }
            guard let item = ScreenshotHistoryStore.shared.items.first(where: { $0.id.uuidString == id }) else { return .close }
            // Opens it in its editor, as the owner chose (sd-458l), a recording in Studio.
            return later {
                if item.isVideo { PreviewPanelPresenter.shared.onEditVideo?(item.url) }
                else { PreviewPanelPresenter.shared.onAnnotate?(item.url) }
            }
        case .recordings:
            if id == "all" { return later { CaptureLibraryModel.shared.show(filter: .recordings) } }
            guard let project = RecordingProjectStore.shared.recentProjects.first(where: { $0.session.directoryURL.path == id }) else {
                return .close
            }
            return later { RecordingProjectOpener.shared.open(project.session) }
        case .clipboardHistory:
            guard let entry = clipEntry(id) else { return .close }
            // Into the Sukusho window the palette opened over, which has the keyboard back by then: the palette is gone
            // before the clip goes back on the clipboard and ⌘V is typed.
            return later { ClipboardHistoryModel.shared.deliver(entry, as: .paste, to: .current) }
        case .goTo:
            guard let page = pages.first(where: { $0.id == id })?.page else { return .close }
            return later {
                CaptureLibraryModel.shared.show()
                CaptureLibrarySidebarSelection.show(page)
            }
        case .searchCaptures:
            return .close   // its one row is the model's search offer, which never comes here
        case .goToSettings:
            guard let tab = SettingsTab(rawValue: id) else { return .close }
            return later { SettingsWindowController.show(tab: tab) }
        case .addTag:
            if id == "new-tag" {
                let name = row.title.dropFirst("Add tag “".count).dropLast()
                libraryModel.setTag(String(name), applied: true)
            } else if id.hasPrefix("tag.") {
                libraryModel.setTag(String(id.dropFirst(4)), applied: !row.ticked)
            }
            return .stay
        case .sortBy:
            if let sort = CaptureLibrarySort(rawValue: id) { libraryModel.sortOrder = sort }
            return .close
        case .revertTo:
            return later { [editor, studio] in
                switch id {
                case "original":
                    if let editor { editor.revertToOriginal() } else { studio?.revertToOriginal() }
                case "lastOpened":
                    if let editor { editor.revertToLastOpened() } else { studio?.revertToLastOpened() }
                default:
                    if let snapshot = editor?.previousSessionSnapshots.first(where: { $0.id.uuidString == id }) {
                        editor?.revertToSession(snapshot)
                    } else if let snapshot = studio?.previousSessionSnapshots.first(where: { $0.id.uuidString == id }) {
                        studio?.revertToSession(snapshot)
                    }
                }
            }
        case .styles:
            if let preset = AnnotationBackgroundPresetStore.shared.presets.first(where: { $0.id.uuidString == id }) {
                editor?.applyBackgroundPreset(preset)
            }
            return .close
        case .changeTheme:
            // Kept: the setting changes and every window follows it, as Settings › Appearance's menu does.
            UserDefaults.standard.set(id, forKey: isDark ? AppTheme.darkKey : AppTheme.lightKey)
            ThemeTryOn.show(nil, dark: isDark)
            return .close
        case .appearance:
            UserDefaults.standard.set(id, forKey: AppAppearance.key)
            AppAppearance.apply()
            return .close
        case .background:
            guard let style = WorkspaceBackground.Style(rawValue: id) else { return .close }
            let store = WindowBackgroundStore.shared
            var choices = store.preferences.backgrounds(for: destination, theme: AppTheme.current(dark: isDark))
            if choices.usesNight && store.isNight { choices.night.style = style } else { choices.day.style = style }
            store.preferences[destination] = choices
            return .close
        }
    }

    private func later(_ action: @escaping () -> Void) -> PaletteOutcome {
        CommandPalettePresenter.shared.whenClosed(action)
        return .close
    }

    func copy(_ row: PaletteRow, in step: PaletteStep) {
        switch step {
        case .recentCaptures:
            guard let item = ScreenshotHistoryStore.shared.items.first(where: { $0.id.uuidString == row.choiceID }) else { return }
            if let capture = libraryModel.items.first(where: { $0.historyIDs.contains(item.id) }) {
                libraryModel.copySelection([.capture(capture)])
            } else {
                // The Library hasn't loaded its captures this run: the file itself.
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([item.url as NSURL])
            }
        case .clipboardHistory:
            if let entry = clipEntry(row.choiceID) { ClipboardHistoryModel.shared.deliver(entry, as: .copy, to: nil) }
        default:
            break
        }
    }

    func tryOn(_ row: PaletteRow?) {
        ThemeTryOn.show(row?.choiceID, dark: isDark)
    }

    func searchCaptures(for text: String) {
        CommandPalettePresenter.shared.whenClosed {
            CaptureLibraryModel.shared.show(filter: .all)
            CaptureLibraryModel.shared.searchText = text
        }
    }
}
