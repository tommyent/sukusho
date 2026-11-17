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

    /// Moves each clashing shortcut to its other keys and registers it (the owner, 2026-11-17). Returns the actions whose
    /// new keys couldn't be registered, because another app holds them; those keep their old shortcut.
    @discardableResult static func useOtherKeys() -> [CaptureHotkeyAction] {
        var failed: [CaptureHotkeyAction] = []
        for (action, shortcut) in currentOtherKeys().sorted(by: { $0.key.hotKeyID < $1.key.hotKeyID }) {
            do { try HotkeyManager.shared.setShortcut(shortcut, for: action) } catch { failed.append(action) }
        }
        return failed
    }
}

/// Once, at launch, when a Sukusho shortcut is one of macOS's screenshot shortcuts that is still on (the owner,
/// 2026-11-17: beta 1), with the owner's two choices: Use Other Keys moves them, Choose My Own opens Settings ›
/// Shortcuts to record new ones; Not Now leaves them. Settings keeps the same line and choices for as long as the clash
/// lasts; this notice never comes back.
enum ShortcutClashNotice {
    static let shownKey = "shortcutClashNotice.shown"

    static func showIfNeeded(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: shownKey) else { return }
        let clashes = SystemScreenshotShortcuts.currentClashPairs()
        guard !clashes.isEmpty else { return }
        defaults.set(true, forKey: shownKey)

        let otherKeys = SystemScreenshotShortcuts.currentOtherKeys()
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "macOS also uses some of Sukusho’s shortcuts"
        alert.informativeText = SystemScreenshotShortcuts.warning(clashes, canUseOtherKeys: !otherKeys.isEmpty)
        if !otherKeys.isEmpty { alert.addButton(withTitle: "Use Other Keys") }
        alert.addButton(withTitle: "Choose My Own")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate()
        let response = alert.runModal()
        let first = NSApplication.ModalResponse.alertFirstButtonReturn
        switch (otherKeys.isEmpty, response) {
        case (false, first): SystemScreenshotShortcuts.useOtherKeys()
        case (false, .alertSecondButtonReturn), (true, first): SettingsWindowController.show(tab: .shortcuts)
        default: break
        }
    }
}
