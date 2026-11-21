//
//  ShakeToUpload.swift
//  Screendrop
//
//  Settings › General › Shake while dragging files. While files are
//  dragged from another app, such as Finder or the Desktop, a shake of the
//  pointer brings up a small shelf under it. Dropping the files there shares
//  them as the Library's Files page does: Share Options first, unless the drop
//  lands on Upload Now or Option is held, and the links are copied. A drop on
//  Optimize or WebP keeps the files on the shelf while they are made smaller
//  (ShakeShelfOptimize.swift); they are shared, copied or saved from there.
//

import AppKit
import Carbon.HIToolbox
import os
import SwiftUI

#if DEBUG
private let shelfLog = Logger(subsystem: "com.tommyent.Sukusho.shelf", category: "drag")
#endif

/// Debug builds say what the shelf's window and its drop view are told, for a Mac where a drop goes wrong:
/// `log stream --info --debug --predicate 'subsystem == "com.tommyent.Sukusho.shelf"'`. Release builds say nothing.
private func shelfNote(_ message: @autoclosure () -> String) {
    #if DEBUG
    let text = message()
    shelfLog.notice("\(text, privacy: .public)")
    #endif
}

@MainActor
@Observable
final class ShakeToUpload {
    static let shared = ShakeToUpload()
    static let enabledKey = "shakeToUploadEnabled"

    enum Tile: CaseIterable {
        case share, upload, gallery, optimize, webP

        var title: String {
            switch self {
            case .share: "Share…"
            case .upload: "Upload Now"
            case .gallery: "Gallery…"
            case .optimize: "Optimize"
            case .webP: "WebP"
            }
        }

        var symbol: String {
            switch self {
            case .share: "square.and.arrow.up"
            case .upload: "icloud.and.arrow.up"
            case .gallery: "square.grid.2x2"
            case .optimize: "arrow.down.right.and.arrow.up.left"
            case .webP: "photo.badge.arrow.down"
            }
        }

        var spokenTitle: String {
            switch self {
            case .share: "Share with Share Options"
            case .upload: "Upload now with your saved Share Options"
            case .gallery: "Share as one gallery"
            case .optimize: "Optimize, keeping each file's format"
            case .webP: "Convert to WebP"
            }
        }
    }

    /// What the shelf does with the files it holds, once they are optimized.
    enum Finish {
        case share, upload, gallery, copy, save(replacing: Bool, askWhere: Bool = false), done
    }

    /// The files being optimized on the shelf, while it holds them.
    var holding: ShelfOptimization? { stage.holding }
    @ObservationIgnored private let stage = ShelfStage()

    /// The tile a drag is over, for its highlight.
    private(set) var targeted: Tile?

    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var detector = ShakeDetector()
    /// The drag pasteboard's count when the button went down: only a drag begun since then is this press's.
    @ObservationIgnored private var dragCountAtPress = 0
    /// Whether this press drags files; nil until a drag begins.
    @ObservationIgnored private var pressDragsFiles: Bool?
    @ObservationIgnored private var panel: NSPanel?
    /// The shelf, before a drop; Share Options take its place after one.
    @ObservationIgnored private var showsShelf = false
    @ObservationIgnored private var dragEndTimer: Timer?
    @ObservationIgnored private var releasedAt: Date?

    private init() {}

    /// Watches drags while the setting is on; call at launch and when it changes.
    func update() {
        let isOn = UserDefaults.standard.bool(forKey: Self.enabledKey)
        if isOn, monitor == nil {
            #if DEBUG
            // A scripted pointer in a test VM can't shake inside the real half second. For a live check:
            // defaults write <bundle id> shakeTestWindow -float 8, then relaunch. Debug builds only.
            if let seconds = UserDefaults.standard.object(forKey: "shakeTestWindow") as? Double { detector.window = seconds }
            // A scripted pointer can't shake at all (seen in the test VM). For a live check of the drop:
            // defaults write <bundle id> shelfOpensOnFileDrag -bool YES, then relaunch. The shelf then opens
            // as soon as files are dragged anywhere, without a shake. Debug builds only.
            if UserDefaults.standard.bool(forKey: "shelfOpensOnFileDrag") {
                var dragCount = NSPasteboard(name: .drag).changeCount
                let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
                    MainActor.assumeIsolated {
                        let pasteboard = NSPasteboard(name: .drag)
                        guard NSEvent.pressedMouseButtons & 1 != 0 else {
                            dragCount = pasteboard.changeCount
                            return
                        }
                        // A drag empties its pasteboard first and fills it a moment later: wait for the files.
                        guard pasteboard.changeCount != dragCount, ShakeToUpload.shared.panel == nil,
                              pasteboard.types?.contains(.fileURL) == true else { return }
                        dragCount = pasteboard.changeCount
                        ShakeToUpload.shared.showShelf()
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
            }
            #endif
            // Copies of other apps' mouse events; macOS asks no permission for these.
            monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged]) { event in
                let isPress = event.type == .leftMouseDown
                // A global event has no window, so this is in screen coordinates.
                let x = event.locationInWindow.x
                let time = event.timestamp
                MainActor.assumeIsolated { ShakeToUpload.shared.pointer(isPress: isPress, x: x, time: time) }
            }
            CloudLibraryModel.shared.checkWorkerVersion()
        } else if !isOn, let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
            dismiss()
        }
    }

    private func pointer(isPress: Bool, x: CGFloat, time: TimeInterval) {
        let pasteboard = NSPasteboard(name: .drag)
        if isPress {
            dragCountAtPress = pasteboard.changeCount
            pressDragsFiles = nil
            detector.reset()
            return
        }
        guard panel == nil else { return }
        // A drag writes the drag pasteboard as it begins; until then this is a plain drag, or not yet one.
        // It is emptied first and filled a moment later (seen in the test VM's log), so an empty one decides nothing.
        if pressDragsFiles == nil, pasteboard.changeCount != dragCountAtPress, let types = pasteboard.types, !types.isEmpty {
            pressDragsFiles = types.contains(.fileURL)
        }
        guard pressDragsFiles == true, detector.add(x: x, time: time) else { return }
        showShelf()
    }

    // MARK: - Shelf

    /// The sharing tiles need Cloud set up and no upload still running; Optimize and WebP are always there.
    private var offersCloud: Bool {
        CloudUploader.shared.isConfigured && CloudLibraryModel.shared.fileUploads == nil
    }

    private func showShelf() {
        // Read here only to say what is being dragged and which tiles fit it. What gets worked on is read
        // again from the drop itself (ShelfDropTarget).
        let files = ShakeShelfFiles.fileURLs(on: NSPasteboard(name: .drag))
        guard !files.isEmpty else { return }
        let offersCloud = offersCloud
        let tiles = Tile.allCases.filter { tile in
            switch tile {
            case .share, .upload: offersCloud
            case .gallery: offersCloud && ShakeShelfFiles.canShareGallery(files, workerSupportsGalleries: CloudLibraryModel.shared.supportsGalleries)
            case .optimize, .webP: true
            }
        }
        let view = ShakeShelfView(tiles: tiles, files: files,
                                  isUploading: CloudUploader.shared.isConfigured && CloudLibraryModel.shared.fileUploads != nil)
        let size = NSHostingController(rootView: view).sizeThatFits(in: CGSize(width: 2000, height: 2000))
        // The first tile is Share…, so a drop right where the shake ended asks first, or Optimize without Cloud.
        // It opens under the pointer, on every macOS: what macOS 26 needed was the drop view registered before
        // the panel is shown (seen on the test Mac, 26.5.1: with that, a drop is taken under the pointer too).
        let pointer = Self.pointer
        var gap: CGFloat = 0
        var style: NSWindow.StyleMask = [.borderless, .nonactivatingPanel]
        var level = NSWindow.Level.statusBar
        var opensAtCenter = false
        #if DEBUG
        // For finding out on a Mac where the drop fails, each with `defaults write <bundle id> …` and a relaunch:
        // shelfGap -float 6 (that far below the pointer, so the drag enters it); shelfOpensAtCenter -bool YES (a fixed place, so
        // a straight drag enters from outside); shelfLevel -string normal|floating|statusBar;
        // shelfActivating -bool YES (an ordinary panel, not a non-activating one).
        let defaults = UserDefaults.standard
        if let value = defaults.object(forKey: "shelfGap") as? Double { gap = value }
        opensAtCenter = defaults.bool(forKey: "shelfOpensAtCenter")
        if defaults.bool(forKey: "shelfActivating") { style = [.borderless] }
        switch defaults.string(forKey: "shelfLevel") {
        case "normal": level = .normal
        case "floating": level = .floating
        default: break
        }
        #endif
        let tileCenter = CGPoint(x: ShakeShelfView.margin + ShakeShelfView.inset + ShakeShelfView.tileSize.width / 2,
                                 y: ShakeShelfView.margin + ShakeShelfView.inset + ShakeShelfView.tileSize.height / 2)
        var origin = CGPoint(x: pointer.x - tileCenter.x, y: pointer.y - (size.height - tileCenter.y))
        let screen = (NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main)?.visibleFrame
        if opensAtCenter, let screen {
            origin = CGPoint(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2)
        } else if gap > 0 {
            // The window's own edge is `gap` from the pointer, so the pointer starts outside it. Below the
            // pointer, where the tiles come first; above it when there is no room below.
            let below = pointer.y - gap - size.height
            origin.y = below >= (screen?.minY ?? below) ? below : pointer.y + gap
        }
        let frame = Self.onScreen(CGRect(origin: origin, size: size), near: pointer)
        let panel = ShakeShelfPanel(contentRect: frame, styleMask: style, backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = level
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        PreviewWindowCaptureExclusion.shared.register(window: panel)
        shelfNote("panel made: frame \(NSStringFromRect(frame)), pointer \(NSStringFromPoint(pointer)), gap \(gap), center \(opensAtCenter), "
            + "style \(style.rawValue), level \(level.rawValue), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        // The drop view is in place, registered and laid out, before the panel is on screen.
        install(view, in: panel, takesDrops: true)
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.orderFrontRegardless()
        self.panel = panel
        showsShelf = true
        let tileNames = tiles.map(\.title).joined(separator: ", ")
        shelfNote("panel shown: visible \(panel.isVisible), frame \(NSStringFromRect(panel.frame)), level \(panel.level.rawValue), "
            + "ignoresMouseEvents \(panel.ignoresMouseEvents), on active space \(panel.isOnActiveSpace), key \(panel.isKeyWindow), "
            + "app active \(NSApp.isActive), policy \(NSApp.activationPolicy().rawValue), tiles \(tileNames)")

        // Often enough to catch a tap of Esc.
        let timer = Timer(timeInterval: 0.03, repeats: true) { _ in
            MainActor.assumeIsolated { ShakeToUpload.shared.checkDragEnded() }
        }
        RunLoop.main.add(timer, forMode: .common)
        dragEndTimer = timer
        // The panel never takes focus while the drag goes on, so VoiceOver wouldn't read it otherwise.
        AccessibilityNotification.Announcement("Sukusho shelf for \(files.count == 1 ? "1 file" : "\(files.count) files"). Drop on: "
            + tiles.map(\.spokenTitle).joined(separator: ", ")).post()
    }

    /// Esc, or the drag ended somewhere else: a drop on the shelf comes just after the release, so it waits a moment for one.
    private func checkDragEnded() {
        guard showsShelf, let panel else { return }
        // Read, not taken, so Esc still cancels the drag as it always does. Needs no permission (seen in the test VM),
        // where a hot key would keep the drag going and a release would then drop the files wherever the pointer is.
        if CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_Escape)) {
            shelfNote("put away: Esc")
            return dismiss()
        }
        guard NSEvent.pressedMouseButtons & 1 == 0 else {
            releasedAt = nil
            return
        }
        if releasedAt == nil {
            shelfNote("button released at \(NSStringFromPoint(Self.pointer)), inside the panel \(panel.frame.contains(Self.pointer))")
        }
        let released = releasedAt ?? .now
        releasedAt = released
        let wait: TimeInterval = panel.frame.contains(Self.pointer) ? 2 : 0.3
        if Date.now.timeIntervalSince(released) > wait {
            shelfNote("put away: no drop arrived within \(wait) s of the release")
            dismiss()
        }
    }

    /// The tile the drag is over, or nil for none.
    func setTargeted(_ tile: Tile?) {
        if targeted != tile { targeted = tile }
    }

    func drop(_ urls: [URL], on tile: Tile) {
        shelfNote("drop handed on: \(urls.count) files on \(tile.title), shelf showing \(showsShelf)")
        guard showsShelf, let shelf = panel else { return }
        // The drop has come, so the shelf stops waiting for one.
        stopWatchingDrag()
        let skipsOptions = NSEvent.modifierFlags.contains(.option)
        Task {
            // Nothing about the dropped files is read on the main actor, not even which of them are folders:
            // a read can wait on a macOS prompt (ShelfOptimization.init).
            let files = await ShelfOptimization.regularFiles(urls)
            // Put away meanwhile, or another shelf by now.
            guard showsShelf, panel === shelf else { return }
            // As the Files page says it; the files go on without the folders.
            if files.count < urls.count {
                let optimizes = tile == .optimize || tile == .webP
                CaptureTextFeedbackPresenter.shared.showDone(optimizes ? "Folders Are Left Out" : "Folders Can’t Be Shared",
                                                             detail: "Drop the files inside them instead.",
                                                             symbol: "folder", displayID: Self.display)
            }
            guard !files.isEmpty else { return dismiss() }
            if tile == .optimize || tile == .webP { return showHolding(files, format: tile == .webP ? .webP : .same) }
            let gallery = tile == .gallery
            if tile == .upload || skipsOptions {
                start(files, gallery: gallery, options: .savedDefaults)
            } else {
                showOptions(files, gallery: gallery)
            }
        }
    }

    private func showOptions(_ files: [URL], gallery: Bool) {
        guard let panel else { return }
        stopWatchingDrag()
        showsShelf = false
        let view = ShakeShelfOptions(files: files, gallery: gallery)
        let size = NSHostingController(rootView: view).sizeThatFits(in: CGSize(width: 2000, height: 2000))
        let top = CGPoint(x: panel.frame.midX, y: panel.frame.maxY)
        install(view, in: panel)
        panel.setFrame(Self.onScreen(CGRect(x: top.x - size.width / 2, y: top.y - size.height, width: size.width, height: size.height),
                                     near: top), display: true)
        // Key without activating Sukusho, so the title and password fields take typing.
        panel.makeKey()
    }

    // MARK: - Holding

    private func showHolding(_ files: [URL], format: ShelfOptimization.Format) {
        guard let panel else { return }
        stopWatchingDrag()
        showsShelf = false
        targeted = nil
        let model = ShelfOptimization(files: files, format: format, optimizer: .shared, effort: OptimizePreferences.effort) { $0.target }
        stage.show(model)
        let offersCloud = offersCloud
        let workerSupportsGalleries = CloudLibraryModel.shared.supportsGalleries
        let view = ShakeShelfHolding(model: model, offersCloud: offersCloud, workerSupportsGalleries: workerSupportsGalleries) { [weak self] in
            self?.finishHolding($0)
        }
        let size = NSHostingController(rootView: view).sizeThatFits(in: CGSize(width: 2000, height: 2000))
        let top = CGPoint(x: panel.frame.midX, y: panel.frame.maxY)
        install(view, in: panel)
        panel.setFrame(Self.onScreen(CGRect(x: top.x - size.width / 2, y: top.y - size.height, width: size.width, height: size.height),
                                     near: top), display: true)
        // Key without activating Sukusho, so Esc and the buttons work while another app stays in front.
        panel.makeKey()
        AccessibilityNotification.Announcement("\(format == .same ? "Optimizing" : "Converting") "
            + (files.count == 1 ? "1 file" : "\(files.count) files") + " on the Sukusho shelf.").post()
    }

    /// Esc on the list is Done; anywhere else it puts the shelf away.
    func escape() {
        if holding != nil { finishHolding(.done) } else { dismiss() }
    }

    func finishHolding(_ finish: Finish) {
        // One choice at a time: until it is done, the results on the list are its to work with (ShelfOptimization.finishing).
        guard let holding, !holding.isFinishing else { return }
        if case .done = finish {
            holding.stop()
            holding.discard()
            dismiss()
            return
        }
        // Every other choice reads whole files: to see that each is still the one its result was made from,
        // and to save. That happens off the main actor, with the list still up and its controls off.
        // By the time it is done the shelf may have been put away and opened again for other files. This
        // choice then finishes with its own list's results and leaves the shelf alone: it dismisses,
        // clears or changes the shelf only while its list is still the one on show (ShelfStage.finish).
        Task {
            if case .save(let replacing, let askWhere) = finish {
                // Each new file beside its original (or in a folder chosen with Option), as
                // "name optimized.png" or "name.webp", or with `replacing` in its place, with the original
                // in the Trash (ShelfFileSave).
                let done = await stage.finish(holding) { rows -> (outcomes: [ShelfFileSave.Outcome], folder: URL?)? in
                    var folder: URL?
                    if !replacing, askWhere {
                        let initial = rows.first(where: \.hasNewFile)?.file.deletingLastPathComponent()
                        let count = rows.count(where: \.hasNewFile)
                        guard count > 0, let picked = await self.chooseSaveFolder(initial: initial, count: count) else { return nil }
                        folder = picked
                    }
                    let destination = folder
                    let outcomes = await Task.detached {
                        ShelfOptimization.rowsToSave(from: rows, replacing: replacing).compactMap { row -> ShelfFileSave.Outcome? in
                            guard let result = row.result else { return nil }
                            return ShelfFileSave.save(result.url, of: row.file, identity: result.source,
                                                      outputIdentity: result.output, replacing: replacing, in: destination)
                        }
                    }.value
                    return (outcomes, destination)
                }
                guard let done else { return }
                guard let saved = done.value else {
                    if !done.isShowing { holding.discard() }
                    return
                }
                holding.discard()
                if done.isShowing { dismiss() }
                report(saved.outcomes, replacing: replacing, folder: saved.folder)
                return
            }
            guard let done = await stage.finish(holding, { await ShelfOptimization.currentFiles(of: $0) }) else { return }
            let files = done.value
            // Nothing Sukusho could read is left to hand over (the buttons are off for that; this is the guard).
            guard !files.isEmpty else {
                holding.discard()
                if done.isShowing { dismiss() }
                return
            }
            let toast = CaptureTextFeedbackPresenter.shared
            switch finish {
            case .share, .gallery, .upload:
                // Both go on in the shelf's panel, or put it away. With its list gone from the shelf there is
                // nowhere to go on: the results go and the shelf stays as it is.
                guard done.isShowing else { return holding.discard() }
                if case .gallery = finish,
                   !ShakeShelfFiles.canShareGallery(files, workerSupportsGalleries: CloudLibraryModel.shared.supportsGalleries) {
                    holding.discard()
                    toast.showDone("Galleries Need 2 or More Images", detail: "Too few readable images remained for a gallery.",
                                   symbol: "square.grid.2x2", displayID: Self.display)
                    dismiss()
                    return
                }
                // The results stay until the next launch: the upload reads them after the shelf is gone.
                stage.putAway()
                if case .upload = finish {
                    start(files, gallery: false, options: .savedDefaults)
                } else if case .gallery = finish {
                    showOptions(files, gallery: true)
                } else {
                    showOptions(files, gallery: false)
                }
            case .copy:
                do {
                    try VideoFileActions.copyFilesToClipboard(from: files)
                    toast.showDone(files.count == 1 ? "File Copied" : "\(files.count) Files Copied",
                                   detail: files.count == 1 ? files[0].lastPathComponent : "Ready to paste", displayID: Self.display)
                } catch {
                    toast.showDone("Couldn’t Copy", detail: error.localizedDescription, symbol: "exclamationmark.triangle", displayID: Self.display)
                }
                holding.discard()
                if done.isShowing { dismiss() }
            case .save, .done:
                break
            }
        }
    }

    /// Asks where to put the saved files when Option is held on Save. Lowers the status-bar shelf while
    /// the folder picker is open so the shelf doesn't float over it.
    private func chooseSaveFolder(initial: URL?, count: Int) async -> URL? {
        let shelfPanel = panel
        let savedLevel = shelfPanel?.level
        shelfPanel?.level = .normal
        defer {
            if let shelfPanel, let savedLevel, panel === shelfPanel {
                shelfPanel.level = savedLevel
                shelfPanel.makeKey()
            }
        }
        let openPanel = NSOpenPanel()
        openPanel.title = count == 1 ? "Save Optimized File" : "Save Optimized Files"
        openPanel.prompt = "Save Here"
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        openPanel.canCreateDirectories = true
        openPanel.allowsMultipleSelection = false
        openPanel.directoryURL = initial
        NSApp.activate(ignoringOtherApps: true)
        return await openPanel.begin() == .OK ? openPanel.url : nil
    }

    /// Says what a Save did. A file changed since it was optimized was left exactly as it is. When any
    /// original or retained backup needs recovery (Trash refused it, or Foundation relocated it before a
    /// replacement failure), show a persistent alert with Reveal in Finder instead of a transient toast.
    private func report(_ outcomes: [ShelfFileSave.Outcome], replacing: Bool, folder: URL? = nil) {
        let summary = ShelfFileSave.summary(of: outcomes, replacing: replacing, folder: folder)
        if !summary.recoveryURLs.isEmpty {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = summary.isFailure
                ? summary.title
                : (summary.recoveryURLs.count == 1 ? "Original Couldn’t Be Moved to the Trash"
                    : "Originals Couldn’t Be Moved to the Trash")
            alert.informativeText = summary.detail
            alert.addButton(withTitle: "Reveal in Finder")
            alert.addButton(withTitle: "OK")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting(summary.recoveryURLs)
            }
            return
        }
        let toast = CaptureTextFeedbackPresenter.shared
        if summary.isFailure {
            toast.showDone(summary.title, detail: summary.detail, symbol: "exclamationmark.triangle", displayID: Self.display)
        } else if summary.saved.isEmpty {
            toast.showDone(summary.title, detail: summary.detail, symbol: "equal.circle", displayID: Self.display)
        } else {
            toast.showDone(summary.title, detail: summary.detail, displayID: Self.display)
        }
        if !summary.saved.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(summary.saved) }
    }

    func start(_ files: [URL], gallery: Bool, options: CloudUploadOptions) {
        dismiss()
        let cloud = CloudLibraryModel.shared
        let toast = CaptureTextFeedbackPresenter.shared
        let display = Self.display
        guard CloudUploader.shared.isConfigured, cloud.fileUploads == nil else { return }
        if gallery {
            toast.showWorking("Sharing \(files.count) images…", detail: "As one gallery", displayID: display)
            cloud.shareGallery(files, options: options) { link in
                guard link != nil else { return Self.showFailure() }
                toast.showDone(ActionFeedback.linksCopied(1), detail: "A gallery of \(files.count) images", displayID: display)
            }
        } else {
            let one = files.count == 1 ? files[0].lastPathComponent : nil
            toast.showWorking(one == nil ? "Uploading \(files.count) files…" : "Uploading file…",
                              detail: one ?? "One link each", displayID: display)
            cloud.uploadFiles(files, options: options) { copied, failed in
                guard copied > 0 else { return Self.showFailure() }
                toast.showDone(ActionFeedback.linksCopied(copied), detail: one ?? "One link each, ready to paste", displayID: display)
                if failed { CaptureLibraryModel.shared.show() }
            }
        }
    }

    func dismiss() {
        stopWatchingDrag()
        stage.putAway()
        panel?.orderOut(nil)
        panel = nil
        showsShelf = false
        targeted = nil
        detector.reset()
    }

    private func stopWatchingDrag() {
        dragEndTimer?.invalidate()
        dragEndTimer = nil
        releasedAt = nil
    }

    /// `takesDrops` is for the tiles: the drop view lies over them.
    private func install(_ view: some View, in panel: NSPanel, takesDrops: Bool = false) {
        let host = NSHostingView(rootView: view)
        // The panel sets the size and the hosting view follows, as the capture bars do.
        host.sizingOptions = []
        guard takesDrops else {
            panel.contentView = host
            return
        }
        let container = NSView(frame: CGRect(origin: .zero, size: panel.frame.size))
        let drops = ShelfDropView(frame: container.bounds)
        for view in [host, drops] {
            view.frame = container.bounds
            view.autoresizingMask = [.width, .height]
            container.addSubview(view)
        }
        drops.registerForDraggedTypes([.fileURL])
        let types = drops.registeredDraggedTypes.map(\.rawValue).joined(separator: ", ")
        shelfNote("drop view registered for \(types), frame \(NSStringFromRect(drops.frame))")
        panel.contentView = container
    }

    /// The Library's alert says what failed; a cancel from the Files page's Stop says nothing.
    private static func showFailure() {
        CaptureTextFeedbackPresenter.shared.dismissWorking()
        if CaptureLibraryModel.shared.errorMessage != nil { CaptureLibraryModel.shared.show() }
    }

    private static var display: CGDirectDisplayID? { ActiveDisplayResolver.activeDisplayID(preferPointer: true) }

    /// The pointer in window coordinates, from Quartz's top-left position. `NSEvent.mouseLocation` can
    /// disagree with the screens' frames: in the macOS 27.0.1 test VM it said y 539 while the only
    /// screen's frame ran from y -1021 to 0, and the shelf landed at the top of the screen.
    private static var pointer: CGPoint {
        guard let location = CGEvent(source: nil)?.location, let primary = NSScreen.screens.first else { return NSEvent.mouseLocation }
        return CGPoint(x: location.x, y: primary.frame.maxY - location.y)
    }

    private static func onScreen(_ frame: CGRect, near point: CGPoint) -> CGRect {
        guard let bounds = (NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main)?.visibleFrame else { return frame }
        var frame = frame
        frame.origin.x = min(max(frame.minX, bounds.minX), bounds.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, bounds.minY), bounds.maxY - frame.height)
        return frame
    }
}

private final class ShakeShelfPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        ShakeToUpload.shared.escape()
    }
}

/// One glass panel of drop tiles, with what's being dragged below them.
private struct ShakeShelfView: View {
    static let tileSize = CGSize(width: 88, height: 72)
    static let inset = DS.Space.ml
    /// Room around the glass for its shadow.
    static let margin = DS.Space.l

    let tiles: [ShakeToUpload.Tile]
    let files: [URL]
    /// Cloud is set up but busy, so the sharing tiles are left out this time.
    var isUploading = false
    @State private var shelf = ShakeToUpload.shared
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: DS.Space.m) {
            HStack(spacing: DS.Space.m) {
                ForEach(tiles, id: \.self) { tile($0) }
            }
            Text(caption)
                .font(DS.TypeScale.label)
                .foregroundStyle(Palette.secondaryLabel)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: CGFloat(tiles.count) * Self.tileSize.width)
                .accessibilityHidden(true)
        }
        .padding(Self.inset)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
        .scaleEffect(appeared || reduceMotion ? 1 : 0.85)
        .opacity(appeared ? 1 : 0)
        .padding(Self.margin)
        .onAppear {
            withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.3, bounce: 0.35)) { appeared = true }
        }
    }

    private var caption: String {
        let what = files.count == 1 ? files[0].lastPathComponent : "\(files.count) files"
        if isUploading { return "\(what) · still uploading the last ones" }
        return tiles.contains(.share) ? "\(what) · ⌥ skips options" : what
    }

    private func tile(_ tile: ShakeToUpload.Tile) -> some View {
        let isTargeted = shelf.targeted == tile
        return VStack(spacing: DS.Space.s) {
            Image(systemName: tile.symbol)
                .font(.system(size: 20, weight: .medium))
            Text(tile.title)
                .font(DS.TypeScale.labelSemibold)
                .lineLimit(1)
        }
        .foregroundStyle(isTargeted ? Palette.onAccent : Palette.label)
        .frame(width: Self.tileSize.width, height: Self.tileSize.height)
        // Concentric with the panel's corners.
        .background(isTargeted ? Palette.accent : Palette.selectedFill,
                    in: RoundedRectangle(cornerRadius: DS.Radius.panel - Self.inset, style: .continuous))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isTargeted)
        .overlay(ShelfTileMarker(tile: tile))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tile.spokenTitle)
        .accessibilityHint("Drop the dragged files here")
    }
}

/// Says where a tile is, for the drop view: a bare AppKit view over the tile that takes no events itself.
private struct ShelfTileMarker: NSViewRepresentable {
    let tile: ShakeToUpload.Tile

    func makeNSView(context: Context) -> MarkerView {
        let view = MarkerView()
        view.tile = tile
        return view
    }

    func updateNSView(_ view: MarkerView, context: Context) {
        view.tile = tile
    }

    final class MarkerView: NSView {
        var tile = ShakeToUpload.Tile.optimize

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        /// Every marker under `view`, wherever SwiftUI put it.
        static func all(under view: NSView) -> [MarkerView] {
            view.subviews.flatMap { ($0 as? MarkerView).map { [$0] } ?? all(under: $0) }
        }
    }
}

/// The shelf's drop target: one AppKit view over all the tiles, registered for file drags before the panel is
/// on screen. SwiftUI's `dropDestination(for: URL.self)` was on each tile until the owner's first try by hand,
/// on macOS 26.5.1, where its action was never called; a dragging destination made by each tile as SwiftUI
/// laid it out worked on macOS 27 and still got no drag on 26. Registered before the panel shows, this one
/// takes drops on 26.5.1 wherever the shelf opens (seen on the test Mac). It finds the tile under the drag
/// from the tiles' markers, and reads the files from the drop's own pasteboard inside the drop.
private final class ShelfDropView: NSView {
    private var lastTile: ShakeToUpload.Tile?

    private func tile(for sender: NSDraggingInfo) -> ShakeToUpload.Tile? {
        guard let root = superview else { return nil }
        let point = convert(sender.draggingLocation, from: nil)
        return ShelfTileMarker.MarkerView.all(under: root).first { $0.convert($0.bounds, to: self).contains(point) }?.tile
    }

    /// The files stay where they are, so a copy where the source allows one; nothing between the tiles.
    private func follow(_ sender: NSDraggingInfo, _ what: String) -> NSDragOperation {
        let tile = tile(for: sender)
        if what != "updated" || tile != lastTile {
            shelfNote("drag \(what): at \(NSStringFromPoint(convert(sender.draggingLocation, from: nil))), tile \(tile?.title ?? "none"), "
                + "source allows \(sender.draggingSourceOperationMask.rawValue), markers \(ShelfTileMarker.MarkerView.all(under: superview ?? self).count)")
        }
        lastTile = tile
        ShakeToUpload.shared.setTargeted(tile)
        guard tile != nil else { return [] }
        return sender.draggingSourceOperationMask.contains(.copy) ? .copy : .generic
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        follow(sender, "entered")
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        follow(sender, "updated")
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        shelfNote("drag exited")
        lastTile = nil
        ShakeToUpload.shared.setTargeted(nil)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        shelfNote("drag ended")
        ShakeToUpload.shared.setTargeted(nil)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let tile = tile(for: sender)
        shelfNote("prepare for drop: tile \(tile?.title ?? "none")")
        return tile != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let files = ShakeShelfFiles.fileURLs(on: sender.draggingPasteboard)
        let tile = tile(for: sender)
        shelfNote("perform drop: tile \(tile?.title ?? "none"), \(files.count) files")
        guard let tile, !files.isEmpty else { return false }
        // Once the drop is over: the shelf swaps its content and moves its window, which is not for the
        // middle of a drag session.
        DispatchQueue.main.async { ShakeToUpload.shared.drop(files, on: tile) }
        return true
    }
}

/// Share Options after a drop on Share… or Gallery…, in the shelf's place.
private struct ShakeShelfOptions: View {
    let files: [URL]
    let gallery: Bool

    var body: some View {
        CloudUploadOptionsPopover(
            suggestedTitle: gallery ? "\(files.count) images" : "",
            // One title can't name several files; a gallery's names the gallery.
            showsTitle: gallery || files.count == 1,
            encryptionUnavailable: gallery ? "Galleries can’t be end-to-end encrypted yet." : CloudShareSeal.unavailableReason(fileURLs: files),
            onCancel: { ShakeToUpload.shared.dismiss() }
        ) { options in
            ShakeToUpload.shared.start(files, gallery: gallery, options: options)
        }
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
        .padding(ShakeShelfView.margin)
    }
}
