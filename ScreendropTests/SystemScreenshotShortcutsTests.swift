import AppKit
import Testing

/// The owner, 2026-11-17 (beta 1): Settings and a one-time notice warn when a Sukusho shortcut is one of macOS's
/// screenshot shortcuts that is still on. These check the rule on dictionaries shaped as macOS stores them.
struct SystemScreenshotShortcutsTests {
    private let shiftCommand: UInt = 1_179_648            // ⇧⌘, as stored
    private let controlShiftCommand: UInt = 1_441_792     // ⌃⇧⌘

    private func entry(_ enabled: Bool, character: Int, keyCode: Int, flags: UInt) -> [String: Any] {
        ["enabled": enabled, "value": ["type": "standard", "parameters": [character, keyCode, Int(flags)]]]
    }

    /// As the owner's Air stores them: all five off.
    private var allOff: [String: Any] {
        ["28": entry(false, character: 51, keyCode: 20, flags: shiftCommand),
         "29": entry(false, character: 51, keyCode: 20, flags: controlShiftCommand),
         "30": entry(false, character: 52, keyCode: 21, flags: shiftCommand),
         "31": entry(false, character: 52, keyCode: 21, flags: controlShiftCommand),
         "184": entry(false, character: 53, keyCode: 23, flags: shiftCommand)]
    }

    private let shift3 = HotkeyShortcut(modifiers: [.shift, .command], keyCode: 20)
    private let shift4 = HotkeyShortcut(modifiers: [.shift, .command], keyCode: 21)
    private let shift5 = HotkeyShortcut(modifiers: [.shift, .command], keyCode: 23)

    @Test func entriesOffMeanNoClash() {
        #expect(SystemScreenshotShortcuts.enabled(in: allOff).isEmpty)
        let sukusho = CaptureHotkeyAction.allCases.reduce(into: [CaptureHotkeyAction: HotkeyShortcut]()) { $0[$1] = $1.defaultShortcut }
        #expect(SystemScreenshotShortcuts.clashes(sukusho, with: SystemScreenshotShortcuts.enabled(in: allOff)).isEmpty)
    }

    /// Entries never changed aren't in the file: macOS has them on, with its own keys.
    @Test func missingEntriesAreMacOSsDefaultsOn() {
        let system = SystemScreenshotShortcuts.enabled(in: [:])
        #expect(system == Set(SystemScreenshotShortcuts.defaults.values))
        #expect(SystemScreenshotShortcuts.enabled(in: nil) == system)
        let sukusho = CaptureHotkeyAction.allCases.reduce(into: [CaptureHotkeyAction: HotkeyShortcut]()) { $0[$1] = $1.defaultShortcut }
        // Sukusho's defaults: 3 Area, 4 Scrolling, 5 Text clash; 1, 2 and 6 don't.
        #expect(SystemScreenshotShortcuts.clashes(sukusho, with: system) == [.area, .textCapture, .scrollingCapture])
    }

    /// Only ⇧⌘5 turned back on: only Capture Text clashes, and a shortcut the user recorded counts as it is.
    @Test func recordedShortcutsAndSingleEntries() {
        var hotkeys = allOff
        hotkeys["184"] = entry(true, character: 53, keyCode: 23, flags: shiftCommand)
        let system = SystemScreenshotShortcuts.enabled(in: hotkeys)
        #expect(system == [shift5])

        var sukusho: [CaptureHotkeyAction: HotkeyShortcut] = [.textCapture: shift5, .area: shift3]
        #expect(SystemScreenshotShortcuts.clashes(sukusho, with: system) == [.textCapture])
        // Capture Text recorded on other keys, and Area recorded onto ⇧⌘5 instead.
        sukusho = [.textCapture: HotkeyShortcut(modifiers: [.shift, .command], keyCode: 31), .area: shift5]
        #expect(SystemScreenshotShortcuts.clashes(sukusho, with: system) == [.area])
        // A cleared Sukusho shortcut clashes with nothing.
        #expect(SystemScreenshotShortcuts.clashes([:], with: system).isEmpty)
    }

    /// Same key, other modifiers: not the same shortcut, either way round.
    @Test func modifiersMustMatchExactly() {
        var hotkeys = allOff
        hotkeys["29"] = entry(true, character: 51, keyCode: 20, flags: controlShiftCommand)   // ⌃⇧⌘3 on
        let system = SystemScreenshotShortcuts.enabled(in: hotkeys)
        #expect(SystemScreenshotShortcuts.clashes([.area: shift3], with: system).isEmpty)
        let controlShift3 = HotkeyShortcut(modifiers: [.control, .shift, .command], keyCode: 20)
        #expect(SystemScreenshotShortcuts.clashes([.area: controlShift3], with: system) == [.area])
        #expect(SystemScreenshotShortcuts.clashes([.area: HotkeyShortcut(modifiers: [.command], keyCode: 20)], with: system).isEmpty)
    }

    /// macOS's own shortcut moved to other keys in System Settings: those keys count, not macOS's defaults.
    @Test func macOSsChangedKeysCount() {
        var hotkeys = allOff
        hotkeys["30"] = entry(true, character: 56, keyCode: 28, flags: shiftCommand)   // ⇧⌘8
        let system = SystemScreenshotShortcuts.enabled(in: hotkeys)
        #expect(system == [HotkeyShortcut(modifiers: [.shift, .command], keyCode: 28)])
        #expect(SystemScreenshotShortcuts.clashes([.area: shift4], with: system).isEmpty)
    }

    /// desk-lead, SC2: the words say what one press does now. Every one of macOS's screenshot shortcuts starts its
    /// Screenshot UI, which closes Sukusho's area picker (VM: ⇧⌘3, ⇧⌘4, ⇧⌘5), so Area, Capture Text and Scrolling
    /// Capture don't run; other actions run as well. Which entry a clash hit follows macOS's keys, moved or not.
    @Test func theWordsSayWhatOnePressDoes() {
        let entries = SystemScreenshotShortcuts.enabledEntries(in: [:])
        #expect(SystemScreenshotShortcuts.entry(for: shift5, in: entries) == 184)
        #expect(SystemScreenshotShortcuts.entry(for: shift3, in: entries) == 28)
        #expect(SystemScreenshotShortcuts.entry(for: HotkeyShortcut(modifiers: [.command], keyCode: 20), in: entries) == nil)
        #expect([CaptureHotkeyAction.area, .textCapture, .scrollingCapture].allSatisfy {
            SystemScreenshotShortcuts.outcome(for: $0) == .macOSOnly })
        #expect([CaptureHotkeyAction.fullscreen, .window, .screenRecording].allSatisfy {
            SystemScreenshotShortcuts.outcome(for: $0) == .both })

        #expect(SystemScreenshotShortcuts.warning(for: .textCapture, shortcut: shift5, entry: 184)
            .hasPrefix("On ⇧⌘5, macOS opens its Screenshot toolbar instead, so Capture Text doesn’t run."))
        #expect(SystemScreenshotShortcuts.warning(for: .area, shortcut: shift3, entry: 28)
            .hasPrefix("On ⇧⌘3, macOS takes its own screenshot instead, so Area doesn’t run."))
        // Fullscreen recorded onto ⇧⌘3: both run.
        #expect(SystemScreenshotShortcuts.warning(for: .fullscreen, shortcut: shift3, entry: 28)
            .hasPrefix("On ⇧⌘3, macOS also takes its own screenshot, so one press does both."))

        // The notice: Sukusho's defaults, keys in order whatever order the actions come in.
        let notice = SystemScreenshotShortcuts.noticeText([(.textCapture, shift5, 184), (.scrollingCapture, shift4, 30),
                                                           (.area, shift3, 28)])
        #expect(notice.hasPrefix("On ⇧⌘3, ⇧⌘4, and ⇧⌘5, only macOS’s own screenshot runs, so Sukusho’s Area, Scrolling Capture, and Capture Text don’t."))
        #expect(!notice.contains("as well"))
        let single = SystemScreenshotShortcuts.noticeText([(.fullscreen, shift3, 28)])
        #expect(single.hasPrefix("On ⇧⌘3, macOS’s screenshot runs as well as Sukusho’s Fullscreen."))
    }
}
