import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import Testing

/// The command palette (sd-458l), driven as the keys drive it: typing, ↑↓, ↩, →, Esc, steps, grey rows with their
/// reasons, switches, Change Theme's try-on, each window's own list and the Clipboard History step. The host is a
/// stand-in that records what the palette asks the app to do.
@MainActor
struct CommandPaletteTests {
    final class FakeHost: CommandPaletteHost {
        var window: PaletteWindow
        var selectionTitle: String? = "Lake at dawn"
        var place = "Library · Lake at dawn"
        var reasons: [String: String] = [:]
        var hidden: Set<String> = []
        var switches: [String: Bool] = [:]
        var clipboardOn = true
        var savedTheme = "Classic"
        private(set) var ran: [String] = []
        private(set) var chosen: [(step: PaletteStep, id: String)] = []
        private(set) var copied: [String] = []
        private(set) var triedOn: [String?] = []
        private(set) var searched: [String] = []

        init(window: PaletteWindow) { self.window = window }

        func state(of command: PaletteCommand) -> PaletteCommandState {
            if hidden.contains(command.id) { return .hidden }
            if command.id == "open.clipboardStep", !clipboardOn { return .hidden }
            var state = PaletteCommandState(reason: reasons[command.id], isOn: switches[command.id])
            if command.id == "look.theme" { state.detail = savedTheme }
            return state
        }

        func keys(for command: PaletteCommand) -> [String] {
            if case .keys(let keys) = command.keys { return keys }
            return []
        }

        func rows(for step: PaletteStep, query: String) -> [PaletteRow] {
            switch step {
            case .changeTheme:
                ["Classic", "Chip", "Glass"].map { PaletteRow(id: $0.lowercased(), title: $0, ticked: $0 == savedTheme) }
            case .goTo:
                ["All Captures", "Screenshots", "Recordings", "Received"].map { PaletteRow(id: $0, title: $0, detail: "Library") }
            case .recentCaptures:
                [PaletteRow(id: "lake", title: "Lake at dawn", subtitle: "Screenshot · 1672 × 941", isCopyable: true),
                 PaletteRow(id: "roads", title: "Slow Roads walkthrough", subtitle: "Recording · 2560 × 1600", isCopyable: true),
                 PaletteRow(id: "all", title: "Show All Captures…", symbol: "square.grid.2x2")]
            case .clipboardHistory:
                // As the ⌃⌘V popup's own list: it searches the clips itself.
                ["npm run build", "https://example.com", "Meeting notes"]
                    .filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }
                    .map { PaletteRow(id: $0, title: $0, isCopyable: true) }
            case .addTag:
                query.isEmpty ? [PaletteRow(id: "bug", title: "bug", ticked: true)]
                    : [PaletteRow(id: "new", title: "Add tag “\(query)”")]
            default: []
            }
        }

        func place(for step: PaletteStep) -> String? { step == .recentCaptures ? "2 captures" : nil }

        func run(_ command: PaletteCommand) -> PaletteOutcome {
            ran.append(command.id)
            if command.isSwitch { switches[command.id] = !(switches[command.id] ?? false) }
            return .close
        }

        func choose(_ row: PaletteRow, in step: PaletteStep) -> PaletteOutcome {
            chosen.append((step, row.choiceID))
            if step == .changeTheme { savedTheme = row.title }
            return step.staysOpen ? .stay : .close
        }

        func copy(_ row: PaletteRow, in step: PaletteStep) { copied.append(row.id) }
        func tryOn(_ row: PaletteRow?) { triedOn.append(row?.title) }
        func searchCaptures(for text: String) { searched.append(text) }
    }

    private func palette(_ window: PaletteWindow, _ configure: (FakeHost) -> Void = { _ in }) -> (CommandPaletteModel, FakeHost) {
        let host = FakeHost(window: window)
        configure(host)
        let model = CommandPaletteModel(host: host)
        return (model, host)
    }

    private func type(_ text: String, into model: CommandPaletteModel) {
        for letter in text { model.query.append(letter) }
    }

    // MARK: Typing and moving

    /// The mock's "rec" in the image editor: the editor's own tool first, then what works in any window, then a Library page
    /// found from the first list, each with its typed letters marked.
    @Test func typingNarrowsRanksAndMarks() {
        let (model, _) = palette(.editor)
        type("rec", into: model)
        let titles = model.rows.map(\.title)
        #expect(Array(titles.prefix(4)) == ["Rectangle", "Record Screen", "Recent Captures", "Recordings"])
        #expect(titles.contains("Go to Received"))
        let received = model.rows.first { $0.title == "Go to Received" }
        #expect(received?.marks == [6 ..< 9], "the letters of Received, not of Go to")
        #expect(model.rows.first?.marks == [0 ..< 3])
        #expect(model.selected == 0)
    }

    @Test func arrowsMoveAndStopAtTheEnds() {
        let (model, _) = palette(.library)
        model.press(.up)
        #expect(model.selected == 0)
        model.press(.down)
        model.press(.down)
        #expect(model.selected == 2)
        for _ in 0 ..< 500 { model.press(.down) }
        #expect(model.selected == model.rows.count - 1)
        type("x", into: model)
        #expect(model.selected == 0, "typing starts at the top again")
    }

    @Test func returnRunsAndCloses() {
        let (model, host) = palette(.library)
        var closed = false
        model.onClose = { closed = true }
        type("capture area", into: model)
        #expect(model.selectedRow?.title == "Capture Area")
        model.press(.enter)
        #expect(host.ran == ["capture.area"])
        #expect(closed)
    }

    // MARK: Steps

    @Test func rightGoesIntoAStepAndEscComesBackThenCloses() {
        let (model, _) = palette(.library)
        var closed = 0
        model.onClose = { closed += 1 }
        #expect(!model.press(.right), "→ on a row without › is the caret's")
        type("go to", into: model)
        #expect(model.selectedRow?.opens == .goTo)
        #expect(model.press(.right))
        #expect(model.step == .goTo)
        #expect(model.query.isEmpty)
        #expect(model.rows.map(\.title) == ["All Captures", "Screenshots", "Recordings", "Received"])
        type("shots", into: model)
        #expect(model.rows.map(\.title) == ["Screenshots"])
        model.press(.escape)
        #expect(model.step == .commands)
        #expect(model.query.isEmpty)
        #expect(closed == 0)
        model.press(.escape)
        #expect(closed == 1)
    }

    @Test func returnOnAStepRowGoesInAndAStepRowIsChosen() {
        let (model, host) = palette(.library)
        type("recent captures", into: model)
        model.press(.enter)
        #expect(model.step == .recentCaptures)
        #expect(model.selectedRow?.title == "Lake at dawn")
        #expect(model.place == "2 captures")
        model.press(.copy)
        #expect(host.copied == ["lake"])
        let (again, other) = palette(.library)
        type("recent", into: again)
        again.press(.right)
        again.press(.down)
        again.press(.enter)
        #expect(other.chosen.map(\.id) == ["roads"], "↩ opens the capture in its editor")
    }

    /// A Library page found from the first list runs as the step's own row.
    @Test func aPageFoundFromTheFirstListIsChosenInItsStep() {
        let (model, host) = palette(.library)
        type("received", into: model)
        #expect(model.selectedRow?.title == "Go to Received")
        model.press(.enter)
        #expect(host.chosen.first?.step == .goTo)
        #expect(host.chosen.first?.id == "Received")
    }

    // MARK: Grey rows and switches

    @Test func greyRowsSayWhyAndDoNothing() {
        let (model, host) = palette(.library) { $0.reasons["selection.revert"] = "not edited yet" }
        var closed = false
        model.onClose = { closed = true }
        type("revert to original", into: model)
        let row = model.selectedRow
        #expect(row?.title == "Revert to Original…")
        #expect(row?.reason == "not edited yet")
        #expect(row?.isEnabled == false)
        model.press(.enter)
        #expect(host.ran.isEmpty)
        #expect(!closed)
    }

    @Test func aSwitchFlipsAndStaysOpen() {
        let (model, host) = palette(.library) { $0.switches["switch.optimizeNew"] = true }
        var closed = false
        model.onClose = { closed = true }
        type("optimize new", into: model)
        #expect(model.selectedRow?.isOn == true)
        model.press(.enter)
        #expect(host.ran == ["switch.optimizeNew"])
        #expect(!closed)
        #expect(model.selectedRow?.isOn == false, "the row shows the new state at once")
    }

    // MARK: Change Theme

    @Test func changeThemeTriesOnAndEscPutsItBack() {
        let (model, host) = palette(.library) { $0.savedTheme = "Chip" }
        var closed = 0
        model.onClose = { closed += 1 }
        type("change theme", into: model)
        model.press(.right)
        #expect(model.step == .changeTheme)
        #expect(model.selectedRow?.title == "Chip", "opens on the one in use")
        model.press(.down)
        #expect(host.triedOn.last == "Glass")
        #expect(model.hints.contains { $0.label == "put Chip back" })
        model.press(.escape)
        #expect(host.triedOn.last == .some(nil), "Esc puts the saved theme back")
        #expect(model.step == .commands)
        #expect(closed == 0)
    }

    /// Typing in Change Theme tries on what's at the top, even when the top was selected already (Sol's finding 7: Glass
    /// showed selected while Classic stayed on), and with nothing matching, the saved one.
    @Test func changeThemeTriesOnWhatTypingPutsAtTheTop() {
        let (model, host) = palette(.library)
        type("change theme", into: model)
        model.press(.right)
        #expect(model.selected == 0 && host.triedOn.last == "Classic")
        type("glass", into: model)
        #expect(model.selectedRow?.title == "Glass")
        #expect(host.triedOn.last == "Glass", "what's selected is what's on")
        model.query = "zzz"
        #expect(model.selectedRow == nil)
        #expect(host.triedOn.last == .some(nil), "nothing matches: the saved theme")
    }

    @Test func changeThemeKeptIsNotPutBack() {
        let (model, host) = palette(.library)
        type("change theme", into: model)
        model.press(.enter)
        model.press(.down)
        model.press(.enter)
        #expect(host.chosen.map(\.id) == ["chip"])
        #expect(host.savedTheme == "Chip")
        #expect(!host.triedOn.contains(where: { $0 == nil }), "a kept theme isn't put back as the palette closes")
    }

    // MARK: Where it opened

    /// A window without commands of its own (Settings): only what runs in any window.
    @Test func aWindowWithoutItsOwnCommandsListsTheSharedOnes() {
        let (model, _) = palette(.other)
        let ids = Set(model.rows.compactMap(\.command))
        let expected = Set(PaletteCommand.catalog.filter { $0.scope == .anywhere }.map(\.id))
        #expect(ids == expected)
        #expect(ids.contains("look.theme"))
        #expect(!ids.contains("selection.copy"))
        #expect(!ids.contains("tool.rectangle"))
        #expect(model.rows.first?.title == "Capture Fullscreen")
    }

    @Test func eachWindowListsItsOwnCommandsAndNotTheOthers() {
        let (library, _) = palette(.library)
        let (editor, _) = palette(.editor)
        let (studio, _) = palette(.studio)
        let ids = { (model: CommandPaletteModel) in Set(model.rows.compactMap(\.command)) }
        #expect(ids(library).contains("selection.copy") && !ids(library).contains("tool.rectangle"))
        #expect(ids(editor).contains("tool.rectangle") && !ids(editor).contains("studio.split"))
        #expect(ids(studio).contains("studio.split") && !ids(studio).contains("selection.copy"))
        #expect([library, editor, studio].allSatisfy { ids($0).contains("window.inspector") && ids($0).contains("look.theme") })
        // Grouped under their headings, in the catalog's group order.
        let groups = library.rows.compactMap(\.group)
        #expect(groups == groups.sorted())
    }

    // MARK: No match

    @Test func noMatchOffersToSearchCaptures() {
        let (model, host) = palette(.library)
        var closed = false
        model.onClose = { closed = true }
        type("watermrk", into: model)
        #expect(model.isNoMatch)
        #expect(model.rows.map(\.title) == ["Search captures for “watermrk”"])
        #expect(model.hints.map(\.label) == ["search captures", "close"])
        model.press(.enter)
        #expect(host.searched == ["watermrk"])
        #expect(closed)
    }

    // MARK: Clipboard History

    /// ↩ copies the clip, as ⌘C does, to paste in any app (the owner, 2026-11-25).
    @Test func clipboardHistoryStepListsClipsNarrowsAndCopies() throws {
        let (model, host) = palette(.editor)
        var closed = 0
        model.onClose = { closed += 1 }
        type("clipboard", into: model)
        let titles = model.rows.map(\.title)
        #expect(titles.contains("Clipboard History") && titles.contains("Clipboard History Popup"),
                "the step sits beside the row that opens the ⌃⌘V popup")
        let step = model.rows.firstIndex { $0.opens == .clipboardHistory }
        model.selected = try #require(step)
        model.press(.right)
        #expect(model.step == .clipboardHistory)
        #expect(model.rows.count == 3)
        type("exa", into: model)
        #expect(model.rows.map(\.title) == ["https://example.com"])
        #expect(model.hints.first?.keys == ["↩"] && model.hints.first?.label == "copy")
        #expect(!model.hints.contains { $0.label.contains("paste") }, "the key line says nothing about pasting here")
        model.press(.enter)
        #expect(host.chosen.map(\.step) == [.clipboardHistory])
        #expect(host.chosen.map(\.id) == ["https://example.com"])
        #expect(closed == 1, "copied, the palette closes")

        // ⌘C does the same.
        let (again, other) = palette(.editor)
        type("clipboard history", into: again)
        again.press(.right)
        again.press(.copy)
        #expect(other.copied == ["npm run build"])
    }

    /// ⌘C on Show All Captures… copies nothing, so it goes on to the field (Sol's other notes).
    @Test func copyIsOnlyForCapturesAndClips() {
        let (model, host) = palette(.library)
        type("recent captures", into: model)
        model.press(.right)
        model.press(.down)
        model.press(.down)
        #expect(model.selectedRow?.title == "Show All Captures…")
        #expect(!model.press(.copy), "the field gets ⌘C")
        #expect(host.copied.isEmpty)
    }

    // MARK: Studio's inspector, timeline and toolbar, and the editor's Upload

    private static let studioCommands: [(title: String, id: String)] = [
        ("Auto Zoom", "studio.autoZoom"), ("Blur at Playhead", "studio.blur"), ("Pixelate at Playhead", "studio.pixelate"),
        ("Add Video Overlay…", "studio.videoOverlay"), ("Detach Audio", "studio.detachAudio"),
        ("Reset All Clip Edits…", "studio.resetClips"), ("Translate Captions…", "studio.translate"),
        ("Isolate Voice", "studio.isolateVoice"), ("Zoom In", "studio.timelineZoomIn"), ("Zoom Out", "studio.timelineZoomOut"),
        ("Fit Timeline", "studio.fitTimeline"), ("Export…", "studio.export"), ("Upload", "studio.upload"),
    ]

    /// Studio lists them and no other window does; each is found by its name and runs, and Isolate Voice is a switch
    /// that stays open.
    @Test func studiosNewCommandsAreListedAndRun() {
        let ids = Set(Self.studioCommands.map(\.id))
        let (studio, _) = palette(.studio)
        #expect(ids.isSubset(of: Set(studio.rows.compactMap(\.command))))
        for window in [PaletteWindow.library, .editor, .other] {
            let (model, _) = palette(window)
            #expect(Set(model.rows.compactMap(\.command)).isDisjoint(with: ids), "\(window)")
        }
        for (title, id) in Self.studioCommands {
            let (model, host) = palette(.studio)
            var closed = false
            model.onClose = { closed = true }
            type(title.replacingOccurrences(of: "…", with: ""), into: model)
            #expect(model.selectedRow?.command == id, "\(title)")
            model.press(.enter)
            #expect(host.ran == [id], "\(title)")
            #expect(closed == (id != "studio.isolateVoice"), "\(title): a switch stays open")
        }
    }

    /// While one can't run, its row is grey with the app's reason and ↩ does nothing.
    @Test func studiosNewCommandsAreGreyWithTheirReasons() {
        let reasons = Dictionary(uniqueKeysWithValues: Self.studioCommands.map { ($0.id, "reason for \($0.id)") })
        for (title, id) in Self.studioCommands {
            let (model, host) = palette(.studio) { $0.reasons = reasons }
            type(title.replacingOccurrences(of: "…", with: ""), into: model)
            #expect(model.selectedRow?.reason == "reason for \(id)")
            model.press(.enter)
            #expect(host.ran.isEmpty, "\(title)")
        }
    }

    /// The editor's Upload, in the editor only; grey with its reason while the toolbar has none to press.
    @Test func theEditorsUploadIsListedAndRuns() {
        let (model, host) = palette(.editor)
        type("upload", into: model)
        #expect(model.selectedRow?.command == "editor.upload")
        model.press(.enter)
        #expect(host.ran == ["editor.upload"])
        let (studio, _) = palette(.studio)
        #expect(!studio.rows.contains { $0.command == "editor.upload" })
        let (grey, idle) = palette(.editor) { $0.reasons["editor.upload"] = "Cloud isn’t set up" }
        type("upload", into: grey)
        #expect(grey.selectedRow?.reason == "Cloud isn’t set up")
        grey.press(.enter)
        #expect(idle.ran.isEmpty)
    }

    @Test func clipboardHistoryStepIsShownOnlyWhileHistoryIsOn() {
        let (model, _) = palette(.library) { $0.clipboardOn = false }
        #expect(!model.rows.contains { $0.opens == .clipboardHistory })
    }

    // MARK: Add Tag stays open

    @Test func addTagTicksAndStaysThenOffersANewTag() {
        let (model, host) = palette(.library)
        var closed = false
        model.onClose = { closed = true }
        type("add tag", into: model)
        model.press(.enter)
        #expect(model.step == .addTag)
        model.press(.enter)
        #expect(host.chosen.map(\.id) == ["bug"])
        #expect(!closed)
        type("urgent", into: model)
        #expect(model.rows.map(\.title) == ["Add tag “urgent”"], "the field is the answer here, not a filter")
    }

    // MARK: Matching, contrast and the catalog

    @Test func matchingTiers() {
        #expect(PaletteMatch.match("cap", in: "Capture Area")?.tier == .prefix)
        #expect(PaletteMatch.match("area", in: "Capture Area")?.tier == .wordStart)
        #expect(PaletteMatch.match("ptu", in: "Capture Area")?.tier == .inside)
        let initials = PaletteMatch.match("cf", in: "Capture Fullscreen")
        #expect(initials?.tier == .initials)
        #expect(initials?.ranges == [0 ..< 1, 8 ..< 9])
        #expect(PaletteMatch.match("cpa", in: "Capture Area") == nil, "letters merely in order don't count")
        #expect(PaletteMatch.match("rec", in: "Numbered Circle") == nil)
        #expect(PaletteMatch.match("zzz", in: "Capture Area") == nil)
        #expect(PaletteMatch.match("area capture", in: "Capture Area")?.ranges == [0 ..< 7, 8 ..< 12], "every word, in any order")
    }

    @Test func accentIsLiftedForWhiteText() {
        let blue = PaletteAccent.RGB(red: 0, green: 0.478, blue: 1)
        #expect(PaletteAccent.contrast(blue, with: .init(red: 1, green: 1, blue: 1)) < 4.5)
        let lifted = PaletteAccent.liftedForWhiteText(blue)
        #expect(PaletteAccent.contrast(lifted, with: .init(red: 1, green: 1, blue: 1)) >= 4.5)
        #expect(lifted.blue > lifted.red, "still blue")
        let deep = PaletteAccent.RGB(red: 0.1, green: 0.1, blue: 0.4)
        #expect(PaletteAccent.liftedForWhiteText(deep) == deep)
        let yellow = PaletteAccent.RGB(red: 1, green: 0.8, blue: 0)
        #expect(PaletteAccent.contrast(PaletteAccent.liftedForWhiteText(yellow), with: .init(red: 1, green: 1, blue: 1)) >= 4.5)
    }

    /// Every word on the selected row's fill reads at 4.5:1 for any accent, yellow too. At the 70 and 85 % this first
    /// had, a grey row's title and reason fell short on yellow (Sol's finding 11).
    @Test func everyWordOnTheFillReads() {
        let accents: [PaletteAccent.RGB] = [
            .init(red: 0, green: 0.478, blue: 1), .init(red: 1, green: 0.8, blue: 0), .init(red: 0.2, green: 0.78, blue: 0.35),
            .init(red: 1, green: 0.58, blue: 0), .init(red: 0.6, green: 0.6, blue: 0.6), .init(red: 1, green: 0.18, blue: 0.33),
            .init(red: 0.69, green: 0.32, blue: 0.87),
        ]
        for accent in accents {
            let fill = PaletteAccent.liftedForWhiteText(accent)
            let words = PaletteAccent.white(PaletteAccent.textOnFill, over: fill)
            #expect(PaletteAccent.contrast(words, with: fill) >= 4.5, "\(accent)")
        }
        let yellow = PaletteAccent.liftedForWhiteText(.init(red: 1, green: 0.8, blue: 0))
        #expect(PaletteAccent.contrast(PaletteAccent.white(0.7, over: yellow), with: yellow) < 4.5, "the old grey title's strength")
    }

    /// The palette is in captures as the window under it is: other apps see it, and Sukusho's own follow "Include Sukusho
    /// windows in captures". It was private, left out of every capture (m1's pass, 2026-11-25).
    @Test func thePanelFollowsTheCaptureSetting() {
        let key = ScreendropPreferences.includeAppWindowsInCapturesKey
        let previous = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(previous, forKey: key) }
        let exclusion = PreviewWindowCaptureExclusion.shared
        // A fresh panel each time: on a window the window server already holds, `.readOnly` didn't read back after
        // `.none` within the same turn (seen here, 2026-11-25), which the deferred windows of the tests above don't show.
        for include in [true, false] {
            UserDefaults.standard.set(include, forKey: key)
            let panel = CommandPalettePanel()
            #expect(panel.sharingType == .readOnly, "other apps and screen sharing see it; a private one they don't")
            #expect(exclusion.hidesFromOwnCaptures(panel) == !include)
            exclusion.beginOwnCapture()
            #expect(panel.sharingType == (include ? .readOnly : .none), "Sukusho's own captures follow the setting")
            exclusion.endOwnCapture()
        }
    }

    // MARK: The palette's keys

    /// A Capture Fullscreen recorded as ⇧⌘P before the palette came keeps it; the palette has no keys until some are
    /// recorded, and gets ⇧⌘P back once it's free. Other rows' defaults don't yield (Sol's finding 4).
    @Test func thePalettesDefaultYieldsToRecordedKeys() throws {
        let name = "palette-keys-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let palette = CaptureHotkeyAction.commandPalette, shiftP = palette.defaultShortcut
        #expect(CaptureHotkeyPreferences.shortcut(for: palette, defaults: defaults) == shiftP)
        CaptureHotkeyPreferences.saveShortcut(shiftP, for: .fullscreen, defaults: defaults)
        #expect(CaptureHotkeyPreferences.shortcut(for: palette, defaults: defaults) == nil)
        #expect(CaptureHotkeyPreferences.defaultTakenBy(palette, defaults: defaults) == .fullscreen)
        #expect(CaptureHotkeyPreferences.shortcut(for: .fullscreen, defaults: defaults) == shiftP)
        #expect(CaptureHotkeyPreferences.conflictingAction(for: shiftP, excluding: .fullscreen, defaults: defaults) == nil,
                "one shortcut, one action")
        let shiftR = HotkeyShortcut(modifiers: [.shift, .command], keyCode: Int(kVK_ANSI_R))
        CaptureHotkeyPreferences.saveShortcut(shiftR, for: palette, defaults: defaults)
        #expect(CaptureHotkeyPreferences.shortcut(for: palette, defaults: defaults) == shiftR, "recorded keys are its own")
        CaptureHotkeyPreferences.resetToDefault(palette, defaults: defaults)
        CaptureHotkeyPreferences.resetToDefault(.fullscreen, defaults: defaults)
        #expect(CaptureHotkeyPreferences.shortcut(for: palette, defaults: defaults) == shiftP, "free again, ⇧⌘P is back")
        // As on the mini: Recording recorded on Capture Text's default keeps both, as before.
        let shiftO = CaptureHotkeyAction.textCapture.defaultShortcut
        CaptureHotkeyPreferences.saveShortcut(shiftO, for: .screenRecording, defaults: defaults)
        #expect(CaptureHotkeyPreferences.shortcut(for: .textCapture, defaults: defaults) == shiftO)
        #expect(CaptureHotkeyPreferences.defaultTakenBy(.textCapture, defaults: defaults) == nil)
    }

    /// Keys Sukusho's own menus and windows have are refused for the palette: ⌘S is File › Save and the editor's.
    @Test func appCommandsKeepTheirKeys() {
        let command = { (key: Int) in HotkeyShortcut(modifiers: [.command], keyCode: key) }
        #expect(CaptureHotkeyPreferences.appCommand(using: command(kVK_ANSI_S)) == "Save")
        #expect(CaptureHotkeyPreferences.appCommand(using: command(kVK_ANSI_B)) == "Split at Playhead")
        #expect(CaptureHotkeyPreferences.appCommand(using: HotkeyShortcut(modifiers: [.option, .command], keyCode: kVK_ANSI_I))
                == "Show Inspector")
        #expect(CaptureHotkeyPreferences.appCommand(using: CaptureHotkeyAction.commandPalette.defaultShortcut) == nil, "⇧⌘P is free")
        let names = CaptureHotkeyPreferences.appCommands.map(\.shortcut)
        #expect(!CaptureHotkeyAction.allCases.contains { names.contains($0.defaultShortcut) }, "no default is a menu's")
    }

    @Test func catalogIdsAreUniqueAndEveryStepRowHasAStep() {
        let ids = PaletteCommand.catalog.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(!PaletteCommand.catalog.contains { $0.isSwitch && $0.step != nil })
        // Every step but the first list is opened by some command.
        let opened = Set(PaletteCommand.catalog.compactMap(\.step))
        #expect(opened == Set(PaletteStep.allCases).subtracting([.commands]))
        // US spelling in every title.
        #expect(!PaletteCommand.catalog.contains { $0.title.contains("Colour") || $0.title.contains("colour") })
    }

    /// Change Theme's try-on is what every themed colour reads, and putting it back leaves the saved theme.
    @Test func themeTryOnIsReadAndPutBack() {
        let saved = AppTheme.named(UserDefaults.standard.string(forKey: AppTheme.darkKey), dark: true)
        ThemeTryOn.show(AppTheme.chipDark.id, dark: true)
        #expect(AppTheme.current(dark: true).id == "chip-dark")
        #expect(AppTheme.current(dark: false).id == AppTheme.named(UserDefaults.standard.string(forKey: AppTheme.lightKey), dark: false).id)
        ThemeTryOn.show(nil, dark: true)
        #expect(AppTheme.current(dark: true) == saved)
        #expect(ThemeTryOn.id(dark: true) == nil)
    }
}
