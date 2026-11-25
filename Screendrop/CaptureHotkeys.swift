//
//  CaptureHotkeys.swift
//  Screendrop
//

import AppKit
import Carbon.HIToolbox
import Foundation

struct HotkeyShortcut: Codable, Equatable, Hashable {
    struct Modifiers: OptionSet, Codable, Equatable, Hashable {
        let rawValue: Int

        static let command = Modifiers(rawValue: 1 << 0)
        static let option = Modifiers(rawValue: 1 << 1)
        static let control = Modifiers(rawValue: 1 << 2)
        static let shift = Modifiers(rawValue: 1 << 3)

        init(rawValue: Int) {
            self.rawValue = rawValue
        }

        init(from eventFlags: NSEvent.ModifierFlags) {
            var modifiers: Modifiers = []
            if eventFlags.contains(.command) { modifiers.insert(.command) }
            if eventFlags.contains(.option) { modifiers.insert(.option) }
            if eventFlags.contains(.control) { modifiers.insert(.control) }
            if eventFlags.contains(.shift) { modifiers.insert(.shift) }
            self = modifiers
        }

        var carbonEventModifiers: UInt32 {
            var flags: UInt32 = 0
            if contains(.command) { flags |= UInt32(cmdKey) }
            if contains(.option) { flags |= UInt32(optionKey) }
            if contains(.control) { flags |= UInt32(controlKey) }
            if contains(.shift) { flags |= UInt32(shiftKey) }
            return flags
        }

        var symbols: [String] {
            var result: [String] = []
            if contains(.control) { result.append("⌃") }
            if contains(.option) { result.append("⌥") }
            if contains(.shift) { result.append("⇧") }
            if contains(.command) { result.append("⌘") }
            return result
        }
    }

    let modifiers: Modifiers
    let keyCode: Int
    /// For a modifier key on its own, whose code `keyCode` is: 1 for a tap of that key (Right ⌥), 2 for two taps of
    /// either key of its pair (⌥ ⌥, stored as the left key). Nil for every other shortcut, and then left out of the saved
    /// JSON, so shortcuts saved before it load and save as they were.
    var taps: Int? = nil

    /// One token per keycap: "Right ⌥" and "⌥ ⌥" are one token each, so every joined form reads the same.
    var displayTokens: [String] {
        guard let taps, let key = ModifierKeys.keys[keyCode], let symbol = key.family.symbols.first else {
            return modifiers.symbols + [Self.keyLabel(for: keyCode)]
        }
        return [taps == 2 ? "\(symbol) \(symbol)" : "\(key.isRight ? "Right" : "Left") \(symbol)"]
    }

    var displayString: String {
        displayTokens.joined(separator: " ")
    }

    var isValid: Bool {
        if let taps { return modifiers.isEmpty && ModifierKeys.keys[keyCode] != nil && (taps == 1 || taps == 2) }
        return !modifiers.isEmpty || Self.functionKeyCodes.contains(keyCode)
    }

    /// Why the recorder turns these keys down, in one line; nil when they can be a shortcut. Any modifier with any key
    /// can, and so can F1 to F20 alone; another key alone would stop working in every app.
    var refusal: String? {
        guard taps == nil, modifiers.isEmpty, !Self.functionKeyCodes.contains(keyCode) else { return nil }
        return "\(Self.keyLabel(for: keyCode)) on its own would stop working in every app. Add ⌘, ⌥, ⌃ or ⇧, or use F1 to F20."
    }

    /// With ⌥ or ⇧ but neither ⌘ nor ⌃, the keys also type or edit in text fields, and while they're Sukusho's no app
    /// gets them. They're allowed (the owner wants the choice, 2026-11-17), with this warning.
    var typingWarning: String? {
        guard taps == nil, !modifiers.isEmpty, modifiers.isDisjoint(with: [.command, .control]),
              !Self.functionKeyCodes.contains(keyCode) else { return nil }
        return Self.editingKeyCodes.contains(keyCode)
            ? "\(displayString) also works in text fields. While it’s Sukusho’s shortcut, no app gets it."
            : "\(displayString) also types a character. While it’s Sukusho’s shortcut, you can’t type it."
    }

    /// A menu item's title with a shortcut its shortcut column can't show (a modifier key on its own, a function key
    /// alone) after it, as "Capture Area (Right ⌥)". A title reads the same in every menu on every macOS; SwiftUI drops a
    /// subtitle given inside a Label (checked on macOS 27.3).
    /// What Settings' recorder takes from a key going down: the keys to record (or refuse), or nil for a repeat. A
    /// repeat is a key held on, often since before recording started, so it only counts as held and never makes a
    /// chord: E held from before recording, then a Right ⌥ tap, recorded ⌥E (VM, keys-vm4 F2).
    static func recording(keyCode: Int, flags: NSEvent.ModifierFlags, isRepeat: Bool) -> HotkeyShortcut? {
        isRepeat ? nil : HotkeyShortcut(modifiers: Modifiers(from: flags), keyCode: keyCode)
    }

    /// Whether a menu can take these keys as its own shortcut: a key with a modifier, not a modifier key alone and not a
    /// function key, which `MenuBarView.shortcut(for:)` can't hand a menu. The palette's shortcut inside Sukusho is one.
    var isMenuShortcut: Bool {
        guard taps == nil, !modifiers.isEmpty else { return false }
        let label = Self.keyLabel(for: keyCode)
        return label.count == 1 || label == "Space"
    }

    static func menuTitle(_ title: String, adding shortcut: HotkeyShortcut?) -> String {
        shortcut.map { "\(title) (\($0.displayString))" } ?? title
    }

    /// Whether one press would set off both: the same shortcut, or a tap and a double tap of one pair (Right ⌥ and ⌥ ⌥),
    /// since every double tap starts with a tap.
    func overlaps(_ other: HotkeyShortcut) -> Bool {
        if self == other { return true }
        guard let taps, let otherTaps = other.taps, taps == 2 || otherTaps == 2,
              let family = ModifierKeys.keys[keyCode]?.family else { return false }
        return ModifierKeys.keys[other.keyCode]?.family == family
    }

    /// F1 to F20, the keys that can be a shortcut on their own.
    static let functionKeyCodes: Set<Int> = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]

    /// Keys that move, select or delete in text fields rather than type a character.
    private static let editingKeyCodes: Set<Int> = [
        kVK_Return, kVK_ANSI_KeypadEnter, kVK_Tab, kVK_Delete, kVK_ForwardDelete, kVK_Escape,
        kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow, kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown, kVK_Help,
    ]

    private static func keyLabel(for keyCode: Int) -> String {
        switch keyCode {
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Space: return "Space"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_Escape: return "⎋"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        case kVK_F13: return "F13"
        case kVK_F14: return "F14"
        case kVK_F15: return "F15"
        case kVK_F16: return "F16"
        case kVK_F17: return "F17"
        case kVK_F18: return "F18"
        case kVK_F19: return "F19"
        case kVK_F20: return "F20"
        default:
            return ansiKeyLabel(for: keyCode) ?? "Key \(keyCode)"
        }
    }

    private static func ansiKeyLabel(for keyCode: Int) -> String? {
        switch keyCode {
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_ANSI_Minus: return "-"
        case kVK_ANSI_Equal: return "="
        case kVK_ANSI_LeftBracket: return "["
        case kVK_ANSI_RightBracket: return "]"
        case kVK_ANSI_Backslash: return "\\"
        case kVK_ANSI_Semicolon: return ";"
        case kVK_ANSI_Quote: return "'"
        case kVK_ANSI_Comma: return ","
        case kVK_ANSI_Period: return "."
        case kVK_ANSI_Slash: return "/"
        case kVK_ANSI_Grave: return "`"
        default: return nil
        }
    }
}

enum CaptureHotkeyAction: String, CaseIterable, Identifiable {
    case fullscreen
    case window
    case area
    case screenRecording
    case drawing
    case textCapture
    case scrollingCapture
    /// Not a capture: brings the Library forward from any app.
    case library
    /// Not a capture: the clipboard history popup, registered only while history is on.
    case clipboardHistory
    /// Not a capture: the command palette, inside Sukusho's own windows only. Recorded and checked for clashes as the
    /// others are, but a menu's shortcut (View › Command Palette…), never registered with macOS for every app (`isGlobal`).
    case commandPalette

    var id: Self { self }

    /// Registered system-wide by `HotkeyManager`. The rest are menu shortcuts, which work while Sukusho is in front.
    var isGlobal: Bool { self != .commandPalette }

    var hotKeyID: UInt32 {
        switch self {
        case .fullscreen: 1
        case .window: 2
        case .area: 3
        case .screenRecording: 4
        case .textCapture: 5
        case .scrollingCapture: 6
        case .library: 7
        case .drawing: 9
        case .clipboardHistory: 8
        case .commandPalette: 10
        }
    }

    /// Shown as Beta wherever it's named: Scrolling Capture ships as Beta in 1.3.0 (the owner, 2026-11-19).
    var isBeta: Bool { self == .scrollingCapture }

    var title: String {
        switch self {
        case .fullscreen: "Fullscreen"
        case .window: "Window"
        case .area: "Area"
        case .screenRecording: "Screen Recording"
        case .drawing: "Drawing while recording"
        case .textCapture: "Capture Text"
        case .scrollingCapture: "Scrolling Capture"
        case .library: "Show Library"
        case .clipboardHistory: "Clipboard History"
        case .commandPalette: "Command Palette"
        }
    }

    /// The owner's own set (2026-11-17, beta 1): ⇧⌘1 Fullscreen, ⇧⌘2 Window, ⇧⌘3 Area, ⇧⌘4 Scrolling, ⇧⌘5 Recording,
    /// ⇧⌘O Capture Text, ⇧⌘L Library, ⌃⌘V Clipboard History. ⇧⌘3, ⇧⌘4 and ⇧⌘5 are also macOS's screenshot shortcuts
    /// (Settings and a notice say so). Only actions the user never recorded follow a default, so recorded shortcuts stay.
    var defaultShortcut: HotkeyShortcut {
        switch self {
        case .fullscreen:
            HotkeyShortcut(modifiers: [.command, .shift], keyCode: Int(kVK_ANSI_1))
        case .window:
            HotkeyShortcut(modifiers: [.command, .shift], keyCode: Int(kVK_ANSI_2))
        case .area:
            HotkeyShortcut(modifiers: [.command, .shift], keyCode: Int(kVK_ANSI_3))
        case .screenRecording:
            HotkeyShortcut(modifiers: [.command, .shift], keyCode: Int(kVK_ANSI_5))
        case .drawing:
            HotkeyShortcut(modifiers: [.control, .shift], keyCode: Int(kVK_ANSI_M))
        case .textCapture:
            HotkeyShortcut(modifiers: [.command, .shift], keyCode: Int(kVK_ANSI_O))
        case .scrollingCapture:
            HotkeyShortcut(modifiers: [.command, .shift], keyCode: Int(kVK_ANSI_4))
        case .library:
            HotkeyShortcut(modifiers: [.command, .shift], keyCode: Int(kVK_ANSI_L))
        case .clipboardHistory:
            // ⌃⌘V (owner, 2026-11-16): ⌥⌘V is Finder's move-here and Paste Style, ⇧⌘V Sublime's Paste and Indent.
            HotkeyShortcut(modifiers: [.control, .command], keyCode: Int(kVK_ANSI_V))
        case .commandPalette:
            // ⇧⌘P, as Hashbrown's and the code editors' palettes; free in Sukusho (sd-458l).
            HotkeyShortcut(modifiers: [.shift, .command], keyCode: Int(kVK_ANSI_P))
        }
    }

    /// The defaults before beta 1, where they differ: Recording ⇧⌘6, Capture Text ⇧⌘5. A stored shortcut that equals one
    /// was stored by an older build, not chosen, so it is forgotten and follows the new default (`dropStoredDefaults`).
    var previousDefaultShortcut: HotkeyShortcut? {
        switch self {
        case .screenRecording: HotkeyShortcut(modifiers: [.command, .shift], keyCode: Int(kVK_ANSI_6))
        case .textCapture: HotkeyShortcut(modifiers: [.command, .shift], keyCode: Int(kVK_ANSI_5))
        default: nil
        }
    }

    /// Settings › Shortcuts' rows: 1 to 5, then O, L and V (the owner, 2026-11-17), then the palette's P.
    static let settingsOrder: [CaptureHotkeyAction] = [
        .fullscreen, .window, .area, .scrollingCapture, .screenRecording, .drawing, .textCapture, .library, .clipboardHistory,
        .commandPalette,
    ]

    var preferencesKey: String {
        switch self {
        case .fullscreen:
            ScreendropPreferences.fullscreenHotkeyKey
        case .window:
            ScreendropPreferences.windowHotkeyKey
        case .area:
            ScreendropPreferences.areaHotkeyKey
        case .screenRecording:
            ScreendropPreferences.screenRecordingHotkeyKey
        case .drawing:
            "recordingDrawingHotkey"
        case .textCapture:
            ScreendropPreferences.textCaptureHotkeyKey
        case .scrollingCapture:
            ScreendropPreferences.scrollingCaptureHotkeyKey
        case .library:
            ScreendropPreferences.libraryHotkeyKey
        case .clipboardHistory:
            ScreendropPreferences.clipboardHistoryHotkeyKey
        case .commandPalette:
            "captureHotkey.commandPalette"
        }
    }
}

enum CaptureHotkeyPreferences {
    /// Stored for an action the user cleared, so it has no shortcut at all.
    private static let clearedValue = "none"

    /// A shortcut with no modifier (a modifier key on its own, a function key alone) is kept here, with the action's own
    /// key saying cleared. Beta 1 can't read one: in its own key it would fall back to the default, which beta 1's launch
    /// cleanup then forgets, so a trip to beta 1 lost it (Sol's review). Here beta 1 never looks, and shows the row as
    /// None. It counts only while the own key still says cleared: when beta 1 records, resets or restores that row, what
    /// beta 1 saved wins.
    private static func noModifiersKey(_ action: CaptureHotkeyAction) -> String { action.preferencesKey + ".noModifiers" }

    private static func noModifiersShortcut(for action: CaptureHotkeyAction, defaults: UserDefaults) -> HotkeyShortcut? {
        guard defaults.string(forKey: action.preferencesKey) == clearedValue,
              let data = defaults.data(forKey: noModifiersKey(action)),
              let shortcut = try? JSONDecoder().decode(HotkeyShortcut.self, from: data),
              shortcut.isValid, shortcut.modifiers.isEmpty
        else { return nil }
        return shortcut
    }

    /// The action's shortcut: recorded, else the default; nil once cleared, or while its default is another action's
    /// (`defaultTakenBy`).
    static func shortcut(for action: CaptureHotkeyAction, defaults: UserDefaults = .standard) -> HotkeyShortcut? {
        if let shortcut = noModifiersShortcut(for: action, defaults: defaults) { return shortcut }
        if defaults.string(forKey: action.preferencesKey) == clearedValue { return nil }
        guard
            let data = defaults.data(forKey: action.preferencesKey),
            let shortcut = try? JSONDecoder().decode(HotkeyShortcut.self, from: data),
            shortcut.isValid
        else {
            return defaultTakenBy(action, defaults: defaults) == nil ? action.defaultShortcut : nil
        }

        return shortcut
    }

    /// The action another row's recorded keys took the palette's default from: a Capture Fullscreen recorded as ⇧⌘P
    /// before the palette came keeps it, and the palette has no keys until some are recorded for it (Sol, sd-458l). Only
    /// the palette's default yields; the other rows' stay as they were.
    static func defaultTakenBy(_ action: CaptureHotkeyAction, defaults: UserDefaults = .standard) -> CaptureHotkeyAction? {
        guard action == .commandPalette, defaults.object(forKey: action.preferencesKey) == nil else { return nil }
        return CaptureHotkeyAction.allCases.first { other in
            guard other != action else { return false }
            let recorded = noModifiersShortcut(for: other, defaults: defaults) ?? defaults.data(forKey: other.preferencesKey)
                .flatMap { try? JSONDecoder().decode(HotkeyShortcut.self, from: $0) }
            return recorded?.overlaps(action.defaultShortcut) == true
        }
    }

    /// Sukusho's own menu and window keys, which a shortcut that works only inside Sukusho would fight: ⌘S is File ›
    /// Save and the editor's own key, ⌘B Studio's Split at Playhead (Sol, sd-458l). The palette's row refuses them.
    static let appCommands: [(shortcut: HotkeyShortcut, name: String)] = {
        func keys(_ modifiers: HotkeyShortcut.Modifiers, _ key: Int, _ name: String) -> (HotkeyShortcut, String) {
            (HotkeyShortcut(modifiers: modifiers, keyCode: key), name)
        }
        return [
            keys(.command, kVK_ANSI_S, "Save"), keys([.command, .shift], kVK_ANSI_S, "Save As…"),
            keys(.command, kVK_ANSI_Z, "Undo"), keys([.command, .shift], kVK_ANSI_Z, "Redo"),
            keys(.command, kVK_ANSI_X, "Cut"), keys(.command, kVK_ANSI_C, "Copy"), keys([.command, .shift], kVK_ANSI_C, "Copy Original"),
            keys(.command, kVK_ANSI_V, "Paste"), keys(.command, kVK_ANSI_A, "Select All"),
            keys(.command, kVK_ANSI_F, "Find"), keys(.command, kVK_ANSI_R, "Refresh"), keys(.command, kVK_ANSI_B, "Split at Playhead"),
            keys(.command, kVK_ANSI_Equal, "Zoom In"), keys(.command, kVK_ANSI_Minus, "Zoom Out"),
            keys([.command, .shift], kVK_ANSI_Equal, "Zoom In"), keys(.command, kVK_ANSI_0, "Actual Size"),
            keys(.command, kVK_ANSI_1, "Zoom to Fit"), keys([.command, .option], kVK_ANSI_Equal, "Bigger Text"),
            keys([.command, .option], kVK_ANSI_Minus, "Smaller Text"), keys([.command, .option], kVK_ANSI_I, "Show Inspector"),
            keys([.command, .control], kVK_ANSI_S, "Show Sidebar"), keys(.option, kVK_ANSI_X, "Clear Marked Range"),
            keys(.command, kVK_ANSI_Comma, "Settings…"), keys(.command, kVK_ANSI_Q, "Quit Sukusho"),
            keys(.command, kVK_ANSI_H, "Hide Sukusho"), keys([.command, .option], kVK_ANSI_H, "Hide Others"),
            keys(.command, kVK_ANSI_W, "Close"), keys(.command, kVK_ANSI_M, "Minimize"),
            keys([.command, .control], kVK_ANSI_F, "Enter Full Screen"), keys(.command, kVK_Delete, "Move to Trash"),
            keys([.command, .shift], kVK_ANSI_Minus, "Zoom Out"),
            // The palette's own ⌘Y, and Studio's one-second steps (Sol's second review).
            keys(.command, kVK_ANSI_Y, "Quick Look"),
            keys(.shift, kVK_LeftArrow, "Back One Second"), keys(.shift, kVK_RightArrow, "Forward One Second"),
        ]
    }()

    /// The Sukusho command already on these keys.
    static func appCommand(using shortcut: HotkeyShortcut) -> String? {
        appCommands.first { $0.shortcut == shortcut }?.name
    }

    /// Nil clears the action. Its default is never stored, so changing a
    /// default reaches everyone who didn't record their own.
    static func saveShortcut(
        _ shortcut: HotkeyShortcut?,
        for action: CaptureHotkeyAction,
        defaults: UserDefaults = .standard
    ) {
        defaults.removeObject(forKey: noModifiersKey(action))
        guard let shortcut else {
            defaults.set(clearedValue, forKey: action.preferencesKey)
            return
        }
        guard shortcut != action.defaultShortcut else {
            defaults.removeObject(forKey: action.preferencesKey)
            return
        }

        guard let data = try? JSONEncoder().encode(shortcut) else { return }
        if shortcut.modifiers.isEmpty {
            defaults.set(data, forKey: noModifiersKey(action))
            defaults.set(clearedValue, forKey: action.preferencesKey)
        } else {
            defaults.set(data, forKey: action.preferencesKey)
        }
    }

    /// Forgets what the user recorded or cleared, so the default applies.
    static func resetToDefault(_ action: CaptureHotkeyAction, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: action.preferencesKey)
        defaults.removeObject(forKey: noModifiersKey(action))
    }

    /// Whether the action has its default shortcut: nothing stored, or a stored shortcut that equals the default. An
    /// older build stored defaults too, so Reset showed on rows it couldn't change (owner, 2026-11-17). A cleared
    /// shortcut isn't the default.
    static func isDefault(_ action: CaptureHotkeyAction, defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: action.preferencesKey) != nil else { return true }
        guard defaults.string(forKey: action.preferencesKey) != clearedValue else { return false }
        return shortcut(for: action, defaults: defaults) == action.defaultShortcut
    }

    /// Forgets stored shortcuts that equal their action's default, or its default before beta 1, so a change of a
    /// default reaches them, as it does everyone who never recorded one: an older build stored defaults, and without this
    /// a stored old ⇧⌘5 for Capture Text would collide with Recording's new ⇧⌘5. Cleared and changed shortcuts stay.
    /// Run at launch. It also moves a shortcut with no modifier that an earlier build of this one kept in the action's
    /// own key to where beta 1 can't lose it, and forgets one that beta 1 has since replaced.
    static func dropStoredDefaults(defaults: UserDefaults = .standard) {
        for action in CaptureHotkeyAction.allCases {
            if noModifiersShortcut(for: action, defaults: defaults) == nil {
                defaults.removeObject(forKey: noModifiersKey(action))
            }
            if let data = defaults.data(forKey: action.preferencesKey),
               let stored = try? JSONDecoder().decode(HotkeyShortcut.self, from: data), stored.isValid, stored.modifiers.isEmpty {
                saveShortcut(stored, for: action, defaults: defaults)
            }
        }
        for action in CaptureHotkeyAction.allCases where defaults.data(forKey: action.preferencesKey) != nil {
            let stored = shortcut(for: action, defaults: defaults)
            if isDefault(action, defaults: defaults) || (stored != nil && stored == action.previousDefaultShortcut) {
                defaults.removeObject(forKey: action.preferencesKey)
            }
        }
    }

    /// Every action that has a shortcut; cleared ones are left out.
    static func shortcuts(
        for actions: [CaptureHotkeyAction] = CaptureHotkeyAction.allCases,
        defaults: UserDefaults = .standard
    ) -> [CaptureHotkeyAction: HotkeyShortcut] {
        actions.reduce(into: [:]) { result, action in
            result[action] = shortcut(for: action, defaults: defaults)
        }
    }

    static func conflictingAction(
        for shortcut: HotkeyShortcut,
        excluding action: CaptureHotkeyAction,
        defaults: UserDefaults = .standard
    ) -> CaptureHotkeyAction? {
        CaptureHotkeyAction.allCases.first { candidate in
            candidate != action && self.shortcut(for: candidate, defaults: defaults)?.overlaps(shortcut) == true
        }
    }
}

/// macOS's own screenshot shortcuts, which one press shares with any Sukusho shortcut on the same keys: both start, and
/// for ⇧⌘5 macOS's toolbar wins (sd-7l2f). macOS keeps them in com.apple.symbolichotkeys › AppleSymbolicHotKeys, each
/// under its number with `enabled` and `value.parameters` = [character, key code, modifier flags] (read on a Mac and in
/// the VM, 2026-11-17).
enum SystemScreenshotShortcuts {
    static let domain = "com.apple.symbolichotkeys"
    static let key = "AppleSymbolicHotKeys"

    /// The screenshot entries, with the keys macOS gives them: an entry that isn't in the file was never changed, so it
    /// is on with these keys.
    static let defaults: [Int: HotkeyShortcut] = [
        28: HotkeyShortcut(modifiers: [.shift, .command], keyCode: 20),             // ⇧⌘3
        29: HotkeyShortcut(modifiers: [.control, .shift, .command], keyCode: 20),   // ⌃⇧⌘3
        30: HotkeyShortcut(modifiers: [.shift, .command], keyCode: 21),             // ⇧⌘4
        31: HotkeyShortcut(modifiers: [.control, .shift, .command], keyCode: 21),   // ⌃⇧⌘4
        184: HotkeyShortcut(modifiers: [.shift, .command], keyCode: 23),            // ⇧⌘5
    ]

    /// The screenshot shortcuts macOS has on, by entry number, from its AppleSymbolicHotKeys dictionary.
    static func enabledEntries(in hotkeys: [String: Any]?) -> [Int: HotkeyShortcut] {
        defaults.reduce(into: [:]) { result, item in
            let (id, fallback) = item
            guard let entry = hotkeys?[String(id)] as? [String: Any] else { result[id] = fallback; return }
            guard (entry["enabled"] as? Bool) ?? (entry["enabled"] as? NSNumber)?.boolValue ?? true else { return }
            let parameters = (entry["value"] as? [String: Any])?["parameters"] as? [NSNumber]
            guard let parameters, parameters.count >= 3 else { result[id] = fallback; return }
            let flags = NSEvent.ModifierFlags(rawValue: parameters[2].uintValue)
            result[id] = HotkeyShortcut(modifiers: HotkeyShortcut.Modifiers(from: flags), keyCode: parameters[1].intValue)
        }
    }

    /// The screenshot shortcuts macOS has on, from its AppleSymbolicHotKeys dictionary.
    static func enabled(in hotkeys: [String: Any]?) -> Set<HotkeyShortcut> {
        Set(enabledEntries(in: hotkeys).values)
    }

    /// Sukusho's actions whose shortcut macOS also uses, in Settings' order.
    static func clashes(_ shortcuts: [CaptureHotkeyAction: HotkeyShortcut], with system: Set<HotkeyShortcut>) -> [CaptureHotkeyAction] {
        CaptureHotkeyAction.settingsOrder.filter { shortcuts[$0].map(system.contains) ?? false }
    }

    /// The macOS entry that also uses `shortcut`, if one does; the lowest number when two share it.
    static func entry(for shortcut: HotkeyShortcut, in entries: [Int: HotkeyShortcut]) -> Int? {
        entries.filter { $0.value == shortcut }.keys.min()
    }

    /// macOS's settings as they are now: synchronized first, so a shortcut just turned off in System Settings counts.
    static func currentEntries() -> [Int: HotkeyShortcut] {
        CFPreferencesAppSynchronize(domain as CFString)
        return enabledEntries(in: CFPreferencesCopyAppValue(key as CFString, domain as CFString) as? [String: Any])
    }

    /// Sukusho's shortcuts that macOS also uses now.
    static func currentClashes() -> [CaptureHotkeyAction] {
        clashes(CaptureHotkeyPreferences.shortcuts(), with: Set(currentEntries().values))
    }

    typealias Clash = (action: CaptureHotkeyAction, shortcut: HotkeyShortcut)

    /// "⇧⌘3, ⇧⌘4 and ⇧⌘5": the wording agreed with the owner has no comma before "and".
    private static func list(_ items: [String]) -> String {
        items.count < 2 ? items.joined() : items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
    }

    private static func inKeyOrder(_ clashes: [Clash]) -> [Clash] {
        clashes.sorted { ($0.shortcut.keyCode, $0.shortcut.modifiers.rawValue) < ($1.shortcut.keyCode, $1.shortcut.modifiers.rawValue) }
    }

    /// The warning, the same in Settings and the launch notice, in the words agreed with the owner (2026-11-17): the keys
    /// that clash, in key order, and the two ways out. Without free keys to move to, the first way is picking keys here.
    static func warning(_ clashes: [Clash], canUseOtherKeys: Bool) -> String {
        let keys = list(inKeyOrder(clashes).map { $0.shortcut.displayTokens.joined() })
        let one = clashes.count == 1
        let what = one ? "\(keys) is also one of macOS’s screenshot shortcuts." : "\(keys) are also macOS’s screenshot shortcuts."
        let ours = canUseOtherKeys ? (one ? "Give Sukusho another key (you can change it)" : "Give Sukusho other keys (you can change them)")
            : (one ? "Pick another key for Sukusho" : "Pick other keys for Sukusho")
        return "\(what) \(ours), or turn macOS’s off in Keyboard Shortcuts › Screenshots."
    }

    /// Names the actions Use Other Keys left on their keys, the same after the launch notice as in Settings.
    static func keptKeysMessage(_ kept: [CaptureHotkeyAction]) -> String? {
        guard !kept.isEmpty else { return nil }
        return "\(list(kept.map(\.title))) kept \(kept.count == 1 ? "its" : "their") keys: another app uses the new ones."
    }

    /// Under and on every Open Keyboard Shortcuts… button (the owner, 2026-11-17): the link lands on the sheet's Modifier
    /// Keys section on macOS 26.5.1 and 27.2.1, one click from Screenshots.
    static let keyboardShortcutsHint = "Opens Keyboard Shortcuts; choose Screenshots on the left"

    /// Opens System Settings at Keyboard › Keyboard Shortcuts…, the nearest a link reaches: `Shortcuts` is the anchor
    /// System Settings' own search uses for "App and system keyboard shortcuts" (Keyboard.searchTerms on macOS 26.5.1
    /// and 27.3, read 2026-11-17); no anchor selects Screenshots in it, one click from there.
    @MainActor static func openKeyboardSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Shortcuts") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Dictation

    /// macOS Dictation's shortcut when it is a modifier key pressed twice (System Settings › Keyboard › Dictation ›
    /// Shortcut, such as Press Control Key Twice): entry 164 with type `modifier`, whose parameters hold that key's flags
    /// (262144, ⌃, on a fresh macOS 27.2.1 in the VM, 2026-11-18). One Sukusho double tap of that pair starts Dictation
    /// too (seen there). Nil when it's off, fn, or another kind of shortcut.
    static func dictationDoubleTap(in hotkeys: [String: Any]?) -> HotkeyShortcut? {
        guard let entry = hotkeys?["164"] as? [String: Any],
              (entry["enabled"] as? Bool) ?? (entry["enabled"] as? NSNumber)?.boolValue ?? false,
              let value = entry["value"] as? [String: Any], value["type"] as? String == "modifier",
              let flags = (value["parameters"] as? [NSNumber])?.map(\.uintValue).first(where: { $0 & 0xFFFF_0000 != 0 }),
              flags & NSEvent.ModifierFlags.function.rawValue == 0,
              let left = ModifierKeys.leftKeyCode(of: HotkeyShortcut.Modifiers(from: NSEvent.ModifierFlags(rawValue: flags)))
        else { return nil }
        return HotkeyShortcut(.twice(keyCode: left))
    }

    static func currentDictationDoubleTap() -> HotkeyShortcut? {
        CFPreferencesAppSynchronize(domain as CFString)
        return dictationDoubleTap(in: CFPreferencesCopyAppValue(key as CFString, domain as CFString) as? [String: Any])
    }

    /// Under a row whose double tap is Dictation's shortcut too. The path is Apple's (Use Dictation on Mac, macOS 27).
    static func dictationWarning(_ shortcut: HotkeyShortcut) -> String {
        "\(shortcut.displayString) also starts macOS Dictation. Pick another shortcut, or change Dictation’s in System Settings › Keyboard › Dictation."
    }

    // MARK: - Use Other Keys

    /// Every shortcut macOS has on in AppleSymbolicHotKeys, not only the screenshot ones; an entry never changed isn't in
    /// the file, so macOS's other defaults are covered by the choice of candidates (`candidates`).
    static func allEnabled(in hotkeys: [String: Any]?) -> Set<HotkeyShortcut> {
        var result = enabled(in: hotkeys)
        for case let entry as [String: Any] in (hotkeys ?? [:]).values {
            guard (entry["enabled"] as? Bool) ?? (entry["enabled"] as? NSNumber)?.boolValue ?? false,
                  let parameters = (entry["value"] as? [String: Any])?["parameters"] as? [NSNumber], parameters.count >= 3,
                  parameters[1].intValue != 0xFFFF else { continue }
            let flags = NSEvent.ModifierFlags(rawValue: parameters[2].uintValue)
            result.insert(HotkeyShortcut(modifiers: HotkeyShortcut.Modifiers(from: flags), keyCode: parameters[1].intValue))
        }
        return result
    }

    static func currentAllEnabled() -> Set<HotkeyShortcut> {
        CFPreferencesAppSynchronize(domain as CFString)
        return allEnabled(in: CFPreferencesCopyAppValue(key as CFString, domain as CFString) as? [String: Any])
    }

    /// The keys tried for a clashing shortcut, in order: the same key with ⌥⇧⌘, then ⌃⌥⌘. Neither is on Apple's list of
    /// Mac shortcuts for 3, 4 or 5 (support.apple.com/102650, read 2026-11-17: ⌃⌥⌘ only 8, comma and period), and the
    /// same digit keeps each action on its number. ⌃⇧⌘3 and ⌃⇧⌘4 are macOS's own copy-to-clipboard screenshots.
    /// Only those verified digits get candidates (Sol, R9-1): a screenshot shortcut remapped to another key, such as ⇧⌘Q,
    /// would otherwise offer ⌥⇧⌘Q, Apple's immediate log-out. Any other key is left for the user to change by hand,
    /// with the warning still shown.
    static func candidates(for shortcut: HotkeyShortcut) -> [HotkeyShortcut] {
        guard verifiedKeyCodes.contains(shortcut.keyCode) else { return [] }
        return [HotkeyShortcut(modifiers: [.option, .shift, .command], keyCode: shortcut.keyCode),
                HotkeyShortcut(modifiers: [.control, .option, .command], keyCode: shortcut.keyCode)]
    }

    /// 3, 4 and 5: the digits checked against Apple's list for both families.
    static let verifiedKeyCodes: Set<Int> = [Int(kVK_ANSI_3), Int(kVK_ANSI_4), Int(kVK_ANSI_5)]

    /// New keys for the clashing actions: the first candidate macOS doesn't have on and no other Sukusho action uses,
    /// counting the keys already chosen here. An action with no free candidate is left out.
    static func otherKeys(for clashing: [CaptureHotkeyAction], shortcuts: [CaptureHotkeyAction: HotkeyShortcut],
                          system: Set<HotkeyShortcut>) -> [CaptureHotkeyAction: HotkeyShortcut] {
        var taken = Set(shortcuts.filter { !clashing.contains($0.key) }.values)
        var result: [CaptureHotkeyAction: HotkeyShortcut] = [:]
        for action in clashing {
            guard let shortcut = shortcuts[action],
                  let free = candidates(for: shortcut).first(where: { !system.contains($0) && !taken.contains($0) }) else { continue }
            result[action] = free
            taken.insert(free)
        }
        return result
    }
}
