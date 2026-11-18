//
//  ScreendropApp.swift
//  Screendrop
//
//  Created by Fayaz Ahmed Aralikatti on 26/04/26.
//

import SwiftUI
import UniformTypeIdentifiers
import UserNotifications
import Carbon

/// Started by `AppEntry`, after the one-time Screendrop import.
struct ScreendropApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.openWindow) var openWindow
    @AppStorage(ScreendropPreferences.showMenuBarIconKey) private var showMenuBarIcon = true

    var body: some Scene {
        let _ = configurePreviewPresentation()

        MenuBarExtra("Sukusho", image: "MenuBarIcon", isInserted: $showMenuBarIcon) {
            MenuBarView()
        }

        Window("Sukusho Library", id: "CAPTURE_LIBRARY") {
            CaptureLibraryView()
        }
        .defaultSize(width: 1180, height: 760)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Sukusho") { AboutWindowController.show() }
                CheckForUpdatesCommand()
            }
            CommandGroup(after: .newItem) {
                Button { CaptureLibraryModel.shared.show() } label: {
                    Text("Show Library")
                    if let subtitle = MenuBarView.subtitle(for: .library) { Text(subtitle) }
                }
                .keyboardShortcut(MenuBarView.shortcut(for: .library))
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { SettingsWindowController.show(tab: .general) }
                    .keyboardShortcut(",", modifiers: .command)
            }
            // Fable's #6: the menu bar holds the app, so its shortcuts can be found there.
            CommandMenu("Capture") { CaptureMenuItems() }
            SidebarCommands()
            InspectorCommands()
            CommandGroup(before: .toolbar) {
                AnnotationEditorZoomCommands()
                LibraryCardSizeCommands()
            }
        }
        
        WindowGroup("Sukusho Annotate", id: "ANNOTATION_EDITOR", for: URL.self) { value in
            AnnotationEditorWindow(url: value)
        }
        .commands {
            // After New, not Save: this app's File menu drops the .saveItem
            // group (after or replacing), so Save As… never showed there.
            CommandGroup(after: .newItem) {
                AnnotationEditorSaveCommand()
                AnnotationEditorSaveAsCommand()
                AnnotationEditorRevertCommand()
            }
            CommandMenu("Format") {
                AnnotationEditorTextSizeCommands()
            }
            CommandMenu("Tools") {
                AnnotationEditorToolCommands()
            }
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 1100, height: 760)

        WindowGroup("Sukusho Recording Editor", id: "VIDEO_EDITOR", for: URL.self) { value in
            RecordingStudioWindow(url: value)
        }
        .commands {
            CommandGroup(after: .newItem) {
                RecordingStudioSaveCommand()
                RecordingStudioAgentPromptCommand()
                RecordingStudioRevertCommand()
            }
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 1360, height: 860)
    }

    @MainActor
    private func configurePreviewPresentation() {
        CaptureLibraryModel.shared.installOpener { [openWindow] in
            openWindow(id: "CAPTURE_LIBRARY")
        }
        PreviewPanelPresenter.shared.onAnnotate = { [openWindow] url in
            openWindow(id: "ANNOTATION_EDITOR", value: url)
        }
        let openVideoEditor: (URL) -> Void = { [openWindow] url in
            let editorURL = ScreenshotHistoryStore.shared.editorURL(for: url)
            openWindow(id: "VIDEO_EDITOR", value: editorURL)
            // Refocusing an existing Studio window does not run its load task
            // again. New windows dismiss their card after a successful load.
            if StudioProjectRegistry.shared.hasLoadedEditor(for: editorURL) {
                ScreenshotPreviewStack.shared.dismissVideo(for: editorURL)
            }
        }
        PreviewPanelPresenter.shared.onEditVideo = openVideoEditor
        // The menu bar extra has no scene of its own, so it reaches Studio
        // through this opener.
        RecordingProjectOpener.shared.openHandler = openVideoEditor

        CaptureCoordinator.shared.onShowPreview = { [openWindow] url, displayID, source in
            // Set the editor openers first so auto-annotate can fire during add.
            PreviewPanelPresenter.shared.onAnnotate = { url in
                openWindow(id: "ANNOTATION_EDITOR", value: url)
            }
            PreviewPanelPresenter.shared.onEditVideo = openVideoEditor

            let historyURL = ScreenshotHistoryStore.shared.importScreenshot(from: url, source: source)
            await ScreenshotPreviewStack.shared.add(url: historyURL)

            if AfterCaptureActions.isEnabled(.showOverlay, for: .screenshot) {
                PreviewPanelPresenter.shared.show(displayID: displayID)
            }

            return historyURL
        }

        appDelegate.onOpenFiles = { [openWindow] urls in
            for url in urls where UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true {
                let historyURL = ScreenshotHistoryStore.shared.importScreenshot(from: url, title: url.deletingPathExtension().lastPathComponent)
                openWindow(id: "ANNOTATION_EDITOR", value: historyURL)
            }
        }

        ScreenRecordingManager.shared.onFinishRecording = { session, displayID in
            Task { @MainActor in
                // A recording session is already an editable project: the
                // screen, camera, audio, and event tracks do not need to be
                // flattened before Studio can open them. Rendering here made
                // Stop behave like Export and blocked short recordings behind
                // a full-resolution transcode.
                let historyURL = await ScreenshotHistoryStore.shared.importRecordingSession(session)
                RecordingProjectStore.shared.reload()
                // A bug report goes straight to its Agent Prompt: no preview card, after-capture actions or Studio.
                if session.loadCaptureManifest()?.isBugReport == true {
                    // With Include app logs on, the user sees the log and chooses before it joins the prompt.
                    await RecordingAppLogsReview.collect(for: session)
                    // The Library comes forward to say why it failed; the bar is gone and the app was behind.
                    if await !CaptureLibraryModel.shared.exportBugReport(session) { CaptureLibraryModel.shared.show() }
                    return
                }
                ScreenshotPreviewStack.shared.addVideo(url: historyURL)
                if AfterCaptureActions.isEnabled(.showOverlay, for: .recording) {
                    PreviewPanelPresenter.shared.show(displayID: displayID)
                }
            }
        }
    }
}

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var openedFilesAtLaunch = false

    /// Files handed to us via Finder's "Open With" (or `open -a Sukusho`)
    /// before `onOpenFiles` is wired up, e.g. a cold launch where SwiftUI's
    /// scene body - and therefore the `openWindow` closure - hasn't run yet.
    private var pendingOpenURLs: [URL] = []
    var onOpenFiles: (([URL]) -> Void)? {
        didSet {
            guard let onOpenFiles, !pendingOpenURLs.isEmpty else { return }
            let urls = pendingOpenURLs
            pendingOpenURLs = []
            onOpenFiles(urls)
        }
    }

    /// The notification delegate has to be in place *before* launch
    /// finishes, or the system handles clicks on export notifications
    /// itself - activating the app and never calling us back to reveal the
    /// file. `applicationDidFinishLaunching` is already too late.
    func applicationWillFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = RecordingExportNotificationDelegate.shared
        // Before the Library opens, so it doesn't appear in the other appearance first.
        AppAppearance.apply()
        // No window here uses tabs, so View has no "Show Tab Bar" or "Show All Tabs" (Fable 15).
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        #if DEBUG
        if RecordingExportBenchmark.runIfRequested() { return }
        #endif
        HotkeyManager.shared.registerHotkeys()
        // The Library's Grid/List choice, saved before List view went (sd-vkd).
        UserDefaults.standard.removeObject(forKey: "captureLibrary.layout")
        ImageTextWarmUp.shared.start()
        CaptureLibraryIndex.shared.start()
        FileRequestsModel.shared.start()
        ShakeToUpload.shared.update()
        // Results the last session left for a paste or an upload: nothing needs them now.
        try? FileManager.default.removeItem(at: ImageOptimizer.shared.outputDirectory)
        AgentAccess.shared.start()
        ClipboardMonitor.shared.update()
        // shortcut: a fixed 3 s lets the Library or an editor open first, so Sparkle's question on the second
        // launch lands in front of it, not behind (seen in the VM); start it from that window's appearance if one ever opens later.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { UpdaterManager.shared.start() }
        RecordingRecoveryCoordinator.recoverInterruptedRecordings()
        let launchEvent = NSAppleEventManager.shared().currentAppleEvent
        let launchReason = launchEvent?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue
        // An agent's helper starting Sukusho keeps it in the menu bar, as a login launch does.
        let launchedInBackground = launchReason == keyAELaunchedAsLogInItem
            || launchReason == keyAELaunchedAsServiceItem
            || CommandLine.arguments.contains(AgentAccess.launchArgument)
        // Let Finder's open-file event reach its editor without also opening a
        // Library. Login/service launches keep the existing quiet menu-bar mode.
        DispatchQueue.main.async { [weak self] in
            guard let self, !launchedInBackground, !self.openedFilesAtLaunch else { return }
            CaptureLibraryModel.shared.show()
        }
        // Below the macOS this build is tested on, say so, in front of the Library and before
        // Sparkle's question; not when an agent's helper started the app. Then, once, any shortcut
        // macOS's own screenshot shortcuts also use: each notice waits for the one before.
        if !CommandLine.arguments.contains(AgentAccess.launchArgument) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                UnsupportedOSNotice.showIfNeeded()
                ShortcutClashNotice.showIfNeeded()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AgentAccess.shared.stop()
    }

    /// Finder "Open With" / `open -a Sukusho file.png` entry point.
    func application(_ application: NSApplication, open urls: [URL]) {
        openedFilesAtLaunch = true
        guard let onOpenFiles else {
            pendingOpenURLs.append(contentsOf: urls)
            return
        }
        onOpenFiles(urls)
    }

    /// Finder, Spotlight and the Dock all reopen the same Library window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        CaptureLibraryModel.shared.show()
        return false
    }

    /// Guard against silently losing captures. Screenshots that were never
    /// saved to disk (Auto Save off and not manually saved) only live in the
    /// temporary directory, so quitting discards them. Warn before that
    /// happens.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Saved Studio projects save without closing first, so the review
        // below finds only failed ones and an export still gets its prompt.
        StudioProjectRegistry.shared.autosaveAll()
        // Annotation edits have no draft, so ask about each dirty editor
        // first. Once all are saved or discarded (their windows closed), run
        // this again for the checks below; it replies itself if it defers.
        if EditorCloseGuard.reviewBeforeQuit(completion: { approved in
            let reply = approved ? self.applicationShouldTerminate(sender) : .terminateCancel
            if reply != .terminateLater {
                sender.reply(toApplicationShouldTerminate: reply == .terminateNow)
            }
        }) {
            return .terminateLater
        }

        // Studio's draft is debounced. Flushing here means quitting never
        // costs the last edit - the project reopens on its draft.
        StudioProjectRegistry.shared.flushDrafts()
        if StudioProjectRegistry.shared.hasUnsavedMovieEdits {
            NSApp.activate(ignoringOtherApps: true)

            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Some video edits can't be saved"
            alert.informativeText = "Videos that aren't recording projects lose their edits when Sukusho quits. Export them first if you want to keep them."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Quit Anyway")

            guard alert.runModal() == .alertSecondButtonReturn else {
                return .terminateCancel
            }
        }
        let unsavedProjectCount = StudioProjectRegistry.shared.unsavedProjectCount
        let unsavedCount = ScreenshotPreviewStack.shared.unsavedItems.count
        if StudioProjectRegistry.shared.hasRunningWork {
            NSApp.activate(ignoringOtherApps: true)

            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "An export or upload is still in progress"
            alert.informativeText = "Quitting cancels it. The recording itself is kept."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Quit Anyway")

            guard alert.runModal() == .alertSecondButtonReturn else {
                return .terminateCancel
            }
        }
        if ScreenRecordingManager.shared.isActive {
            NSApp.activate(ignoringOtherApps: true)

            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "A screen recording is still in progress"
            alert.informativeText = unsavedCount > 0
                ? "Sukusho will finish and save the recording before quitting. You also have \(unsavedCount) unsaved capture\(unsavedCount == 1 ? "" : "s") that will be discarded."
                : "Sukusho will finish and save the recording before quitting. This can take a moment for a long recording."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Finish Recording and Quit")

            guard alert.runModal() == .alertSecondButtonReturn else {
                return .terminateCancel
            }

            ScreenRecordingManager.shared.finishForTermination { session in
                Task { @MainActor in
                    if let session {
                        _ = await ScreenshotHistoryStore.shared.importRecordingSession(session)
                    }
                    await ScreenshotPreviewStack.shared.waitForPendingImageSaves()
                    sender.reply(toApplicationShouldTerminate: true)
                }
            }
            return .terminateLater
        }

        if ScreenshotPreviewStack.shared.hasPendingImageSaves {
            Task { @MainActor in
                await ScreenshotPreviewStack.shared.waitForPendingImageSaves()
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }

        guard unsavedCount > 0 else { return .terminateNow }

        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = unsavedCount == 1
            ? "You have 1 unsaved capture"
            : "You have \(unsavedCount) unsaved captures"
        var informativeText = """
        These captures haven't been saved to your Mac and will be lost if you quit. \
        Turn on Auto Save in Settings to keep every capture automatically.
        """
        if unsavedProjectCount > 0 {
            // Unlike captures, these are safe - say so, so the warning above
            // doesn't read as covering them too.
            informativeText += """
            \n\n\(unsavedProjectCount) recording project\(unsavedProjectCount == 1 ? " has" : "s have") \
            unsaved edits. Those are kept and restored the next time you open them.
            """
        }
        alert.informativeText = informativeText

        // Cancel is the default (and leftmost-safe) action so an accidental
        // Return never discards work.
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Quit Anyway")

        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
}

extension FocusedValues {
    /// The Library's card width, for View › Bigger Cards and Smaller Cards.
    @Entry var captureLibraryCardWidth: Binding<Double>?
}

/// The Library's card size, as its status bar slider sets it.
enum LibraryCardWidth {
    static let range: ClosedRange<Double> = 140...320
    static let step: Double = 30

    static func stepped(_ width: Double, by direction: Int) -> Double {
        min(max(width + Double(direction) * step, range.lowerBound), range.upperBound)
    }
}

/// View › Bigger Cards and Smaller Cards for the Library, on the keys the editor uses for zoom.
/// Only there while the Library is focused, so the editor and Studio keep ⌘+ and ⌘−.
struct LibraryCardSizeCommands: View {
    @FocusedValue(\.captureLibraryCardWidth) private var cardWidth
    @FocusedValue(\.annotationEditor) private var editor

    var body: some View {
        if editor == nil, let cardWidth {
            Button("Bigger Cards") { cardWidth.wrappedValue = LibraryCardWidth.stepped(cardWidth.wrappedValue, by: 1) }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(cardWidth.wrappedValue >= LibraryCardWidth.range.upperBound)
            Button("Smaller Cards") { cardWidth.wrappedValue = LibraryCardWidth.stepped(cardWidth.wrappedValue, by: -1) }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(cardWidth.wrappedValue <= LibraryCardWidth.range.lowerBound)
        }
    }
}
