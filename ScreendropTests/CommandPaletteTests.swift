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
                [PaletteRow(id: "lake", title: "Lake at dawn", subtitle: "Screenshot · 1672 × 941"),
                 PaletteRow(id: "roads", title: "Slow Roads walkthrough", subtitle: "Recording · 2560 × 1600")]
            case .clipboardHistory:
                // As the ⌃⌘V popup's own list: it searches the clips itself.
                ["npm run build", "https://example.com", "Meeting notes"]
                    .filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }
                    .map { PaletteRow(id: $0, title: $0) }
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
