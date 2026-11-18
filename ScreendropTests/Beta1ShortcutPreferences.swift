import Foundation

// Beta 1's own shortcut storage, so a test can take saved shortcuts through beta 1 and back. The enum is
// 90cdd5b:Screendrop/CaptureHotkeys.swift lines 266–329, unchanged but for the names: HotkeyShortcut became
// Beta1HotkeyShortcut, CaptureHotkeyPreferences Beta1CaptureHotkeyPreferences, and action.defaultShortcut and
// action.previousDefaultShortcut their beta1 forms below (beta 1's defaults are this build's).

/// Beta 1's shortcut: its two saved fields, and its rule that a shortcut has a modifier.
struct Beta1HotkeyShortcut: Codable, Equatable, Hashable {
    let modifiers: HotkeyShortcut.Modifiers
    let keyCode: Int

    var isValid: Bool {
        !modifiers.isEmpty
    }
}

extension Beta1HotkeyShortcut {
    init(_ shortcut: HotkeyShortcut) {
        self.init(modifiers: shortcut.modifiers, keyCode: shortcut.keyCode)
    }
}

extension CaptureHotkeyAction {
    var beta1DefaultShortcut: Beta1HotkeyShortcut { Beta1HotkeyShortcut(defaultShortcut) }
    var beta1PreviousDefaultShortcut: Beta1HotkeyShortcut? { previousDefaultShortcut.map { Beta1HotkeyShortcut($0) } }
}

enum Beta1CaptureHotkeyPreferences {
    /// Stored for an action the user cleared, so it has no shortcut at all.
    private static let clearedValue = "none"

    /// The action's shortcut: recorded, else the default; nil once cleared.
    static func shortcut(for action: CaptureHotkeyAction, defaults: UserDefaults = .standard) -> Beta1HotkeyShortcut? {
        if defaults.string(forKey: action.preferencesKey) == clearedValue { return nil }
        guard
            let data = defaults.data(forKey: action.preferencesKey),
            let shortcut = try? JSONDecoder().decode(Beta1HotkeyShortcut.self, from: data),
            shortcut.isValid
        else {
            return action.beta1DefaultShortcut
        }

        return shortcut
    }

    /// Nil clears the action. Its default is never stored, so changing a
    /// default reaches everyone who didn't record their own.
    static func saveShortcut(
        _ shortcut: Beta1HotkeyShortcut?,
        for action: CaptureHotkeyAction,
        defaults: UserDefaults = .standard
    ) {
        guard let shortcut else {
            defaults.set(clearedValue, forKey: action.preferencesKey)
            return
        }
        guard shortcut != action.beta1DefaultShortcut else {
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
        return shortcut(for: action, defaults: defaults) == action.beta1DefaultShortcut
    }

    /// Forgets stored shortcuts that equal their action's default, or its default before beta 1, so a change of a
    /// default reaches them, as it does everyone who never recorded one: an older build stored defaults, and without this
    /// a stored old ⇧⌘5 for Capture Text would collide with Recording's new ⇧⌘5. Cleared and changed shortcuts stay.
    /// Run at launch.
    static func dropStoredDefaults(defaults: UserDefaults = .standard) {
        for action in CaptureHotkeyAction.allCases where defaults.data(forKey: action.preferencesKey) != nil {
            let stored = shortcut(for: action, defaults: defaults)
            if isDefault(action, defaults: defaults) || (stored != nil && stored == action.beta1PreviousDefaultShortcut) {
                defaults.removeObject(forKey: action.preferencesKey)
            }
        }
    }
}
