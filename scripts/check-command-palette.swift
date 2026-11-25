// The command palette against the app itself, without a window: the real host (`AppCommandPaletteHost`) over the
// Library's model, a Studio model on a bare one-second movie, the theme try-on and the catalog. What a hostless test
// can't reach: an action queued past the palette, the Library's pages, the appearance a try-on started in, and Studio's
// own reasons. Compiled with the app's sources by scripts/check-command-palette.sh, in a fresh home.

import AppKit
import AVFoundation

@main
struct CheckCommandPalette {
    nonisolated(unsafe) static var failures = 0

    static func check(_ ok: Bool, _ what: String) {
        print(ok ? "ok    \(what)" : "FAIL  \(what)")
        if !ok { failures += 1 }
    }

    /// Lets what the palette queued for after it closes run.
    static func turn() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }

    /// A bare movie: one second, no sound, no clicks, no project.
    static func movie(at url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 200,
        ])
        writer.add(input)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        guard writer.startWriting() else { throw CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 320, 200, kCVPixelFormatType_32BGRA, nil, &buffer)
        guard let buffer else { throw CocoaError(.fileWriteUnknown) }
        for time in [0.0, 0.9] {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            adaptor.append(buffer, withPresentationTime: CMTime(seconds: time, preferredTimescale: 600))
        }
        writer.endSession(atSourceTime: CMTime(seconds: 1, preferredTimescale: 600))
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw CocoaError(.fileWriteUnknown) }
    }

    static func command(_ id: String) -> PaletteCommand { PaletteCommand.catalog.first { $0.id == id }! }

    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let home = ProcessInfo.processInfo.environment["PALETTE_CHECK_HOME"] ?? ""
        let support = ScreendropStorage.applicationSupportDirectory.resolvingSymlinksInPath().path
        let isolated = URL(fileURLWithPath: home).resolvingSymlinksInPath().path
        guard home.hasPrefix("/private/tmp/"), support.hasPrefix(isolated + "/") else {
            print("ABORT: Sukusho's storage isn't in the check's own home: \(support)")
            exit(5)
        }
        NSApplication.shared.setActivationPolicy(.prohibited)
        // Nothing here may put an alert on the screen: a failure the app would show is recorded instead.
        var alerts: [String] = []
        FailureAlert.presenter = { message, _, _ in alerts.append(message) }
        let defaults = UserDefaults.standard

        // Finding 2: an action queued past the palette runs once the palette and its host are gone.
        defaults.set(220.0, forKey: "captureLibrary.cardWidth")
        let library = LibraryPaletteHooks(sidebarShown: { true }, toggleSidebar: {}, inspectorShown: { true }, toggleInspector: {},
                                          find: {}, refresh: {})
        var host: AppCommandPaletteHost? = AppCommandPaletteHost(context: .library(library), windowTitle: "Check")
        weak let released = host
        check(host?.run(command("library.biggerCards")) == .close, "Bigger Cards closes the palette")
        CommandPalettePresenter.shared.close()
        host = nil
        check(released == nil, "the host goes with the palette")
        await turn()
        check((defaults.object(forKey: "captureLibrary.cardWidth") as? Double ?? 220) > 220, "Bigger Cards ran after both were gone")

        // Finding 5: Search Captures… and Show All leave Snippets and Clipboard for the captures they ask for.
        let shared = AppCommandPaletteHost(context: nil, windowTitle: nil)
        CaptureLibrarySidebarSelection.show(.snippets)
        check(CaptureLibrarySidebarSelection.current == .snippets, "Snippets shows")
        shared.searchCaptures(for: "lake")
        CommandPalettePresenter.shared.close()
        await turn()
        check(CaptureLibrarySidebarSelection.current == .kind(.all) && CaptureLibraryModel.shared.searchText == "lake",
              "Search Captures… from Snippets shows All Captures with “lake”")
        CaptureLibrarySidebarSelection.show(.clipboard)
        _ = shared.choose(PaletteRow(id: "all", title: "Show All Recordings…"), in: .recordings)
        CommandPalettePresenter.shared.close()
        await turn()
        check(CaptureLibrarySidebarSelection.current == .kind(.recordings), "Show All Recordings… from Clipboard shows Recordings")

        // Finding 7: a try-on stays in the appearance it started in, put back or kept.
        var dark = false
        let themes = CommandPaletteModel(host: AppCommandPaletteHost(context: nil, windowTitle: nil, appearsDark: { dark }),
                                         start: .changeTheme)
        themes.press(.down)
        check(ThemeTryOn.id(dark: false) == "chip-light" && ThemeTryOn.id(dark: true) == nil, "Chip is tried on in Light")
        dark = true
        themes.close()
        check(ThemeTryOn.id(dark: false) == nil && ThemeTryOn.id(dark: true) == nil, "turning Dark mid-step, Esc puts Light back")
        dark = false
        let keep = CommandPaletteModel(host: AppCommandPaletteHost(context: nil, windowTitle: nil, appearsDark: { dark }),
                                       start: .changeTheme)
        keep.press(.down)
        dark = true
        keep.press(.enter)
        check(defaults.string(forKey: AppTheme.lightKey) == "chip-light" && defaults.string(forKey: AppTheme.darkKey) == nil
              && ThemeTryOn.id(dark: false) == nil, "kept after turning Dark, Chip goes into the Light slot it was tried in")
        defaults.removeObject(forKey: AppTheme.lightKey)
        // Sol's second review: a search that found nothing let the step go, so turning Dark meanwhile kept a dark theme.
        dark = false
        let slot = CommandPaletteModel(host: AppCommandPaletteHost(context: nil, windowTitle: nil, appearsDark: { dark }),
                                       start: .changeTheme)
        slot.query = "glass"
        dark = true
        slot.query = "nothing matches this"
        check(ThemeTryOn.id(dark: false) == "classic-light" && ThemeTryOn.id(dark: true) == nil,
              "nothing matching shows the saved Light theme, still in the Light slot")
        slot.query = "chip"
        check(slot.selectedRow?.id == "chip-light", "the step still lists Light's themes")
        slot.press(.enter)
        check(defaults.string(forKey: AppTheme.lightKey) == "chip-light" && defaults.string(forKey: AppTheme.darkKey) == nil
              && ThemeTryOn.id(dark: false) == nil, "↩ keeps Chip in the Light slot it started in")
        defaults.removeObject(forKey: AppTheme.lightKey)

        // Sol's second review: a view leaving its window takes its registration along, though the window stays.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: .titled, backing: .buffered,
                              defer: true)
        CommandPalettePresenter.shared.register(window) { .library(library) }
        check(CommandPalettePresenter.shared.context(for: window) != nil, "a window registers its context")
        CommandPalettePresenter.shared.register(nil, replacing: window) { .library(library) }
        check(CommandPalettePresenter.shared.context(for: window) == nil, "the view leaving takes it back; the window stays")

        // Studio on a bare movie: findings 3 and 9, and round 2's commands.
        let movieURL = URL(fileURLWithPath: home).appendingPathComponent("bare.mov")
        try await movie(at: movieURL)
        let studio = RecordingStudioModel(url: movieURL)
        await studio.load()
        check(studio.isLoaded, "Studio opens the bare movie")
        var inspectorShown = false
        let hooks = StudioPaletteHooks(model: studio, inspectorShown: { inspectorShown }, toggleInspector: { inspectorShown.toggle() })
        let studioHost = AppCommandPaletteHost(context: .studio(hooks), windowTitle: "Check")
        let reasons: [String: String?] = [
            "studio.transcribe": "recorded without the microphone",
            "studio.removeFillers": "transcribe the narration first", "studio.shortenPauses": "transcribe the narration first",
            "studio.suggestChapters": "transcribe the narration first", "studio.summarize": "transcribe the narration first",
            "studio.nameChapters": "transcribe the narration first", "studio.translate": "transcribe the narration first",
            "studio.autoZoom": "no clicks were recorded", "studio.videoOverlay": "save this recording as a project first",
            "studio.detachAudio": "select a clip first", "studio.resetClips": "no clip edits",
            "studio.isolateVoice": "no microphone track",
            "studio.timelineZoomOut": "the whole timeline shows", "studio.fitTimeline": "the whole timeline shows",
            "studio.timelineZoomIn": .none, "studio.blur": .none, "studio.pixelate": .none, "studio.export": .none,
            "studio.upload": "Cloud isn’t set up",
        ]
        for (id, reason) in reasons.sorted(by: { $0.key < $1.key }) {
            let state = studioHost.state(of: command(id))
            check(state.reason == reason, "\(id): \(reason ?? "runs") (is \(state.reason ?? "runs"))")
        }

        // Sol's second review: Export's reasons are export()'s own, and say what's in the way.
        studio.audioExportState = .exporting(progress: 0.4)
        check(studioHost.state(of: command("studio.export")).reason == "wait for Studio to finish",
              "Export waits while the audio exports, as export() does")
        studio.audioExportState = .idle
        studio.beginRedaction()
        check(studioHost.state(of: command("studio.export")).reason == "add or cancel the redaction first",
              "placing a redaction: “add or cancel the redaction first”, not cropping")
        studio.cancelRedaction()

        // Sol's note: Split at Playhead splits the selected audio clip, as the timeline's button does.
        check(studioHost.state(of: command("studio.split")).reason == "can’t split here", "no audio clip: the video, which can't split at 0")
        studio.selectedAudioClipID = UUID()
        check(studioHost.state(of: command("studio.split")).reason == nil, "an audio clip selected: it's that clip's split")
        studio.selectedAudioClipID = nil

        // Finding 3: Snapping flips Studio's own setting, and the palette stays.
        let snapping = studio.snapsEdits
        let switches = CommandPaletteModel(host: studioHost, catalog: PaletteCommand.catalog.filter { $0.id == "studio.snapping" })
        var closed = false
        switches.onClose = { closed = true }
        switches.press(.enter)
        check(studio.snapsEdits == !snapping && !closed, "↩ on Snapping turns it \(snapping ? "off" : "on") and stays open")

        // Each runs what its control runs.
        let redactions = studio.redactions.count
        _ = studioHost.run(command("studio.blur"))
        CommandPalettePresenter.shared.close()
        await turn()
        check(studio.redactions.count == redactions + 1 && studio.redactions.last?.mode == .blur, "Blur at Playhead adds a blur")
        for (id, request) in [("studio.export", StudioPaletteRequest.Kind.exportOptions), ("studio.timelineZoomIn", .zoomIn)] {
            studio.paletteRequest = nil
            _ = studioHost.run(command(id))
            CommandPalettePresenter.shared.close()
            await turn()
            check(studio.paletteRequest?.kind == request, "\(id) asks its control for \(request)")
        }
        for id in ["studio.resetClips", "studio.upload"] {
            studio.paletteRequest = nil
            _ = studioHost.run(command(id))
            CommandPalettePresenter.shared.close()
            await turn()
            check(studio.paletteRequest == nil, "\(id), grey here, asks for nothing as it's delivered")
        }
        studio.paletteRequest = nil
        _ = studioHost.run(command("studio.translate"))
        CommandPalettePresenter.shared.close()
        await turn()
        check(!inspectorShown && studio.paletteRequest == nil, "Translate Captions… without captions asks for nothing as it's delivered")

        // Sol's second review: a request checks again as it's delivered; the toolbar's button may have gone.
        _ = studioHost.run(command("studio.export"))
        studio.exportState = .exporting(progress: 0.4)
        CommandPalettePresenter.shared.close()
        await turn()
        check(studio.paletteRequest == nil, "Export… whose button went before delivery asks for nothing")
        studio.exportState = .idle
        _ = studioHost.run(command("studio.export"))
        CommandPalettePresenter.shared.close()
        await turn()
        let first = studio.paletteRequest
        _ = studioHost.run(command("studio.export"))
        CommandPalettePresenter.shared.close()
        await turn()
        check(first?.kind == .exportOptions && studio.paletteRequest?.kind == .exportOptions && studio.paletteRequest != first,
              "each request is its own, so a button that appears later never takes an old one")
        studio.paletteRequest = nil

        // Sol's second review: a recording made by a newer Sukusho is read-only; its redaction can't be saved.
        let future = RecordingSession(directoryURL: URL(fileURLWithPath: home).appendingPathComponent("future.sukushorec"))
        try FileManager.default.createDirectory(at: future.directoryURL, withIntermediateDirectories: false)
        try FileManager.default.copyItem(at: movieURL, to: future.screenURL)
        var newer = RecordingEditDocument(style: .init(), zoomEnabled: false, zoomCues: [])
        newer.formatVersion = 99
        let saved = try CaptureManifest.encoder.encode(newer)
        try saved.write(to: future.editDocumentURL)
        let futureStudio = RecordingStudioModel(url: future.directoryURL)
        await futureStudio.load()
        let futureHost = AppCommandPaletteHost(context: .studio(StudioPaletteHooks(model: futureStudio, inspectorShown: { true },
                                                                                    toggleInspector: {})), windowTitle: "Check")
        check(futureStudio.isReadOnlyNewerFormat, "the newer project opens read-only")
        for id in ["studio.blur", "studio.pixelate", "studio.autoZoom", "studio.translate", "studio.export"] {
            let reason = futureHost.state(of: command(id)).reason
            check(reason == "made by a newer Sukusho", "\(id): made by a newer Sukusho (is \(reason ?? "runs"))")
        }
        futureStudio.addRedaction(atEditorTime: 0, mode: .blur)
        check(futureStudio.redactions.isEmpty && alerts.isEmpty && (try? Data(contentsOf: future.editDocumentURL)) == saved,
              "a redaction there is refused before it's made: no alert, the project file as it was")
        futureStudio.teardown()

        // Every command that isn't a step or a switch has a handler in action(for:): dispatch, not what each does
        // (finding 3: three went to an empty closure). Each window's hooks are stand-ins here.
        let editor = EditorPaletteHooks(model: nil, selectTool: { _ in }, pickColor: {}, measure: {}, inspectorShown: { true },
                                        toggleInspector: {}, uploadUnavailable: { nil }, openUpload: {})
        let hosts: [(PaletteWindow, AppCommandPaletteHost)] = [
            (.library, AppCommandPaletteHost(context: .library(library), windowTitle: nil)),
            (.editor, AppCommandPaletteHost(context: .editor(editor), windowTitle: nil)), (.studio, studioHost),
        ]
        var unhandled: [String] = []
        for command in PaletteCommand.catalog where command.step == nil && !command.isSwitch {
            guard let host = hosts.first(where: { command.scope.isListed(in: $0.0) })?.1 else { continue }
            if !host.hasAction(for: command.id) { unhandled.append(command.id) }
        }
        check(unhandled.isEmpty, "every command that isn't a step or a switch has a handler\(unhandled.isEmpty ? "" : ": not \(unhandled)")")
        check(alerts.isEmpty, "no failure alert came up\(alerts.isEmpty ? "" : ": \(alerts)")")

        studio.teardown()
        // This binary's own preferences, which the fresh home doesn't hold: the runner trashes their file too.
        defaults.removePersistentDomain(forName: Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName)
        print(failures == 0 ? "All palette checks passed." : "\(failures) palette check(s) failed.")
        exit(failures == 0 ? 0 : 1)
    }
}
