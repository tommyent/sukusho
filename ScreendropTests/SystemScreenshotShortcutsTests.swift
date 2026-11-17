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
}
