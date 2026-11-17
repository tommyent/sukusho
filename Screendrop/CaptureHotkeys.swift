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

    var displayTokens: [String] {
        modifiers.symbols + [Self.keyLabel(for: keyCode)]
    }

    var displayString: String {
        displayTokens.joined(separator: " ")
    }

    var isValid: Bool {
        !modifiers.isEmpty
    }

    /// New shortcuts need ⌘ or ⌃. With ⌥ or ⇧ alone the chord types a
    /// character, so as a global hotkey it would take that character away
    /// from every app. Shortcuts recorded before this rule are kept.
    var hasCommandOrControl: Bool {
        !modifiers.isDisjoint(with: [.command, .control])
    }

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
    case textCapture
    case scrollingCapture
    /// Not a capture: brings the Library forward from any app.
    case library
    /// Not a capture: the clipboard history popup, registered only while history is on.
    case clipboardHistory

    var id: Self { self }

    var hotKeyID: UInt32 {
        switch self {
        case .fullscreen: 1
        case .window: 2
        case .area: 3
        case .screenRecording: 4
        case .textCapture: 5
        case .scrollingCapture: 6
        case .library: 7
        case .clipboardHistory: 8
        }
    }

    var title: String {
        switch self {
        case .fullscreen: "Fullscreen"
        case .window: "Window"
        case .area: "Area"
        case .screenRecording: "Screen Recording"
        case .textCapture: "Capture Text"
        case .scrollingCapture: "Scrolling Capture"
        case .library: "Show Library"
        case .clipboardHistory: "Clipboard History"
        }
    }

    /// ⌘⇧ chords picked by the user (2026-10-19): 1 Fullscreen, 2 Window,
    /// 3 Area, 4 Scrolling, 5 Text and 6 Recording. ⌘⇧3, ⌘⇧4 and ⌘⇧5 are also
    /// macOS's screenshot shortcuts, which must be off for them to register.
    /// Only actions the user never recorded follow a default, so recorded
    /// shortcuts stay.
    var defaultShortcut: HotkeyShortcut {
        switch self {
        case .fullscreen:
            HotkeyShortcut(modifiers: [.command, .shift], keyCode: Int(kVK_ANSI_1))
        case .window:
            HotkeyShortcut(modifiers: [.command, .shift], keyCode: Int(kVK_ANSI_2))
        case .area:
            HotkeyShortcut(modifiers: [.command, .shift], keyCode: Int(kVK_ANSI_3))
        case .screenRecording:
            HotkeyShortcut(modifiers: [.command, .shift], keyCode: Int(kVK_ANSI_6))
        case .textCapture:
            HotkeyShortcut(modifiers: [.command, .shift], keyCode: Int(kVK_ANSI_5))
        case .scrollingCapture:
            HotkeyShortcut(modifiers: [.command, .shift], keyCode: Int(kVK_ANSI_4))
        case .library:
            HotkeyShortcut(modifiers: [.command, .shift], keyCode: Int(kVK_ANSI_L))
        case .clipboardHistory:
            // ⌃⌘V (owner, 2026-11-16): ⌥⌘V is Finder's move-here and Paste Style, ⇧⌘V Sublime's Paste and Indent.
            HotkeyShortcut(modifiers: [.control, .command], keyCode: Int(kVK_ANSI_V))
        }
    }

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
        case .textCapture:
            ScreendropPreferences.textCaptureHotkeyKey
        case .scrollingCapture:
            ScreendropPreferences.scrollingCaptureHotkeyKey
        case .library:
            ScreendropPreferences.libraryHotkeyKey
        case .clipboardHistory:
            ScreendropPreferences.clipboardHistoryHotkeyKey
        }
    }

    init?(hotKeyID: UInt32) {
        guard let action = Self.allCases.first(where: { $0.hotKeyID == hotKeyID }) else {
            return nil
        }

        self = action
    }
}

enum CaptureHotkeyPreferences {
    /// Stored for an action the user cleared, so it has no shortcut at all.
    private static let clearedValue = "none"

    /// The action's shortcut: recorded, else the default; nil once cleared.
    static func shortcut(for action: CaptureHotkeyAction, defaults: UserDefaults = .standard) -> HotkeyShortcut? {
        if defaults.string(forKey: action.preferencesKey) == clearedValue { return nil }
        guard
            let data = defaults.data(forKey: action.preferencesKey),
            let shortcut = try? JSONDecoder().decode(HotkeyShortcut.self, from: data),
            shortcut.isValid
        else {
            return action.defaultShortcut
        }

        return shortcut
    }

    /// Nil clears the action. Its default is never stored, so changing a
    /// default reaches everyone who didn't record their own.
    static func saveShortcut(
        _ shortcut: HotkeyShortcut?,
        for action: CaptureHotkeyAction,
        defaults: UserDefaults = .standard
    ) {
        guard let shortcut else {
            defaults.set(clearedValue, forKey: action.preferencesKey)
            return
        }
        guard shortcut != action.defaultShortcut else {
            defaults.removeObject(forKey: action.preferencesKey)
            return
        }

        guard let data = try? JSONEncoder().encode(shortcut) else { return }
        defaults.set(data, forKey: action.preferencesKey)
    }

    /// Forgets what the user recorded or cleared, so the default applies.
    static func resetToDefault(_ action: CaptureHotkeyAction, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: action.preferencesKey)
    }

    /// Whether the action has its default shortcut: nothing stored, or a stored shortcut that equals the default. An
    /// older build stored defaults too, so Reset showed on rows it couldn't change (owner, 2026-11-17). A cleared
    /// shortcut isn't the default.
    static func isDefault(_ action: CaptureHotkeyAction, defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: action.preferencesKey) != nil else { return true }
        guard defaults.string(forKey: action.preferencesKey) != clearedValue else { return false }
        return shortcut(for: action, defaults: defaults) == action.defaultShortcut
    }

    /// Forgets stored shortcuts that equal their action's default, so a later change of a default reaches them, as it
    /// does everyone who never recorded one. Cleared and changed shortcuts stay. Run at launch.
    static func dropStoredDefaults(defaults: UserDefaults = .standard) {
        for action in CaptureHotkeyAction.allCases where defaults.data(forKey: action.preferencesKey) != nil
            && isDefault(action, defaults: defaults) {
            defaults.removeObject(forKey: action.preferencesKey)
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
            candidate != action && self.shortcut(for: candidate, defaults: defaults) == shortcut
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

    /// What one press does when a Sukusho shortcut is also one of macOS's.
    enum Outcome: Equatable {
        /// macOS does its screenshot and Sukusho does its action as well.
        case both
        /// Only macOS's runs: every one of macOS's screenshot shortcuts starts its Screenshot UI, and Sukusho's area
        /// picker closes when that UI starts (sd-7l2f).
        case macOSOnly
    }

    /// By Sukusho's action, since all five of macOS's start the same Screenshot UI. Area, Capture Text and Scrolling
    /// Capture open Sukusho's picker at once, so they don't run: seen for ⇧⌘3, ⇧⌘4 and ⇧⌘5 in the VM (27.2.1). Any
    /// other action has no picker to close, so it runs as well (inferred, not seen).
    static func outcome(for action: CaptureHotkeyAction) -> Outcome {
        switch action {
        case .area, .textCapture, .scrollingCapture: .macOSOnly
        default: .both
        }
    }

    /// What macOS does on its entry's keys, for the sentence that says so.
    static func macOSDoes(_ entry: Int) -> String {
        switch entry {
        case 28, 29: "takes its own screenshot"
        case 30, 31: "starts its own area screenshot"
        default: "opens its Screenshot toolbar"
        }
    }

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
        CaptureHotkeyAction.allCases.filter { shortcuts[$0].map(system.contains) ?? false }
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

    /// Where the user turns macOS's screenshot shortcuts off, as System Settings names it (checked on screen in the VM).
    static let settingsPath = "Keyboard › Keyboard Shortcuts… › Screenshots"

    /// Opens System Settings at its Keyboard pane, the nearest place a link reaches (checked in the VM).
    @MainActor static func openKeyboardSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    /// The line Settings shows under a clashing shortcut: what one press does now, and the way out.
    static func warning(for action: CaptureHotkeyAction, shortcut: HotkeyShortcut, entry: Int) -> String {
        let keys = shortcut.displayTokens.joined()
        let now = switch outcome(for: action) {
        case .both: "On \(keys), macOS also \(macOSDoes(entry)), so one press does both."
        case .macOSOnly: "On \(keys), macOS \(macOSDoes(entry)) instead, so \(action.title) doesn’t run."
        }
        return "\(now) Turn macOS’s off in System Settings › \(settingsPath), or pick another key."
    }

    /// The launch notice's text for these clashes, the keys in order: what one press does now, and the way out.
    static func noticeText(_ clashes: [(action: CaptureHotkeyAction, shortcut: HotkeyShortcut, entry: Int)]) -> String {
        let sorted = clashes.sorted { ($0.shortcut.keyCode, $0.shortcut.modifiers.rawValue) < ($1.shortcut.keyCode, $1.shortcut.modifiers.rawValue) }
        let list = { (items: [String]) in ListFormatter.localizedString(byJoining: items) }
        let macOSOnly = sorted.filter { outcome(for: $0.action) == .macOSOnly }
        let both = sorted.filter { outcome(for: $0.action) == .both }
        var lines: [String] = []
        if !macOSOnly.isEmpty {
            let keys = list(macOSOnly.map { $0.shortcut.displayTokens.joined() })
            let actions = list(macOSOnly.map(\.action.title))
            lines.append("On \(keys), only macOS’s own screenshot runs, so Sukusho’s \(actions) \(macOSOnly.count == 1 ? "doesn’t" : "don’t").")
        }
        if !both.isEmpty {
            let keys = list(both.map { $0.shortcut.displayTokens.joined() })
            lines.append("On \(keys), macOS’s screenshot runs as well as Sukusho’s \(list(both.map(\.action.title))).")
        }
        lines.append("To use Sukusho’s, turn macOS’s off in System Settings › \(settingsPath), or pick other keys in Settings › Shortcuts.")
        return lines.joined(separator: " ")
    }
}
