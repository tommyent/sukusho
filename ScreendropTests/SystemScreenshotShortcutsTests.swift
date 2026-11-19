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
        // Sukusho's defaults (the owner's set): 3 Area, 4 Scrolling, 5 Recording clash; 1, 2, O, L and V don't.
        #expect(SystemScreenshotShortcuts.clashes(sukusho, with: system) == [.area, .scrollingCapture, .screenRecording])
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

    /// The owner, 2026-11-17: the warning is short and plain, names only the keys that clash, in key order, and never
    /// starts with "On". Which entry a clash hit follows macOS's keys, moved or not.
    @Test func theWarningIsShortAndPlain() {
        let entries = SystemScreenshotShortcuts.enabledEntries(in: [:])
        #expect(SystemScreenshotShortcuts.entry(for: shift5, in: entries) == 184)
        #expect(SystemScreenshotShortcuts.entry(for: shift3, in: entries) == 28)
        #expect(SystemScreenshotShortcuts.entry(for: HotkeyShortcut(modifiers: [.command], keyCode: 20), in: entries) == nil)

        let several: [SystemScreenshotShortcuts.Clash] = [(.screenRecording, shift5), (.scrollingCapture, shift4), (.area, shift3)]
        // The words desk-lead agreed with the owner, for Sukusho's three default clashes.
        #expect(SystemScreenshotShortcuts.warning(several, canUseOtherKeys: true)
            == "⇧⌘3, ⇧⌘4 and ⇧⌘5 are also macOS’s screenshot shortcuts. Give Sukusho other keys (you can change them), or turn macOS’s off in Keyboard Shortcuts › Screenshots.")
        #expect(SystemScreenshotShortcuts.warning([(.area, shift3), (.screenRecording, shift5)], canUseOtherKeys: true)
            .hasPrefix("⇧⌘3 and ⇧⌘5 are also"))
        #expect(SystemScreenshotShortcuts.warning([(.area, shift3)], canUseOtherKeys: true)
            == "⇧⌘3 is also one of macOS’s screenshot shortcuts. Give Sukusho another key (you can change it), or turn macOS’s off in Keyboard Shortcuts › Screenshots.")
        #expect(SystemScreenshotShortcuts.warning([(.area, shift3)], canUseOtherKeys: false)
            == "⇧⌘3 is also one of macOS’s screenshot shortcuts. Pick another key for Sukusho, or turn macOS’s off in Keyboard Shortcuts › Screenshots.")
        #expect(!SystemScreenshotShortcuts.warning(several, canUseOtherKeys: true).hasPrefix("On"))
    }

    /// The owner's set as the defaults, and his row order.
    @Test func theOwnersDefaultsAndOrder() {
        let shiftCmd = { (key: Int) in HotkeyShortcut(modifiers: [.shift, .command], keyCode: key) }
        let expected: [CaptureHotkeyAction: HotkeyShortcut] = [
            .fullscreen: shiftCmd(18), .window: shiftCmd(19), .area: shiftCmd(20), .scrollingCapture: shiftCmd(21),
            .drawing: HotkeyShortcut(modifiers: [.control, .shift], keyCode: 46),
            .screenRecording: shiftCmd(23), .textCapture: shiftCmd(31), .library: shiftCmd(37),
            .clipboardHistory: HotkeyShortcut(modifiers: [.control, .command], keyCode: 9),
        ]
        for action in CaptureHotkeyAction.allCases { #expect(action.defaultShortcut == expected[action], "\(action)") }
        #expect(Set(expected.values).count == expected.count, "no two defaults share keys")
        #expect(!expected.values.contains(shiftCmd(22)), "nothing on ⇧⌘6")
        #expect(CaptureHotkeyAction.settingsOrder
            == [.fullscreen, .window, .area, .scrollingCapture, .screenRecording, .drawing, .textCapture, .library, .clipboardHistory])
        #expect(Set(CaptureHotkeyAction.settingsOrder) == Set(CaptureHotkeyAction.allCases))

    }

    private func altShift(_ keyCode: Int) -> HotkeyShortcut { HotkeyShortcut(modifiers: [.option, .shift, .command], keyCode: keyCode) }

    /// The owner, 2026-11-17: Use Other Keys moves each clashing shortcut to the same digit with ⌥⇧⌘, else ⌃⌥⌘, never
    /// onto anything macOS has on or another Sukusho action uses, and leaves the rest alone.
    @Test func useOtherKeysPicksFreeKeys() {
        let sukusho = CaptureHotkeyAction.allCases.reduce(into: [CaptureHotkeyAction: HotkeyShortcut]()) { $0[$1] = $1.defaultShortcut }
        let clashing: [CaptureHotkeyAction] = [.area, .scrollingCapture, .screenRecording]
        let system = SystemScreenshotShortcuts.enabled(in: [:])
        let moved = SystemScreenshotShortcuts.otherKeys(for: clashing, shortcuts: sukusho, system: system)
        #expect(moved == [.area: altShift(20), .scrollingCapture: altShift(21), .screenRecording: altShift(23)])
        #expect(moved[.fullscreen] == nil)

        // macOS has ⌥⇧⌘3 on (some user's own shortcut): Area falls back to ⌃⌥⌘3.
        let withOption3 = system.union([altShift(20)])
        #expect(SystemScreenshotShortcuts.otherKeys(for: [.area], shortcuts: sukusho, system: withOption3)[.area]
            == HotkeyShortcut(modifiers: [.control, .option, .command], keyCode: 20))

        // Sol, R9-1: macOS's ⇧⌘5 entry remapped to ⇧⌘Q, and Capture Text recorded onto ⇧⌘Q. It still clashes, so the
        // warning shows, but no new key is offered: ⌥⇧⌘Q is Apple's immediate log-out.
        let shiftQ = HotkeyShortcut(modifiers: [.shift, .command], keyCode: 12)
        var remapped = allOff
        remapped["184"] = entry(true, character: 113, keyCode: 12, flags: shiftCommand)
        let remappedSystem = SystemScreenshotShortcuts.enabled(in: remapped)
        var onQ = sukusho
        onQ[.textCapture] = shiftQ
        #expect(SystemScreenshotShortcuts.clashes(onQ, with: remappedSystem) == [.textCapture])
        #expect(SystemScreenshotShortcuts.candidates(for: shiftQ).isEmpty)
        #expect(SystemScreenshotShortcuts.otherKeys(for: [.textCapture], shortcuts: onQ, system: remappedSystem).isEmpty)

        // Another Sukusho action already on ⌥⇧⌘5 and ⌃⌥⌘5: Screen Recording has no free key and stays out.
        var taken = sukusho
        taken[.library] = altShift(23)
        taken[.window] = HotkeyShortcut(modifiers: [.control, .option, .command], keyCode: 23)
        #expect(SystemScreenshotShortcuts.otherKeys(for: [.screenRecording], shortcuts: taken, system: system).isEmpty)

        // Every enabled entry in the file counts, not only the screenshot ones; disabled and unbound ones don't.
        let hotkeys: [String: Any] = [
            "79": entry(true, character: 51, keyCode: 20, flags: 0x180000 | 0x20000),    // ⌥⇧⌘3 on
            "80": entry(false, character: 52, keyCode: 21, flags: 0x180000 | 0x20000),   // ⌥⇧⌘4 off
            "81": entry(true, character: 65535, keyCode: 65535, flags: 0),                // nothing bound
        ]
        let all = SystemScreenshotShortcuts.allEnabled(in: hotkeys)
        #expect(all.contains(altShift(20)) && !all.contains(altShift(21)))
        #expect(all.isSuperset(of: system))
    }

    /// Use Other Keys names the actions that kept their keys in the same words after the launch notice as in Settings,
    /// where the launch notice's run used to drop them (audit finding 16).
    @Test func keptKeysAreNamedTheSameWayEverywhere() {
        #expect(SystemScreenshotShortcuts.keptKeysMessage([]) == nil)
        #expect(SystemScreenshotShortcuts.keptKeysMessage([.area]) == "Area kept its keys: another app uses the new ones.")
        #expect(SystemScreenshotShortcuts.keptKeysMessage([.area, .scrollingCapture, .screenRecording])
            == "Area, Scrolling Capture and Screen Recording kept their keys: another app uses the new ones.")
    }
}
