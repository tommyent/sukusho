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

/// Once, at launch, when a Sukusho shortcut is one of macOS's screenshot shortcuts that is still on (the owner,
/// 2026-11-17: beta 1), with the owner's two ways out: Use Other Keys… moves them and opens Settings › Shortcuts to
/// change them further, Open Keyboard Shortcuts… opens macOS's settings to turn macOS's off; Not Now leaves them.
/// Settings keeps the same line and buttons for as long as the clash lasts; this notice never comes back.
enum ShortcutClashNotice {
    static let shownKey = "shortcutClashNotice.shown"

    static func showIfNeeded(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: shownKey) else { return }
        let clashes = SystemScreenshotShortcuts.currentClashPairs()
        guard !clashes.isEmpty else { return }

        let otherKeys = SystemScreenshotShortcuts.currentOtherKeys()
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "macOS also uses some of Sukusho’s shortcuts"
        alert.informativeText = SystemScreenshotShortcuts.warning(clashes, canUseOtherKeys: !otherKeys.isEmpty)
        if !otherKeys.isEmpty { alert.addButton(withTitle: "Use Other Keys…") }
        alert.addButton(withTitle: "Open Keyboard Shortcuts…")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate()
        let response = alert.runModal()
        // Shown once it's answered, Not Now included; a notice that never got an answer comes back at the next launch.
        defaults.set(true, forKey: shownKey)
        let first = NSApplication.ModalResponse.alertFirstButtonReturn
        switch (otherKeys.isEmpty, response) {
        case (false, first):
            // One button for "other keys or your own" (the owner): moved, then shown in Settings to change if wanted,
            // where any that kept their keys are named, as when Use Other Keys runs in Settings.
            SystemScreenshotShortcuts.useOtherKeys()
            SettingsWindowController.show(tab: .shortcuts)
        case (false, .alertSecondButtonReturn), (true, first): SystemScreenshotShortcuts.openKeyboardSettings()
        default: break
        }
    }
}
