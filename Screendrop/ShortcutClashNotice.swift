//
//  ShortcutClashNotice.swift
//  Screendrop
//

import AppKit

extension SystemScreenshotShortcuts {
    /// Sukusho's clashing shortcuts now, with their keys.
    static func currentClashPairs() -> [Clash] {
        let shortcuts = CaptureHotkeyPreferences.shortcuts()
        return currentClashes().compactMap { action in shortcuts[action].map { (action, $0) } }
    }

    /// Use Other Keys, as it would run now.
    static func currentOtherKeys() -> [CaptureHotkeyAction: HotkeyShortcut] {
        otherKeys(for: currentClashes(), shortcuts: CaptureHotkeyPreferences.shortcuts(), system: currentAllEnabled())
    }

    /// Moves each clashing shortcut to its other keys and registers it (the owner, 2026-11-17). The actions whose new keys
    /// couldn't be registered, because another app holds them, keep their old shortcut and are kept in
    /// `HotkeyManager.keptKeys`, which Settings names, wherever this ran.
    @discardableResult static func useOtherKeys() -> [CaptureHotkeyAction] {
        var failed: [CaptureHotkeyAction] = []
        for (action, shortcut) in currentOtherKeys().sorted(by: { $0.key.hotKeyID < $1.key.hotKeyID }) {
            do { try HotkeyManager.shared.setShortcut(shortcut, for: action) } catch { failed.append(action) }
        }
        HotkeyManager.shared.keptKeys = failed
        return failed
    }
}

extension ShortcutClashNotice {
    static func showIfNeeded(defaults: UserDefaults = .standard) {
        guard panel == nil, !defaults.bool(forKey: shownKey) else { return }
        let clashes = SystemScreenshotShortcuts.currentClashPairs()
        guard !clashes.isEmpty else { return }

        let canUseOtherKeys = !SystemScreenshotShortcuts.currentOtherKeys().isEmpty
        let window = makePanel(clashes: clashes, canUseOtherKeys: canUseOtherKeys, defaults: defaults) { answer in
            switch answer {
            case .useOtherKeys:
                // One button for "other keys or your own" (the owner): moved, then shown in Settings to change if wanted,
                // where any that kept their keys are named, as when Use Other Keys runs in Settings. The keys that clash
                // are read again now, so a change made while the notice waited is taken into account.
                SystemScreenshotShortcuts.useOtherKeys()
                SettingsWindowController.show(tab: .shortcuts)
            case .openKeyboardShortcuts: SystemScreenshotShortcuts.openKeyboardSettings()
            case .notNow: break
            }
        }
        panel = window
        NSApp.activate()
        window.orderFront(nil)
    }
}
